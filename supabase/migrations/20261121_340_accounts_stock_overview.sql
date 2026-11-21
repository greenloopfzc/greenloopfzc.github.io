-- Accounts stock movement and company balance by original receipt.
begin;

create or replace function greenloop_private.aso_report(
  p_mode text, p_supplier_id uuid, p_batch_id uuid, p_invoice_number text,
  p_offset integer, p_limit integer, p_catalogue boolean, p_expected_snapshot text
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $report$
declare result jsonb;
begin
  perform greenloop_private.pf_cap('accounts','view');
  perform greenloop_private.pf_cap('accounts','supplier_stock');
  if p_supplier_id is not null or p_batch_id is not null or p_invoice_number is not null then
    perform greenloop_private.pf_cap('accounts','search');
  end if;
  if p_mode is null or p_mode not in ('in','out','balance')
    or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 0 and 250
    or (p_limit=0 and p_offset<>0) or p_catalogue is null
    or length(p_invoice_number)>200 then
    raise exception 'Choose a valid Stock Overview selection.' using errcode='22023';
  end if;

  with receipts as materialized (
    select * from greenloop_private.sc_receipts()
  ), roots as materialized (
    select * from receipts where parent_batch_id is null
  ), selected as materialized (
    select r.* from roots r
    where (p_supplier_id is null or r.supplier_id=p_supplier_id)
      and (p_batch_id is null or r.batch_id=p_batch_id)
      and (p_invoice_number is null or r.invoice_number=p_invoice_number)
  ), active_custody as materialized (
    select distinct on (l.device_id) l.device_id,
      coalesce(l.details->>'batch_id',j.receiving_batch_id::text) batch_key
    from greenloop_private.chaman_lines l
    left join public.jobs j on j.id=l.job_id
    where p_mode<>'in' and l.voided_at is null and l.phase in ('out_pending','shop','return_pending')
    order by l.device_id,l.custody_order desc,l.id
  ), custody_counts as (
    select r.batch_id,count(*) outside_chaman
    from selected r
    cross join lateral unnest(r.descendant_ids) node(id)
    join active_custody c on c.batch_key=node.id::text
    group by r.batch_id
  ), unit_filters as (
    select jsonb_strip_nulls(jsonb_build_object('supplier_id',p_supplier_id,'batch_id',p_batch_id,'invoice_number',p_invoice_number)) filters
    where p_mode<>'in' and exists(select 1 from selected)
  ), ready_devices as materialized (
    select r.device_id from greenloop_private.rsbe_current(null,null) r
    where p_mode='balance' and exists(select 1 from selected)
  ), stock_units as (
    select (u->>'batch_id')::uuid batch_id,
      count(*) unit_count,
      count(*) filter(where custody.device_id is null and u->>'category' not in ('returned','exported','chaman') and ready.device_id is not null) ready,
      count(*) filter(where custody.device_id is null and u->>'category'='exported') exported,
      count(*) filter(where custody.device_id is null and u->>'category' not in ('returned','exported','chaman') and ready.device_id is null) in_process
    from unit_filters f cross join lateral greenloop_private.isu_units(f.filters) u
    left join active_custody custody on custody.device_id=(u->>'device_id')::uuid
    left join ready_devices ready on ready.device_id=(u->>'device_id')::uuid
    group by (u->>'batch_id')::uuid
  ), pending_replacement as (
    select r.batch_id,sum(greatest(child.received_quantity-greenloop_private.sro_entered_count(child.batch_id),0)) pending
    from selected r join receipts child on child.batch_id=any(r.descendant_ids) and child.parent_batch_id is not null
    where p_mode='balance' and child.received_quantity>0
    group by r.batch_id
  ), facts as (
    select r.*,
      coalesce(u.exported,0) exported,coalesce(c.outside_chaman,0) outside_chaman,
      coalesce(u.ready,0) ready,
      coalesce(u.in_process,0)+greatest(r.received_quantity-coalesce(u.unit_count,0),0)+coalesce(p.pending,0) in_process
    from selected r
    left join stock_units u using(batch_id)
    left join pending_replacement p using(batch_id)
    left join custody_counts c using(batch_id)
  ), displayed as materialized (
    select f.batch_id,f.received_at,
      jsonb_build_object('batch_id',f.batch_id,'supplier_code',f.supplier_code,'supplier_name',f.supplier_name,
        'batch_number',f.batch_number,'invoice_number',f.invoice_number,'received_at',f.received_at,
        'receipt_quantity',f.received_quantity)
      || case p_mode
        when 'in' then jsonb_build_object('original_received',f.received_quantity,'replacement_received',f.replacement_quantity,
          'total_received',f.received_quantity+f.replacement_quantity)
        when 'out' then jsonb_build_object('exported',f.exported,'supplier_returned',f.returned_quantity,
          'outside_chaman',f.outside_chaman,'total_out',f.exported+f.returned_quantity+f.outside_chaman)
        else jsonb_build_object('in_company',f.ready+f.in_process,'ready',f.ready,
          'in_process',f.in_process,'receipt_balance',f.balance_quantity)
      end record
    from facts f
  ), totals as (
    select key,case when count(value #>> '{}')=count(*) then to_jsonb(coalesce(sum((value #>> '{}')::numeric),0))
      else 'null'::jsonb end total
    from displayed cross join lateral jsonb_each(record - array['batch_id','supplier_code','supplier_name','batch_number',
      'invoice_number','received_at','receipt_quantity'])
    group by key
  ), page as (
    select * from displayed order by received_at desc nulls last,batch_id offset p_offset limit p_limit
  )
  select jsonb_build_object(
    'mode',p_mode,'offset',p_offset,'total',(select count(*) from displayed),
    'summary',coalesce((select jsonb_object_agg(key,total) from totals),'{}'::jsonb),
    'snapshot',md5(coalesce((select jsonb_agg(record order by received_at desc nulls last,batch_id) from displayed),'[]'::jsonb)::text),
    'rows',coalesce((select jsonb_agg(record order by received_at desc nulls last,batch_id) from page),'[]'::jsonb),
    'catalogue',case when p_catalogue and public.has_page_capability_v1('accounts','search') then
      coalesce((select jsonb_agg(jsonb_build_object('batch_id',r.batch_id,'batch_number',r.batch_number,
        'invoice_number',r.invoice_number,'supplier_id',r.supplier_id,'supplier_code',r.supplier_code,
        'supplier_name',r.supplier_name,'receipt_quantity',r.received_quantity) order by r.batch_number,r.batch_id) from roots r),'[]'::jsonb)
      else null end
  ) into result;

  if p_expected_snapshot is not null and p_expected_snapshot is distinct from result->>'snapshot' then
    raise exception 'Stock changed. Refresh Stock Overview before trying again.' using errcode='40001';
  end if;
  return result;
end
$report$;

create or replace function greenloop_private.aso_read(
  p_mode text,p_supplier_id uuid,p_batch_id uuid,p_invoice_number text,
  p_offset integer,p_show_rows boolean,p_catalogue boolean,p_expected_snapshot text
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if p_show_rows is null then raise exception 'Choose a valid Stock Overview page.' using errcode='22023'; end if;
  return greenloop_private.aso_report(p_mode,p_supplier_id,p_batch_id,p_invoice_number,p_offset,
    case when p_show_rows then 50 else 0 end,p_catalogue,p_expected_snapshot);
end
$$;

create or replace function greenloop_private.aso_export(
  p_mode text,p_supplier_id uuid,p_batch_id uuid,p_invoice_number text,p_offset integer,p_expected_snapshot text
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.pf_cap('accounts','print');
  if p_expected_snapshot is null or p_expected_snapshot !~ '^[a-f0-9]{32}$' then
    raise exception 'Refresh the Stock Overview summary before exporting.' using errcode='22023';
  end if;
  return greenloop_private.aso_report(p_mode,p_supplier_id,p_batch_id,p_invoice_number,p_offset,250,false,p_expected_snapshot);
end
$$;

create or replace function public.get_accounts_stock_overview_v1(
  p_mode text,p_supplier_id uuid default null,p_batch_id uuid default null,p_invoice_number text default null,
  p_offset integer default 0,p_show_rows boolean default false,p_catalogue boolean default false,p_expected_snapshot text default null
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.aso_read(p_mode,p_supplier_id,p_batch_id,p_invoice_number,p_offset,p_show_rows,p_catalogue,p_expected_snapshot);
end
$$;

create or replace function public.export_accounts_stock_overview_v1(
  p_mode text,p_supplier_id uuid,p_batch_id uuid,p_invoice_number text,p_offset integer,p_expected_snapshot text
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.aso_export(p_mode,p_supplier_id,p_batch_id,p_invoice_number,p_offset,p_expected_snapshot);
end
$$;

revoke all on function greenloop_private.aso_report(text,uuid,uuid,text,integer,integer,boolean,text),
  greenloop_private.aso_read(text,uuid,uuid,text,integer,boolean,boolean,text),
  greenloop_private.aso_export(text,uuid,uuid,text,integer,text)
  from public,anon,authenticated;
revoke all on function public.get_accounts_stock_overview_v1(text,uuid,uuid,text,integer,boolean,boolean,text),
  public.export_accounts_stock_overview_v1(text,uuid,uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.get_accounts_stock_overview_v1(text,uuid,uuid,text,integer,boolean,boolean,text),
  public.export_accounts_stock_overview_v1(text,uuid,uuid,text,integer,text) to authenticated;

insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
select api,impl,md5(pg_get_functiondef(impl::regprocedure)),md5(pg_get_functiondef(api::regprocedure))
from (values
  ('public.get_accounts_stock_overview_v1(text,uuid,uuid,text,integer,boolean,boolean,text)','greenloop_private.aso_read(text,uuid,uuid,text,integer,boolean,boolean,text)'),
  ('public.export_accounts_stock_overview_v1(text,uuid,uuid,text,integer,text)','greenloop_private.aso_export(text,uuid,uuid,text,integer,text)')
) v(api,impl)
on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_accounts_stock_overview_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"supplier_stock"}],"read":true}'),
  ('export_accounts_stock_overview_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"supplier_stock"},{"page":"accounts","capability":"print"}],"read":true}'),
  ('get_accounts_stock_overview_version','{"read":true}')
on conflict (rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.accounts_stock_overview_installation(identity text primary key,hash text not null);
alter table greenloop_private.accounts_stock_overview_installation enable row level security;
revoke all on greenloop_private.accounts_stock_overview_installation from public,anon,authenticated;

create or replace function public.get_accounts_stock_overview_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
  select case when (
    select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
    from greenloop_private.accounts_stock_overview_installation
  )
  and not exists (
    select 1 from greenloop_private.accounts_stock_overview_installation s
    where s.identity like 'greenloop_private.%'
      and (has_function_privilege('anon',to_regprocedure(s.identity),'EXECUTE')
        or has_function_privilege('authenticated',to_regprocedure(s.identity),'EXECUTE'))
  )
  and (
    select count(*)=2 and bool_and(
      coalesce(wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))),false) and
      coalesce(original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),false)
      and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')
      and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE'))
    from greenloop_private.office_routines
    where identity in ('public.get_accounts_stock_overview_v1(text,uuid,uuid,text,integer,boolean,boolean,text)',
                       'public.export_accounts_stock_overview_v1(text,uuid,uuid,text,integer,text)')
  )
  and public.get_page_capabilities_version()='20261016-page-capabilities-1'
  then '20261121-accounts-stock-overview-1' end;
$$;
revoke all on function public.get_accounts_stock_overview_version() from public;
grant execute on function public.get_accounts_stock_overview_version() to anon,authenticated;
insert into greenloop_private.accounts_stock_overview_installation
select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array[
  'greenloop_private.aso_report(text,uuid,uuid,text,integer,integer,boolean,text)',
  'greenloop_private.aso_read(text,uuid,uuid,text,integer,boolean,boolean,text)',
  'greenloop_private.aso_export(text,uuid,uuid,text,integer,text)',
  'public.get_accounts_stock_overview_v1(text,uuid,uuid,text,integer,boolean,boolean,text)',
  'public.export_accounts_stock_overview_v1(text,uuid,uuid,text,integer,text)',
  'public.get_accounts_stock_overview_version()'
]) signature on conflict(identity) do update set hash=excluded.hash;

do $verify$
begin
  if public.get_accounts_stock_overview_version() is distinct from '20261121-accounts-stock-overview-1' then
    raise exception 'Accounts Stock Overview verification failed.';
  end if;
end
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_accounts_stock_overview_version() as installed_accounts_stock_overview_version;
