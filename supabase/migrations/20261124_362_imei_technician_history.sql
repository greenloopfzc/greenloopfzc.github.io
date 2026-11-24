-- Add recorded technician periods to the existing, permission-checked IMEI journey.
begin;
set local lock_timeout = '5s';

create index if not exists imei_technician_assignment_event_idx
  on public.device_events (device_id, job_id)
  where event_type = 'lab_employee_assigned';

create or replace function greenloop_private.imei_technician_periods(p_device uuid)
returns jsonb
language sql stable security invoker
set search_path = pg_catalog
as $body$
  with jobs as materialized (
    select j.id
    from public.jobs j
    where j.device_id = p_device and j.deleted_at is null
  ), timers as materialized (
    select j.id as job_id, h.id as record_id, saved.technician_name,
           saved.started_at, saved.stopped_at, saved.elapsed_seconds, false as running
    from jobs j
    join greenloop_private.technician_timer_handovers h
      on h.job_id = j.id and h.device_id = p_device
    cross join lateral jsonb_to_record(h.closed_timer) as saved(
      technician_name text, started_at timestamptz, stopped_at timestamptz, elapsed_seconds integer
    )
    union all
    select j.id, t.id, t.technician_name, t.started_at, t.stopped_at,
           t.elapsed_seconds, t.stopped_at is null
    from jobs j
    join public.technician_job_timers t on t.job_id = j.id and t.device_id = p_device
  ), assignments as (
    select e.job_id, e.id as record_id, nullif(btrim(e.event_data->>'employee'), '') as technician_name,
           e.created_at as started_at, null::timestamptz as stopped_at, null::integer as elapsed_seconds,
           false as running
    from public.device_events e
    join jobs j on j.id = e.job_id
    where e.device_id = p_device and e.event_type = 'lab_employee_assigned'
      and nullif(btrim(e.event_data->>'employee'), '') is not null
      and not exists (
        select 1 from timers t
        where t.job_id = e.job_id and t.started_at = e.created_at
          and lower(btrim(t.technician_name)) = lower(btrim(e.event_data->>'employee'))
      )
  ), periods as (
    select * from timers
    union all
    select * from assignments
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'technician', technician_name,
    'started_at', started_at,
    'stopped_at', stopped_at,
    'running', running,
    'elapsed_seconds', case
      when stopped_at >= started_at then coalesce(
        case when elapsed_seconds >= 0 then elapsed_seconds end,
        floor(extract(epoch from stopped_at - started_at))
      )
      when running and statement_timestamp() >= started_at
        then floor(extract(epoch from statement_timestamp() - started_at))
    end
  ) order by started_at nulls last, stopped_at nulls last, record_id), '[]'::jsonb)
  from periods;
$body$;
revoke all on function greenloop_private.imei_technician_periods(uuid) from public, anon, authenticated;

do $install$
declare
  signature constant text := 'greenloop_private.ia_read(text)';
  boundary constant text := $pattern$return\s+(greenloop_private\.itc_enrich\([^\r\n]*\))\s*;$pattern$;
  before_ddl text := pg_get_functiondef(signature::regprocedure);
  before_hash text := md5(before_ddl);
  after_hash text;
begin
  if public.get_imei_activity_journey_version() is distinct from '20261109-imei-activity-1'
     or public.get_imei_qc_corrections_version() is distinct from '20261114-imei-qc-corrections-1'
     or public.get_chaman_shop_flow_version() is distinct from '20261113-chaman-section-flow-1' then
    raise exception 'The installed IMEI journey definition could not be verified.';
  end if;

  if position('greenloop_private.imei_technician_periods(d.id)' in before_ddl) = 0 then
    if (select count(*) from regexp_matches(before_ddl, boundary, 'g')) <> 1 then
      raise exception 'The IMEI journey result boundary changed.';
    end if;

    execute regexp_replace(before_ddl, boundary,
      $replacement$return \1 || jsonb_build_object('technician_history', greenloop_private.imei_technician_periods(d.id));$replacement$);
    after_hash := md5(pg_get_functiondef(signature::regprocedure));

    update greenloop_private.imei_activity_installation set hash = after_hash
      where to_regprocedure(identity) = signature::regprocedure and hash = before_hash;
    update greenloop_private.imei_qc_corrections_installation set hash = after_hash
      where to_regprocedure(identity) = signature::regprocedure and hash = before_hash;
    update greenloop_private.chaman_flow_installation set hash = after_hash
      where to_regprocedure(identity) = signature::regprocedure and hash = before_hash;
    update greenloop_private.office_routines set original_hash = after_hash
      where to_regprocedure(implementation) = signature::regprocedure and original_hash = before_hash;
    update greenloop_private.capability_routines set original_hash = after_hash
      where to_regprocedure(implementation) = signature::regprocedure and original_hash = before_hash;
  end if;
end;
$install$;

create or replace function public.get_imei_technician_history_version()
returns text language sql stable security definer
set search_path = pg_catalog, public
as $body$
  select case when public.get_imei_activity_journey_version() = '20261109-imei-activity-1'
    and public.get_imei_qc_corrections_version() = '20261114-imei-qc-corrections-1'
    and public.get_chaman_shop_flow_version() = '20261113-chaman-section-flow-1'
    and position('greenloop_private.imei_technician_periods(d.id)'
      in pg_get_functiondef('greenloop_private.ia_read(text)'::regprocedure)) > 0
    and not has_function_privilege('anon', 'greenloop_private.imei_technician_periods(uuid)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'greenloop_private.imei_technician_periods(uuid)', 'EXECUTE')
  then '20261124-imei-technician-history-1' end;
$body$;
revoke all on function public.get_imei_technician_history_version() from public, anon, authenticated;
grant execute on function public.get_imei_technician_history_version() to anon, authenticated;

do $verify$
begin
  if public.get_imei_technician_history_version() is distinct from '20261124-imei-technician-history-1' then
    raise exception 'IMEI technician history installation failed verification.';
  end if;
end;
$verify$;

notify pgrst, 'reload schema';
commit;
select public.get_imei_technician_history_version() as installed_imei_technician_history_version;
