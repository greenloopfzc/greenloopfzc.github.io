-- Summarize the active Lab & Glass technician board without returning phone identifiers.
begin;

create or replace function public.get_lab_technician_stock_summary_v1(p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog
as $body$
declare
  summary jsonb;
begin
  perform greenloop_private.pf_cap('lab_glass', 'view');
  if p_offset is null or p_offset < 0 or p_offset % 50 <> 0 then
    raise exception 'Choose a valid technician stock page.' using errcode = '22023';
  end if;

  with pending_steps as materialized (
    select j.device_id, s.assigned_technician_roster_id, s.assigned_technician_name
    from public.job_work_order_steps s
    join public.job_work_orders w on w.id = s.work_order_id
    join public.jobs j on j.id = w.job_id
    where s.department in ('laboratory', 'glass') and s.step_status = 'in_progress'
      and j.current_status in ('laboratory_pending', 'laboratory_in_progress', 'glass_pending', 'glass_in_progress')
      and j.deleted_at is null and greenloop_private.company_job_available(j.id)
  ), model_groups as (
    select coalesce(t.id, '00000000-0000-0000-0000-000000000000'::uuid) as technician_id,
      coalesce(t.full_name, 'Unassigned') as technician,
      min(nullif(btrim(d.model), '')) as model, d.storage_gb, count(distinct d.id) as quantity
    from pending_steps p
    join public.devices d on d.id = p.device_id and d.deleted_at is null
    left join public.technician_roster t on t.is_active
      and greenloop_private.ed_matches(p.assigned_technician_roster_id, p.assigned_technician_name, t.id, t.full_name)
    group by t.id, t.full_name, lower(nullif(btrim(d.model), '')), d.storage_gb
  ), groups as materialized (
    select *, sum(quantity) over (partition by technician_id) as technician_total
    from model_groups
  )
  select jsonb_build_object(
    'stage', 'lab_technician_stock',
    'offset', p_offset,
    'group_count', (select count(*) from groups),
    'total', (select coalesce(sum(quantity), 0) from groups),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(p) order by lower(technician), technician_id, lower(model) nulls last, storage_gb nulls last)
      from (
        select * from groups
        order by lower(technician), technician_id, lower(model) nulls last, storage_gb nulls last
        limit 50 offset p_offset
      ) p
    ), '[]'::jsonb)
  ) into summary;

  return summary;
end;
$body$;

revoke all on function public.get_lab_technician_stock_summary_v1(integer) from public, anon, authenticated;
grant execute on function public.get_lab_technician_stock_summary_v1(integer) to authenticated;

create or replace function public.get_lab_technician_stock_summary_version()
returns text
language sql stable security definer set search_path = pg_catalog
as $body$
  select case when
    not has_function_privilege('anon','public.get_lab_technician_stock_summary_v1(integer)','EXECUTE')
    and has_function_privilege('authenticated','public.get_lab_technician_stock_summary_v1(integer)','EXECUTE')
    and position('greenloop_private.pf_cap(''lab_glass'', ''view'')'
      in pg_get_functiondef('public.get_lab_technician_stock_summary_v1(integer)'::regprocedure)) > 0
    and position('count(distinct d.id)'
      in pg_get_functiondef('public.get_lab_technician_stock_summary_v1(integer)'::regprocedure)) > 0
  then '20261125-lab-technician-stock-1' end;
$body$;
revoke all on function public.get_lab_technician_stock_summary_version() from public, anon, authenticated;
grant execute on function public.get_lab_technician_stock_summary_version() to anon, authenticated;

do $verify$
begin
  if public.get_lab_technician_stock_summary_version() is distinct from '20261125-lab-technician-stock-1' then
    raise exception 'Lab Technician Stock installation failed verification.';
  end if;
end;
$verify$;

notify pgrst, 'reload schema';
commit;
select public.get_lab_technician_stock_summary_version() as installed_lab_technician_stock_version;
