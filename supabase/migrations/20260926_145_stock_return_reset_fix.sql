-- Current Stock Return reporting after Restricted Data deletion/reset.
-- This adds a read-only view API. Permanent return/deletion audit is preserved.
begin;
do $$
begin
  if to_regprocedure('public.get_greenloop_simple_stock_return_version()') is null then
    raise exception 'Install the Simple Stock Return update before this reporting correction.' using errcode='55000';
  end if;
  if public.get_greenloop_simple_stock_return_version() is distinct from '20260926-simple-stock-return-1' then
    raise exception 'The Simple Stock Return database update could not be verified. No changes were installed.' using errcode='55000';
  end if;
end;
$$;

create or replace function public.list_active_stock_returns(p_from date default null,p_to date default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_result jsonb;
begin
  -- The historical API retains the existing permissions, name masking,
  -- original receipt identity, actor, and Dubai return-date range semantics.
  -- Only the current unit membership and its summaries are replaced below.
  with history as (
    select value as data from jsonb_array_elements(public.list_simple_stock_returns(p_from,p_to))
  ), current_groups as (
    select h.data || jsonb_build_object(
      'returned_quantity',units.quantity,
      'return_ids',units.return_ids,
      'return_numbers',units.return_numbers,
      'imeis',units.imeis,
      'model',units.model,
      'storage_gb',units.storage_gb,
      'storage_label',units.storage_label,
      'archived',false
    ) as data,
    (h.data->>'returned_at')::timestamptz as returned_at,
    h.data->>'group_id' as group_id
    from history h
    cross join lateral (
      select count(*)::integer as quantity,
        jsonb_agg(u.id order by u.unit_order) as return_ids,
        jsonb_agg(u.return_number order by u.unit_order) as return_numbers,
        coalesce(jsonb_agg(u.imei_1 order by u.unit_order) filter(where u.imei_1 is not null),'[]'::jsonb) as imeis,
        case when count(*) filter(where nullif(u.model,'') is null)>0 then null
          when count(distinct lower(u.model))=1 then min(u.model) else 'Mixed' end as model,
        case when count(*) filter(where u.storage_gb is null)=0 and count(distinct u.storage_gb)=1
          then min(u.storage_gb) else null end as storage_gb,
        case when count(*) filter(where u.storage_gb is null)>0 then null
          when count(distinct u.storage_gb)=1 then min(u.storage_gb)::text||' GB' else 'Mixed' end as storage_label
      from (
        select r.id,r.return_number,r.imei_1,r.model,ids.unit_order,
          coalesce(nullif(r.source_snapshot->>'storage_gb','')::integer,d.storage_gb,p.storage_gb) as storage_gb
        from jsonb_array_elements_text(h.data->'return_ids') with ordinality as ids(return_id,unit_order)
        join public.supplier_returns r on r.id=ids.return_id::uuid
        left join public.devices d on d.id=r.device_id
        left join public.jobs j on j.id=r.job_id
        left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
        where r.archived_at is null and r.status='returned'
          and (r.device_id is null or (d.id is not null and d.deleted_at is null))
          and (r.job_id is null or (j.id is not null and j.deleted_at is null))
      ) u
    ) units
    where units.quantity>0
  )
  select coalesce(jsonb_agg(data order by returned_at desc,group_id),'[]'::jsonb) into v_result
  from current_groups;
  return v_result;
end;
$$;

revoke all on function public.list_active_stock_returns(date,date) from public,anon,authenticated;
grant execute on function public.list_active_stock_returns(date,date) to authenticated;

create table if not exists greenloop_private.stock_return_reset_installation (
  object_identity text primary key,
  definition_hash text not null
);
revoke all on greenloop_private.stock_return_reset_installation from public,anon,authenticated;

create or replace function public.get_greenloop_stock_return_reset_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare m record;
begin
  if public.get_greenloop_simple_stock_return_version() is distinct from '20260926-simple-stock-return-1' then return null; end if;
  if (select count(*) from greenloop_private.stock_return_reset_installation)<>2 then return null; end if;
  for m in select * from greenloop_private.stock_return_reset_installation loop
    if to_regprocedure(m.object_identity) is null then return null; end if;
    if md5(pg_get_functiondef(to_regprocedure(m.object_identity))) is distinct from m.definition_hash then return null; end if;
  end loop;
  if has_function_privilege('anon','public.list_active_stock_returns(date,date)','execute')
    or not has_function_privilege('authenticated','public.list_active_stock_returns(date,date)','execute')
    or has_table_privilege('anon','greenloop_private.stock_return_reset_installation','select,insert,update,delete')
    or has_table_privilege('authenticated','greenloop_private.stock_return_reset_installation','select,insert,update,delete') then return null; end if;
  return '20260926-stock-return-reset-1';
end;
$$;
revoke all on function public.get_greenloop_stock_return_reset_version() from public,anon,authenticated;
grant execute on function public.get_greenloop_stock_return_reset_version() to anon,authenticated;

delete from greenloop_private.stock_return_reset_installation;
insert into greenloop_private.stock_return_reset_installation(object_identity,definition_hash)
select n.nspname||'.'||p.proname||'('||oidvectortypes(p.proargtypes)||')',md5(pg_get_functiondef(p.oid))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('list_active_stock_returns','get_greenloop_stock_return_reset_version');
do $$
begin
  if public.get_greenloop_stock_return_reset_version() is distinct from '20260926-stock-return-reset-1' then
    raise exception 'Stock Return reporting correction could not be verified. No changes were installed.' using errcode='55000';
  end if;
end;
$$;
notify pgrst,'reload schema';
commit;
select public.get_greenloop_stock_return_reset_version() as installed_stock_return_reset_version;
