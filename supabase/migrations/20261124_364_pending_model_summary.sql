-- Read the operational queues without loading individual phone details.
begin;

create or replace function public.get_pending_model_summary_v1(p_stage text, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog
as $body$
declare
  summary jsonb;
begin
  if p_stage is null or p_stage not in ('initial_qc','qc_issuance','lab_glass','frame_department','final_qc') then
    raise exception 'Choose a valid pending queue.' using errcode = '22023';
  end if;
  perform greenloop_private.pf_cap(p_stage, 'view');
  if p_offset is null or p_offset < 0 or p_offset % 50 <> 0 then
    raise exception 'Choose a valid model summary page.' using errcode = '22023';
  end if;

  with queue_jobs as (
    -- Saved inspections move from the Initial QC tray into Issuance.
    select j.id, j.device_id
    from public.jobs j
    where p_stage = 'initial_qc'
      and j.deleted_at is null and j.current_status = 'initial_qc_pending'
      and not exists (
        select 1 from greenloop_private.qc_saved_issuance s
        where s.job_id = j.id and s.state = 'awaiting_issuance'
      )
    union all
    select j.id, s.device_id
    from greenloop_private.qc_saved_issuance s
    join public.jobs j on j.id = s.job_id
    join public.initial_qc_inspections i on i.id = s.inspection_id and i.job_id = j.id
    where p_stage = 'qc_issuance'
      and s.state = 'awaiting_issuance'
      and j.deleted_at is null and j.current_status = 'initial_qc_pending'
    union all
    select distinct j.id, w.device_id
    from public.job_work_order_steps s
    join public.job_work_orders w on w.id = s.work_order_id
    join public.jobs j on j.id = w.job_id and j.deleted_at is null
    where s.step_status = 'in_progress'
      and (
        (p_stage = 'lab_glass' and s.department in ('laboratory','glass')
          and j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress'))
        or (p_stage = 'frame_department' and s.department = 'frame')
        or (p_stage = 'final_qc' and s.department = 'final_qc' and j.current_status in ('final_qc_pending','qc_failed'))
      )
  ), groups as materialized (
    select min(nullif(btrim(d.model), '')) as model, d.storage_gb, count(distinct d.id) as quantity
    from queue_jobs q
    join public.devices d on d.id = q.device_id and d.deleted_at is null
    where greenloop_private.company_job_available(q.id)
    group by lower(nullif(btrim(d.model), '')), d.storage_gb
  )
  select jsonb_build_object(
    'stage', p_stage,
    'offset', p_offset,
    'group_count', (select count(*) from groups),
    'total', (select coalesce(sum(quantity), 0) from groups),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(p) order by lower(model) nulls last, storage_gb nulls last)
      from (
        select * from groups
        order by lower(model) nulls last, storage_gb nulls last
        limit 50 offset p_offset
      ) p
    ), '[]'::jsonb)
  ) into summary;

  return summary;
end;
$body$;

revoke all on function public.get_pending_model_summary_v1(text,integer) from public, anon, authenticated;
grant execute on function public.get_pending_model_summary_v1(text,integer) to authenticated;

create or replace function public.get_pending_model_summary_version()
returns text
language sql stable security definer set search_path = pg_catalog
as $body$
  select case when
    not has_function_privilege('anon','public.get_pending_model_summary_v1(text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.get_pending_model_summary_v1(text,integer)','EXECUTE')
    and position('greenloop_private.pf_cap(p_stage, ''view'')'
      in pg_get_functiondef('public.get_pending_model_summary_v1(text,integer)'::regprocedure)) > 0
    and position('count(distinct d.id)'
      in pg_get_functiondef('public.get_pending_model_summary_v1(text,integer)'::regprocedure)) > 0
  then '20261124-pending-model-summary-1' end;
$body$;
revoke all on function public.get_pending_model_summary_version() from public, anon, authenticated;
grant execute on function public.get_pending_model_summary_version() to anon, authenticated;

do $verify$
begin
  if public.get_pending_model_summary_version() is distinct from '20261124-pending-model-summary-1' then
    raise exception 'Pending Model Summary installation failed verification.';
  end if;
end;
$verify$;

notify pgrst, 'reload schema';
commit;
select public.get_pending_model_summary_version() as installed_pending_model_summary_version;
