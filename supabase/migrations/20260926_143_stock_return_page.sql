-- Stock Return page: supplier-first lookup only. Existing return transactions,
-- quantities, approval rules and permanent history remain in migration 142.
begin;

do $$
begin
  if to_regprocedure('public.get_greenloop_supplier_returns_version()') is null then
    raise exception 'Install the Supplier Returns database update before the Stock Return page update.' using errcode = '55000';
  end if;
  if public.get_greenloop_supplier_returns_version() is distinct from '20260925-supplier-returns-1' then
    raise exception 'The Supplier Returns database update could not be verified. No Stock Return page changes were installed.' using errcode = '55000';
  end if;
end;
$$;

create or replace function public.get_supplier_return_suppliers()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  perform greenloop_private.require_supplier_return_access('view');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'supplier_id', s.id,
      'supplier_code', s.supplier_code,
      'supplier_name', case when public.get_my_partner_name_access() then s.company_name else null end
    ) order by lower(s.supplier_code), s.id)
    from public.suppliers s
    where s.deleted_at is null and (
      exists(select 1 from public.receiving_batches b where b.supplier_id = s.id and b.planned_quantity is not null)
      or exists(select 1 from public.jobs j join public.devices d on d.id = j.device_id
        where j.supplier_id = s.id and j.deleted_at is null and d.deleted_at is null
          and j.ownership_type = 'company_owned')
    )
  ), '[]'::jsonb);
end;
$$;

create or replace function public.search_supplier_return_devices(
  p_supplier_id uuid,
  p_query text,
  p_offset integer default 0,
  p_limit integer default 25
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_query text := lower(btrim(coalesce(p_query, '')));
  v_offset integer := coalesce(p_offset, 0);
  v_limit integer := least(coalesce(p_limit, 25), 50);
  v_result jsonb;
begin
  perform greenloop_private.require_supplier_return_access('view');
  if p_supplier_id is null or not exists(select 1 from public.suppliers s where s.id = p_supplier_id and s.deleted_at is null) then
    raise exception 'Select a valid supplier first.' using errcode = '22023';
  end if;
  if v_offset < 0 or v_limit < 1 then
    raise exception 'The search page is invalid. Search again from the first page.' using errcode = '22023';
  end if;
  if length(v_query) > 100 then
    raise exception 'Enter a model, IMEI or serial number of 100 characters or fewer.' using errcode = '22023';
  end if;
  if v_query = '' then
    return jsonb_build_object('items', '[]'::jsonb, 'has_more', false);
  end if;

  with matches as materialized (
    select d.id as device_id, d.imei_1, d.serial_number, d.model, d.storage_gb, d.color,
      j.id as job_id, j.supplier_id, j.current_status, j.receiving_batch_id as batch_id,
      j.ownership_type, j.closed_at, s.supplier_code, s.company_name, b.batch_number,
      lower(coalesce(d.model, '')) as sort_model
    from public.devices d
    -- Choose the current job before filtering its supplier. A phone's older
    -- supplier must never offer a return against an earlier repair ticket.
    join lateral (
      select x.* from public.jobs x
      where x.device_id = d.id and x.deleted_at is null
      order by x.received_at desc, x.created_at desc, x.id desc limit 1
    ) j on j.supplier_id = p_supplier_id
    join public.suppliers s on s.id = j.supplier_id and s.deleted_at is null
    left join public.receiving_batches b on b.id = j.receiving_batch_id
    where d.deleted_at is null and (
      strpos(lower(coalesce(d.model, '')), v_query) > 0
      or strpos(coalesce(d.imei_1, ''), v_query) > 0
      or strpos(coalesce(d.imei_2, ''), v_query) > 0
      or strpos(lower(coalesce(d.serial_number, '')), v_query) > 0
    )
    order by lower(coalesce(d.model, '')), d.imei_1, d.id
    offset v_offset limit (v_limit + 1)
  ), shown as (
    select * from matches order by sort_model, imei_1, device_id limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'device_id', q.device_id, 'job_id', q.job_id, 'imei_1', q.imei_1,
      'serial_number', q.serial_number, 'model', q.model,
      'storage_gb', q.storage_gb, 'color', q.color,
      'supplier_id', q.supplier_id, 'supplier_code', q.supplier_code,
      'supplier_name', case when public.get_my_partner_name_access() then q.company_name else null end,
      'current_status', q.current_status, 'batch_id', q.batch_id, 'batch_number', q.batch_number,
      'eligible', q.ownership_type = 'company_owned' and q.closed_at is null
        and q.current_status::text not in ('shipped', 'returned_to_customer', 'rma_completed', 'scrap',
          'supplier_return_requested', 'return_pending', 'returned_to_supplier')
        and not exists(select 1 from public.export_box_items i where i.device_id = q.device_id)
        and active.data is null,
      'unreconciled_parts_quantity', coalesce((select sum((x->>'unused_quantity')::integer)
        from jsonb_array_elements(greenloop_private.supplier_return_parts(q.job_id)) x), 0),
      'active_return', active.data
    ) order by q.sort_model, q.imei_1, q.device_id)
    from shown q
    left join lateral (
      select greenloop_private.supplier_return_record(r.id) as data
      from public.supplier_returns r
      where r.device_id = q.device_id and r.archived_at is null and r.status in ('requested', 'approved', 'returned')
      order by r.requested_at desc, r.id desc limit 1
    ) active on true), '[]'::jsonb),
    'has_more', (select count(*) > v_limit from matches)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_supplier_return_suppliers() from public, anon, authenticated;
revoke all on function public.search_supplier_return_devices(uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.get_supplier_return_suppliers() to authenticated;
grant execute on function public.search_supplier_return_devices(uuid, text, integer, integer) to authenticated;

create table if not exists greenloop_private.stock_return_page_installation (
  object_identity text primary key,
  definition_hash text not null
);
revoke all on greenloop_private.stock_return_page_installation from public, anon, authenticated;

create or replace function public.get_greenloop_stock_return_page_version()
returns text language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  m record;
begin
  if public.get_greenloop_supplier_returns_version() is distinct from '20260925-supplier-returns-1' then return null; end if;
  if (select count(*) from greenloop_private.stock_return_page_installation) <> 3 then return null; end if;
  for m in select * from greenloop_private.stock_return_page_installation loop
    if to_regprocedure(m.object_identity) is null then return null; end if;
    if md5(pg_get_functiondef(to_regprocedure(m.object_identity))) is distinct from m.definition_hash then return null; end if;
  end loop;
  if has_function_privilege('anon', 'public.get_supplier_return_suppliers()', 'execute')
    or has_function_privilege('anon', 'public.search_supplier_return_devices(uuid,text,integer,integer)', 'execute')
    or not has_function_privilege('authenticated', 'public.get_supplier_return_suppliers()', 'execute')
    or not has_function_privilege('authenticated', 'public.search_supplier_return_devices(uuid,text,integer,integer)', 'execute')
    or has_table_privilege('authenticated', 'greenloop_private.stock_return_page_installation', 'select,insert,update,delete')
    or has_table_privilege('anon', 'greenloop_private.stock_return_page_installation', 'select,insert,update,delete') then return null; end if;
  return '20260926-stock-return-page-1';
end;
$$;

revoke all on function public.get_greenloop_stock_return_page_version() from public, anon, authenticated;
grant execute on function public.get_greenloop_stock_return_page_version() to anon, authenticated;
delete from greenloop_private.stock_return_page_installation;
insert into greenloop_private.stock_return_page_installation(object_identity, definition_hash)
select n.nspname || '.' || p.proname || '(' || oidvectortypes(p.proargtypes) || ')', md5(pg_get_functiondef(p.oid))
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'get_supplier_return_suppliers', 'search_supplier_return_devices', 'get_greenloop_stock_return_page_version'
);
do $$
begin
  if public.get_greenloop_stock_return_page_version() is distinct from '20260926-stock-return-page-1' then
    raise exception 'Stock Return page installation verification failed. No changes were installed.' using errcode = '55000';
  end if;
end;
$$;
notify pgrst, 'reload schema';
commit;
select public.get_greenloop_stock_return_page_version() as installed_stock_return_page_version;
