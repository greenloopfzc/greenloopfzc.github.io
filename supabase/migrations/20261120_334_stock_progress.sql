-- Current company inventory by model, storage and workflow stage.
begin;

create or replace function public.get_company_stock_progress_v1(
  p_supplier_id uuid default null,
  p_batch_id uuid default null,
  p_invoice text default null,
  p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $report$
declare result jsonb;
begin
  perform greenloop_private.require_office_network();
  perform greenloop_private.pf_cap('reports', 'view');
  perform greenloop_private.pf_cap('reports', 'report_supplier_progress');
  if p_supplier_id is not null or p_batch_id is not null or p_invoice is not null then
    perform greenloop_private.pf_cap('reports', 'report_supplier_progress_search');
  end if;
  if p_offset is null or p_offset < 0 or p_offset % 50 <> 0 then
    raise exception 'Choose a valid stock page.' using errcode = '22023';
  end if;

  with latest_jobs as materialized (
    select distinct on (j.device_id)
      j.id, j.device_id, j.current_status, j.ownership_type, j.receiving_batch_id
    from public.jobs j
    where j.deleted_at is null
    order by j.device_id, j.received_at desc nulls last, j.created_at desc, j.id
  ), company_phones as materialized (
    select j.id job_id, j.device_id, j.current_status, j.receiving_batch_id,
      coalesce(nullif(btrim(regexp_replace(btrim(d.model), '^iphone[[:space:]]+', '', 'i')), ''), 'Unspecified') model,
      d.storage_gb
    from latest_jobs j
    join public.devices d on d.id = j.device_id and d.deleted_at is null
    where j.ownership_type = 'company_owned'
      and nullif(btrim(d.imei_1), '') is not null
      and j.current_status::text not in ('shipped', 'returned_to_customer', 'returned_to_supplier', 'shop_stock', 'scrap', 'rma_completed', 'cancelled', 'closed')
      and not exists (
        select 1 from greenloop_private.chaman_lines c
        where c.device_id = j.device_id and c.voided_at is null and c.phase <> 'company'
      )
      and not exists (
        select 1 from public.export_box_items i
        join greenloop_private.box_workflow w on w.box_id = i.box_id and w.state = 'exported'
        where i.job_id = j.id
      )
      and not exists (
        select 1 from public.supplier_returns r
        where (r.job_id = j.id or (r.job_id is null and r.device_id = j.device_id))
          and r.archived_at is null and r.status = 'returned'
      )
  ), receipts as materialized (
    select r.batch_id, r.supplier_id, r.supplier_code, r.supplier_name,
      r.batch_number, r.invoice_number, r.received_quantity, r.descendant_ids
    from greenloop_private.sc_receipts() r
    where r.parent_batch_id is null
  ), stock as materialized (
    select c.*, r.batch_id, r.supplier_id, r.invoice_number
    from company_phones c
    left join lateral (
      select r.batch_id, r.supplier_id, r.invoice_number
      from receipts r
      where c.receiving_batch_id = any(r.descendant_ids)
      order by (c.receiving_batch_id = r.batch_id) desc, r.batch_id
      limit 1
    ) r on true
  ), selected as materialized (
    select s.model, s.storage_gb,
      case
        when s.current_status::text in ('return_pending', 'supplier_return_requested')
          or exists (
            select 1 from public.supplier_returns r
            where (r.job_id = s.job_id or (r.job_id is null and r.device_id = s.device_id))
              and r.archived_at is null and r.status in ('requested', 'approved')
          ) then 'return_pending'
        when s.current_status = 'parts_pending' then 'parts'
        when s.current_status = 'box_entry' then 'box_entry'
        when s.current_status = 'accounts_pending' then 'accounts'
        when stage.name = 'ready_stock' and not exists (
          select 1 from greenloop_private.qdr_ready_outcomes q
          where q.job_id = s.job_id and q.result = 'pass'
        ) then 'other'
        when stage.name in ('initial_qc', 'issuance', 'lab_glass', 'final_qc', 'b_dept', 'ready_stock')
          then stage.name
        else 'other'
      end stage
    from stock s
    cross join lateral (select greenloop_private.scp_stage(s.job_id) name) stage
    where (p_supplier_id is null or s.supplier_id = p_supplier_id)
      and (p_batch_id is null or s.batch_id = p_batch_id)
      and (p_invoice is null or s.invoice_number = p_invoice)
  ), grouped as materialized (
    select min(model) model, storage_gb, count(*) quantity,
      count(*) filter (where stage = 'initial_qc') initial_qc,
      count(*) filter (where stage = 'issuance') issuance,
      count(*) filter (where stage = 'lab_glass') lab_glass,
      count(*) filter (where stage = 'parts') parts,
      count(*) filter (where stage = 'final_qc') final_qc,
      count(*) filter (where stage = 'b_dept') b_dept,
      count(*) filter (where stage = 'ready_stock') ready_stock,
      count(*) filter (where stage = 'box_entry') box_entry,
      count(*) filter (where stage = 'accounts') accounts,
      count(*) filter (where stage = 'return_pending') return_pending,
      count(*) filter (where stage = 'other') other
    from selected
    group by lower(regexp_replace(model, '[[:space:]]+', ' ', 'g')), storage_gb
  ), totals as (
    select coalesce(sum(quantity),0) quantity,
      coalesce(sum(initial_qc),0) initial_qc, coalesce(sum(issuance),0) issuance,
      coalesce(sum(lab_glass),0) lab_glass, coalesce(sum(parts),0) parts,
      coalesce(sum(final_qc),0) final_qc, coalesce(sum(b_dept),0) b_dept,
      coalesce(sum(ready_stock),0) ready_stock, coalesce(sum(return_pending),0) return_pending,
      coalesce(sum(box_entry),0) box_entry, coalesce(sum(accounts),0) accounts,
      coalesce(sum(other),0) other
    from grouped
  ), page as (
    select * from grouped order by lower(model), storage_gb nulls last, model
    offset p_offset limit 50
  )
  select jsonb_build_object(
    'offset', p_offset, 'row_count', (select count(*) from grouped),
    'totals', (select to_jsonb(t) from totals t),
    'rows', coalesce((select jsonb_agg(to_jsonb(p) order by lower(model), storage_gb nulls last, model) from page p), '[]'),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'batch_id', r.batch_id, 'supplier_id', r.supplier_id,
        'supplier_code', regexp_replace(r.supplier_code, '-\([0-9]+\)$', ''),
        'supplier_name', case when public.get_my_partner_name_access() then r.supplier_name end,
        'batch_number', r.batch_number, 'invoice_number', r.invoice_number,
        'receipt_quantity', r.received_quantity
      ) order by r.batch_number, r.batch_id)
      from receipts r where exists (select 1 from stock s where s.batch_id = r.batch_id)
    ), '[]'),
    'checked_at', statement_timestamp()
  ) into result;
  return result;
end;
$report$;

revoke all on function public.get_company_stock_progress_v1(uuid,uuid,text,integer) from public, anon;
grant execute on function public.get_company_stock_progress_v1(uuid,uuid,text,integer) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_company_stock_progress_v1','{"page":"reports","capability":"report_supplier_progress","read":true}'),
  ('get_company_stock_progress_version','{"read":true}')
on conflict (rpc_name) do update set rule=excluded.rule;

update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.company_stock_progress_installation(identity text primary key, hash text not null);
alter table greenloop_private.company_stock_progress_installation enable row level security;
revoke all on greenloop_private.company_stock_progress_installation from public, anon, authenticated;

create or replace function public.get_company_stock_progress_version() returns text
language sql stable security definer set search_path = pg_catalog, public as $version$
  select case when
    (select count(*)=2 and bool_and(hash is not distinct from md5(pg_get_functiondef(to_regprocedure(identity))))
      from greenloop_private.company_stock_progress_installation)
    and has_function_privilege('authenticated','public.get_company_stock_progress_v1(uuid,uuid,text,integer)','EXECUTE')
    and not has_function_privilege('anon','public.get_company_stock_progress_v1(uuid,uuid,text,integer)','EXECUTE')
    and public.get_page_capabilities_version()='20261016-page-capabilities-1'
  then '20261120-company-stock-progress-1' end;
$version$;
revoke all on function public.get_company_stock_progress_version() from public;
grant execute on function public.get_company_stock_progress_version() to anon, authenticated;

insert into greenloop_private.company_stock_progress_installation
select signature, md5(pg_get_functiondef(signature::regprocedure))
from unnest(array['public.get_company_stock_progress_v1(uuid,uuid,text,integer)',
                  'public.get_company_stock_progress_version()']) signature
on conflict (identity) do update set hash=excluded.hash;

do $verify$
begin
  if public.get_company_stock_progress_version() is distinct from '20261120-company-stock-progress-1' then
    raise exception 'Stock Progress verification failed.';
  end if;
end
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_company_stock_progress_version() as installed_stock_progress_version;
