-- Out Stock exports exclude exact supplier returns with a received replacement.
begin;

do $$
begin
  if public.get_accounts_stock_overview_export_counts_version() is distinct from '20261121-accounts-stock-overview-export-counts-1' then
    raise exception 'Verify the Stock Overview export counts update first.';
  end if;
end
$$;

create or replace function greenloop_private.aso_unreplaced_out_report(
  p_mode text,p_supplier_id uuid,p_batch_id uuid,p_invoice_number text,p_imei text,
  p_offset integer,p_export boolean,p_summary_only boolean,p_expected_snapshot text
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $report$
declare
  filters jsonb:=jsonb_strip_nulls(jsonb_build_object(
    'supplier_id',p_supplier_id::text,'batch_id',p_batch_id::text,'invoice_number',p_invoice_number));
  result jsonb;
  row_limit integer;
begin
  perform greenloop_private.pf_cap('accounts','supplier_stock');
  perform greenloop_private.aid_access(filters,'imei','asc',true);
  if p_imei is not null then perform greenloop_private.pf_cap('accounts','search'); end if;
  perform greenloop_private.pf_cap('accounts','print');
  if p_mode is distinct from 'out'
    or p_imei is not null and p_imei !~ '^[0-9]{3,15}$'
    or p_export is null or p_summary_only is null
    or p_offset is null or p_offset<0 or p_export=p_summary_only or (p_summary_only and p_offset<>0)
    or p_export and (p_expected_snapshot is null or p_expected_snapshot !~ '^[0-9a-f]{32}$') then
    raise exception 'Choose a valid IMEI search or refresh this report before exporting.' using errcode='22023';
  end if;
  row_limit:=case when p_summary_only then 0 else 250 end;

  with selected as materialized (
    select r.* from greenloop_private.sc_receipts() r
    where r.parent_batch_id is null
      and (p_supplier_id is null or r.supplier_id=p_supplier_id)
      and (p_batch_id is null or r.batch_id=p_batch_id)
      and (p_invoice_number is null or r.invoice_number=p_invoice_number)
  ), receipt_batches as materialized (
    select r.batch_id root_id,node.id batch_id
    from selected r cross join lateral unnest(r.descendant_ids) node(id)
  ), active_custody as materialized (
    select distinct on (l.device_id) l.device_id,l.job_id,l.id,l.imei,l.details,l.phase,
      coalesce(l.details->>'batch_id',j.receiving_batch_id::text) batch_key
    from greenloop_private.chaman_lines l
    left join public.jobs j on j.id=l.job_id
    where l.voided_at is null and l.phase in ('out_pending','shop','return_pending')
    order by l.device_id,l.custody_order desc,l.id
  ), stock_units as materialized (
    select r payload from greenloop_private.isu_units(filters) r
    where exists(select 1 from selected)
  ), active_returns as (
    select b.root_id,s.*,j.device_id job_device,
      coalesce(s.device_id::text,s.job_id::text,s.imei_1,s.id::text) return_key,
      exists(
        select 1 from greenloop_private.srp_allocations allocation
        join greenloop_private.srp_receipts received on received.id=allocation.receipt_id
        join receipt_batches replacement on replacement.batch_id=received.replacement_batch_id
          and replacement.root_id=b.root_id
        where allocation.return_id=s.id and received.original_batch_id=s.batch_id
      ) replaced
    from public.supplier_returns s join receipt_batches b on b.batch_id=s.batch_id
    left join public.jobs j on j.id=s.job_id
    where s.archived_at is null and s.status='returned'
  ), historic_returns as materialized (
    select distinct on (batch_id,return_key) *
    from active_returns
    order by batch_id,return_key,replaced desc,coalesce(handed_over_at,requested_at) desc,id
  ), phone_rows as materialized (
    select (u.payload->>'batch_id')::uuid root_id,u.payload->>'unit_key' row_key,u.payload->>'imei' imei,d.imei_2::text imei_2,
      u.payload->>'model' model,u.payload->>'storage_gb' storage_gb,u.payload->>'color' color,
      coalesce(nullif(u.payload->>'final_grade',''),nullif(u.payload->>'initial_grade',''),u.payload->>'supplier_grade') grade,
      'Exported' status
    from stock_units u
    left join public.devices d on d.id=(u.payload->>'device_id')::uuid
    left join active_custody c on c.device_id=d.id
    where c.device_id is null and u.payload->>'category'='exported'
    union all
    select s.root_id,'return:'||s.id,
      case when btrim(s.imei_1) ~ '^[0-9]{15}$' then btrim(s.imei_1)
        when d.imei_1 ~ '^[0-9]{15}$' then d.imei_1::text end,d.imei_2::text,
      coalesce(nullif(s.model,''),d.model),
      coalesce(s.source_snapshot->>'storage_gb',d.storage_gb::text),
      coalesce(s.source_snapshot->>'color',d.color),coalesce(d.gc_grade::text,d.original_grade::text),
      'Returned to Supplier'
    from historic_returns s
    left join public.devices d on d.id=coalesce(s.device_id,s.job_device)
    where not s.replaced
    union all
    select b.root_id,'chaman:'||c.id,c.imei,d.imei_2::text,
      coalesce(c.details->>'model',d.model),coalesce(c.details->>'storage_gb',d.storage_gb::text),
      coalesce(c.details->>'color',d.color),
      coalesce(c.details->>'final_grade',c.details->>'grade',d.gc_grade::text,d.original_grade::text),
      case c.phase when 'out_pending' then 'Chaman receiving pending'
        when 'return_pending' then 'Greenloop receiving pending' else 'Chaman Shop' end
    from active_custody c join receipt_batches b on b.batch_id::text=c.batch_key
    left join public.devices d on d.id=c.device_id
  ), out_counts as (
    select count(*) filter(where status='Exported') exported,
      (select count(*) from historic_returns) supplier_returned,
      count(*) filter(where status='Returned to Supplier') unreplaced_returned,
      count(*) filter(where row_key like 'chaman:%') outside_chaman,
      (select coalesce(sum(replacement_quantity),0) from selected) replacement_received
    from phone_rows where p_imei is null
  ), matches as materialized (
    select s.received_at,p.imei,p.row_key||':'||p.root_id key,
      jsonb_build_object('row_key',p.row_key||':'||p.root_id,
        'imei',p.imei,'model',p.model,'storage_gb',
        case when p.storage_gb ~ '^[0-9]{1,6}$' then p.storage_gb::integer end,
        'color',p.color,'grade',p.grade,'status',p.status,'batch_number',s.batch_number,
        'invoice_number',s.invoice_number,'receipt_quantity',s.received_quantity,
        'supplier_code',s.supplier_code,'supplier_name',s.supplier_name) record
    from phone_rows p join selected s on s.batch_id=p.root_id
    where (
      p.imei ~ '^[0-9]{15}$' and (p_imei is null or
        (length(p_imei)=15 and (p.imei=p_imei or p.imei_2=p_imei)) or
        (length(p_imei)<15 and (strpos(p.imei,p_imei)>0 or strpos(p.imei_2,p_imei)>0)))
    ) or (
      p_imei is null and p.status='Returned to Supplier' and p.imei is null
    )
  ), page as (
    select * from matches order by received_at desc nulls last,imei,key offset p_offset limit row_limit
  )
  select jsonb_build_object(
    'mode',p_mode,'offset',p_offset,'total',(select count(*) from matches),
    'missing_imei',(select count(*) from matches where imei is null),
    'out_summary',scope_summary,
    'snapshot',md5(jsonb_build_array(p_mode,filters,p_imei,scope_summary,
      (select jsonb_agg(record order by received_at desc nulls last,imei,key) from matches))::text),
    'rows',coalesce((select jsonb_agg(record order by received_at desc nulls last,imei,key) from page),'[]')
  ) into result
  from (select case when p_imei is null then to_jsonb(c) end scope_summary
    from out_counts c) summary;

  if p_expected_snapshot is not null and p_expected_snapshot is distinct from result->>'snapshot' then
    raise exception 'The IMEI list changed. Refresh Stock Overview before trying again.' using errcode='40001';
  end if;
  return result;
end
$report$;

create or replace function public.get_accounts_stock_overview_out_export_v1(
  p_mode text,p_supplier_id uuid default null,p_batch_id uuid default null,p_invoice_number text default null,
  p_imei text default null,p_offset integer default 0,p_export boolean default false,
  p_summary_only boolean default false,p_expected_snapshot text default null
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.aso_unreplaced_out_report(p_mode,p_supplier_id,p_batch_id,p_invoice_number,p_imei,
    p_offset,p_export,p_summary_only,p_expected_snapshot);
end
$$;

revoke all on function greenloop_private.aso_unreplaced_out_report(text,uuid,uuid,text,text,integer,boolean,boolean,text)
  from public,anon,authenticated;
revoke all on function public.get_accounts_stock_overview_out_export_v1(text,uuid,uuid,text,text,integer,boolean,boolean,text)
  from public,anon,authenticated;
grant execute on function public.get_accounts_stock_overview_out_export_v1(text,uuid,uuid,text,text,integer,boolean,boolean,text)
  to authenticated;

insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
select api,impl,md5(pg_get_functiondef(impl::regprocedure)),md5(pg_get_functiondef(api::regprocedure))
from (values ('public.get_accounts_stock_overview_out_export_v1(text,uuid,uuid,text,text,integer,boolean,boolean,text)',
  'greenloop_private.aso_unreplaced_out_report(text,uuid,uuid,text,text,integer,boolean,boolean,text)')) v(api,impl)
on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_accounts_stock_overview_out_export_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"supplier_stock"},{"page":"accounts","capability":"imei_data"},{"page":"accounts","capability":"imei_download"},{"page":"accounts","capability":"print"}],"read":true}'),
  ('get_accounts_stock_overview_net_export_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.accounts_stock_overview_net_export_installation(
  identity text primary key,
  hash text not null
);
alter table greenloop_private.accounts_stock_overview_net_export_installation enable row level security;
revoke all on table greenloop_private.accounts_stock_overview_net_export_installation from public,anon,authenticated;

create or replace function public.get_accounts_stock_overview_net_export_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
  select case when
    public.get_accounts_stock_overview_export_counts_version()='20261121-accounts-stock-overview-export-counts-1'
    and (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.accounts_stock_overview_net_export_installation)
    and (select wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))
      and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')
      and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')
      and not has_function_privilege('anon',to_regprocedure(implementation),'EXECUTE')
      and not has_function_privilege('authenticated',to_regprocedure(implementation),'EXECUTE')
      from greenloop_private.office_routines
      where identity='public.get_accounts_stock_overview_out_export_v1(text,uuid,uuid,text,text,integer,boolean,boolean,text)')
    and not has_table_privilege('anon','greenloop_private.accounts_stock_overview_net_export_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
    and not has_table_privilege('authenticated','greenloop_private.accounts_stock_overview_net_export_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  then '20261121-accounts-stock-overview-net-export-1' end;
$$;
revoke all on function public.get_accounts_stock_overview_net_export_version() from public;
grant execute on function public.get_accounts_stock_overview_net_export_version() to anon,authenticated;

insert into greenloop_private.accounts_stock_overview_net_export_installation
select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array[
  'greenloop_private.aso_unreplaced_out_report(text,uuid,uuid,text,text,integer,boolean,boolean,text)',
  'public.get_accounts_stock_overview_out_export_v1(text,uuid,uuid,text,text,integer,boolean,boolean,text)',
  'public.get_accounts_stock_overview_net_export_version()'
]) signature on conflict(identity) do update set hash=excluded.hash;

do $$
begin
  if public.get_accounts_stock_overview_net_export_version() is distinct from '20261121-accounts-stock-overview-net-export-1' then
    raise exception 'Stock Overview net export verification failed.';
  end if;
end
$$;
notify pgrst,'reload schema';
commit;
select public.get_accounts_stock_overview_net_export_version() as installed_stock_overview_net_export_version;
