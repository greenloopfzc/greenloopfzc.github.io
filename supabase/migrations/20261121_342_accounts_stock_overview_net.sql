-- Report net supplier returns while retaining the gross quantities used by phone history.
begin;

do $$
begin
  if public.get_accounts_stock_overview_imeis_version() is distinct from '20261121-accounts-stock-overview-imeis-1' then
    raise exception 'Verify the Stock Overview IMEI update first.';
  end if;
end
$$;

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
      r.returned_quantity-r.replacement_quantity net_returned,
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
          'outside_chaman',f.outside_chaman,'total_out',f.exported+f.returned_quantity+f.outside_chaman,
          'net_returned',f.net_returned,'replacement_received',f.replacement_quantity,
          'net_out',f.exported+f.net_returned+f.outside_chaman)
        else jsonb_build_object('in_company',f.ready+f.in_process,'ready',f.ready,
          'in_process',f.in_process,'receipt_balance',f.balance_quantity,
          'original_received',f.received_quantity,'exported',f.exported,'supplier_returned',f.returned_quantity,
          'replacement_received',f.replacement_quantity,'net_returned',f.net_returned,'outside_chaman',f.outside_chaman,
          'calculated_balance',f.received_quantity-f.exported-f.net_returned-f.outside_chaman)
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

-- Reseal only the receipt report changed above. Existing readers keep their published fields.
update greenloop_private.accounts_stock_overview_installation
set hash=md5(pg_get_functiondef(to_regprocedure(identity)))
where identity='greenloop_private.aso_report(text,uuid,uuid,text,integer,integer,boolean,text)';

create table if not exists greenloop_private.accounts_stock_overview_net_installation(
  identity text primary key,
  hash text not null
);
alter table greenloop_private.accounts_stock_overview_net_installation enable row level security;
revoke all on table greenloop_private.accounts_stock_overview_net_installation from public,anon,authenticated;

create or replace function public.get_accounts_stock_overview_net_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
  select case when
    public.get_accounts_stock_overview_imeis_version()='20261121-accounts-stock-overview-imeis-1'
    and (select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.accounts_stock_overview_net_installation)
    and not has_table_privilege('anon','greenloop_private.accounts_stock_overview_net_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
    and not has_table_privilege('authenticated','greenloop_private.accounts_stock_overview_net_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  then '20261121-accounts-stock-overview-net-1' end;
$$;
revoke all on function public.get_accounts_stock_overview_net_version() from public;
grant execute on function public.get_accounts_stock_overview_net_version() to anon,authenticated;

insert into greenloop_private.accounts_stock_overview_net_installation
select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array[
  'greenloop_private.aso_report(text,uuid,uuid,text,integer,integer,boolean,text)',
  'public.get_accounts_stock_overview_net_version()'
]) signature on conflict(identity) do update set hash=excluded.hash;

do $$
begin
  if public.get_accounts_stock_overview_net_version() is distinct from '20261121-accounts-stock-overview-net-1' then
    raise exception 'Stock Overview net returns verification failed.';
  end if;
end
$$;
notify pgrst,'reload schema';
commit;
select public.get_accounts_stock_overview_net_version() as installed_stock_overview_net_version;
