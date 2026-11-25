-- Compare recorded Lab handovers with the corresponding Final QC receive scans.
begin;
set local lock_timeout = '5s';

do $permissions$
begin
  if not exists (
    select 1 from greenloop_private.page_capability_catalog
    where page_key = 'reports' and capabilities @> '[{"key":"report_lab_qc_handover"}]'
  ) then
    insert into greenloop_private.user_page_capabilities(user_id,capabilities)
    select id,greenloop_private.user_capabilities(id) from public.user_profiles
    on conflict(user_id) do nothing;
    update greenloop_private.page_capability_catalog
    set capabilities = capabilities || '[
      {"key":"report_lab_qc_handover","label":"View Lab to Final QC Handover","write":false},
      {"key":"report_lab_qc_handover_search","label":"Change handover report dates and times","write":false}
    ]'::jsonb where page_key = 'reports';
    update greenloop_private.user_page_capabilities a
    set capabilities = jsonb_set(a.capabilities,'{reports}',(a.capabilities->'reports') ||
      '["report_lab_qc_handover","report_lab_qc_handover_search"]'::jsonb)
    where a.capabilities->'reports' ? 'view' and exists (
      select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
      where ur.user_id = a.user_id and r.role_key::text in ('owner','super_admin')
    );
  end if;
end;
$permissions$;

insert into greenloop_private.report_access_sections(report_key,config)
values ('lab_qc_handover','{"label":"Lab to Final QC Handover","view":"report_lab_qc_handover",
  "actions":["report_lab_qc_handover_search"],"search":"report_lab_qc_handover_search"}')
on conflict(report_key) do nothing;
insert into greenloop_private.report_access_dependencies(capability,required_views)
values ('report_lab_qc_handover_search','"report_lab_qc_handover"') on conflict(capability) do nothing;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_lab_qc_handover_v1','{"page":"reports","capability":"report_lab_qc_handover","read":true}'),
  ('get_lab_qc_handover_version','{"read":true}')
on conflict(rpc_name) do nothing;
update greenloop_private.page_capability_installation set hash = case identity
  when 'catalog' then (select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
  when 'rules' then (select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
  end where identity in ('catalog','rules');
update greenloop_private.report_access_config_seal set
  sections_hash = (select md5(jsonb_agg(to_jsonb(s) order by report_key)::text) from greenloop_private.report_access_sections s),
  dependencies_hash = (select md5(jsonb_agg(to_jsonb(d) order by capability)::text) from greenloop_private.report_access_dependencies d)
where singleton;

create index if not exists lab_qc_handover_event_match_idx on public.device_events
  (job_id,device_id,(event_data->>'final_qc_step_id'),created_at,id)
  where event_type in ('laboratory_completed','final_qc_received');
create index if not exists lab_qc_handover_receipt_time_idx on public.device_events (created_at)
  where event_type = 'final_qc_received';

create or replace function public.get_lab_qc_handover_v1(
  p_from timestamp default null, p_to timestamp default null, p_mode text default 'technicians',
  p_technician text default null, p_offset integer default 0, p_as_of timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public
as $report$
declare
  today date := (now() at time zone 'Asia/Dubai')::date;
  snapshot_at timestamptz := coalesce(p_as_of,now());
  from_at timestamptz;
  until_at timestamptz;
  output jsonb;
begin
  perform greenloop_private.rp_require('lab_qc_handover');
  if (p_from is null) <> (p_to is null) or
     (p_from is not null and (not isfinite(p_from) or not isfinite(p_to) or p_from > p_to or p_to::date > today))
     or not isfinite(snapshot_at) or snapshot_at > now()
     or p_mode is null or p_mode not in ('technicians','phones','received','missing','receipts')
     or length(p_technician) > 200 or (p_mode = 'technicians' and p_technician is not null)
     or p_offset is null or p_offset < 0 or mod(p_offset,50) <> 0 then
    raise exception 'Choose a valid UAE date and time range and report page.' using errcode = '22023';
  end if;
  if p_from is not null then
    perform greenloop_private.rp_require('lab_qc_handover','search');
  end if;
  from_at := coalesce(date_trunc('minute',p_from),today::timestamp) at time zone 'Asia/Dubai';
  until_at := least(snapshot_at,
    coalesce(date_trunc('minute',p_to) + interval '1 minute',(today + 1)::timestamp) at time zone 'Asia/Dubai');

  with candidates as (
    select h.id from public.device_events h
    where h.event_type = 'laboratory_completed' and h.event_data ? 'final_qc_step_id'
      and h.created_at >= from_at and h.created_at < until_at
    union
    -- Include receipts for handovers completed before the selected start.
    select h.id from public.device_events r
    join lateral (
      select h.id from public.device_events h
      where h.event_type = 'laboratory_completed' and h.job_id = r.job_id and h.device_id = r.device_id
        and h.event_data->>'final_qc_step_id' = r.event_data->>'final_qc_step_id'
        and h.created_at <= r.created_at
      order by h.created_at desc, h.id limit 1
    ) h on true
    where r.event_type = 'final_qc_received' and r.created_at >= from_at and r.created_at < until_at
  ), handovers as (
    select distinct on (e.job_id,e.device_id,e.event_data->>'final_qc_step_id',e.created_at)
      e.id, e.job_id, e.device_id, e.created_at, e.actor_id,
      e.event_data->>'final_qc_step_id' final_step, s.id source_step
    from candidates c join public.device_events e on e.id = c.id
    join public.jobs j on j.id = e.job_id and j.device_id = e.device_id and j.deleted_at is null
    join public.devices d on d.id = e.device_id and d.deleted_at is null
    join public.job_work_order_steps s on s.id = case when (e.event_data->>'step_id') ~*
      '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' then (e.event_data->>'step_id')::uuid end
      and s.department in ('laboratory','glass')
    join public.job_work_orders w on w.id = s.work_order_id and w.job_id = e.job_id
    join public.job_work_order_steps f on f.id = case when (e.event_data->>'final_qc_step_id') ~*
      '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' then (e.event_data->>'final_qc_step_id')::uuid end
      and f.work_order_id = w.id and f.department = 'final_qc'
    order by e.job_id,e.device_id,e.event_data->>'final_qc_step_id',e.created_at,e.id
  ), reconciled as materialized (
    select h.*, r.created_at received_at, r.actor_id received_by, h.created_at >= from_at completed_in_range
    from handovers h
    left join lateral (
      select n.created_at from public.device_events n
      where n.event_type = 'laboratory_completed' and n.job_id = h.job_id and n.device_id = h.device_id
        and n.event_data->>'final_qc_step_id' = h.final_step and n.created_at > h.created_at
      order by n.created_at limit 1
    ) newer on true
    left join lateral (
      select r.created_at,r.actor_id from public.device_events r
      where r.event_type = 'final_qc_received' and r.job_id = h.job_id and r.device_id = h.device_id
        and r.event_data->>'final_qc_step_id' = h.final_step and r.created_at >= h.created_at
        and r.created_at < least(until_at,newer.created_at)
      order by r.created_at,r.id limit 1
    ) r on true
    where h.created_at >= from_at or r.created_at >= from_at
  ), attributed as materialized (
    select h.*,
      coalesce(t.employee_id::text,'name:'||greenloop_private.ed_key(t.employee_name),'unrecorded') technician_key,
      coalesce(roster.full_name,t.employee_name,'Technician not recorded') technician
    from reconciled h
    left join lateral greenloop_private.technician_work_employee(h.job_id,h.source_step,h.created_at) t on true
    left join public.technician_roster roster on roster.id = t.employee_id
  ), totals as (
    select count(*) filter (where completed_in_range) completed,
      count(*) filter (where completed_in_range and received_at is not null) received,
      count(*) filter (where completed_in_range and received_at is null) missing,
      count(*) filter (where received_at >= from_at) receipts
    from attributed
  ), technicians as materialized (
    select technician_key,min(technician) technician,
      count(*) filter (where completed_in_range) completed,
      count(*) filter (where completed_in_range and received_at is not null) received,
      count(*) filter (where completed_in_range and received_at is null) missing,
      count(*) filter (where received_at >= from_at) receipts
    from attributed where p_mode = 'technicians' group by technician_key
  ), phones as materialized (
    select * from attributed
    where p_mode <> 'technicians' and (p_technician is null or technician_key = p_technician)
      and case p_mode when 'received' then completed_in_range and received_at is not null
                      when 'missing' then completed_in_range and received_at is null
                      when 'receipts' then received_at >= from_at else completed_in_range end
  ), visible_phones as (
    select p.id,p.technician,p.created_at completed_at,p.received_at,d.imei_1::text imei,d.model,d.storage_gb,
      coalesce(nullif(btrim(done.full_name),''),'User not recorded') completed_by,
      case when p.received_at is not null then coalesce(nullif(btrim(qc.full_name),''),'User not recorded') end received_by,
      greatest(0,floor(extract(epoch from (coalesce(p.received_at,until_at)-p.created_at))))::bigint elapsed_seconds
    from (
      select * from phones
      order by case when p_mode='receipts' then received_at else created_at end desc,id
      limit 50 offset p_offset
    ) p
    join public.devices d on d.id = p.device_id
    left join public.user_profiles done on done.id = p.actor_id
    left join public.user_profiles qc on qc.id = p.received_by
  )
  select jsonb_build_object(
    'version','20261125-lab-qc-handover-1','as_of',snapshot_at,'offset',p_offset,'mode',p_mode,
    'totals',(select to_jsonb(t) from totals t),
    'total',case when p_mode = 'technicians' then (select count(*) from technicians) else (select count(*) from phones) end,
    'rows',coalesce(case when p_mode = 'technicians' then (
      select jsonb_agg(to_jsonb(t) order by missing desc,lower(technician),technician_key)
      from (select * from technicians order by missing desc,lower(technician),technician_key limit 50 offset p_offset) t
    ) else (
      select jsonb_agg(to_jsonb(p) order by case when p_mode='receipts' then received_at else completed_at end desc,id)
      from visible_phones p
    ) end,'[]'::jsonb)
  ) into output;
  return output;
end;
$report$;

revoke all on function public.get_lab_qc_handover_v1(timestamp,timestamp,text,text,integer,timestamptz) from public,anon,authenticated;
grant execute on function public.get_lab_qc_handover_v1(timestamp,timestamp,text,text,integer,timestamptz) to authenticated;

create or replace function public.get_lab_qc_handover_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when
    not has_function_privilege('anon','public.get_lab_qc_handover_v1(timestamp,timestamp,text,text,integer,timestamptz)','EXECUTE')
    and has_function_privilege('authenticated','public.get_lab_qc_handover_v1(timestamp,timestamp,text,text,integer,timestamptz)','EXECUTE')
    and exists (select 1 from greenloop_private.report_access_sections
      where report_key='lab_qc_handover' and config->>'view'='report_lab_qc_handover')
    and exists (select 1 from greenloop_private.capability_rpc_rules
      where rpc_name='get_lab_qc_handover_v1' and rule->>'capability'='report_lab_qc_handover')
  then '20261125-lab-qc-handover-1' end;
$version$;
revoke all on function public.get_lab_qc_handover_version() from public,anon,authenticated;
grant execute on function public.get_lab_qc_handover_version() to anon,authenticated;
do $verify$
begin
  if public.get_lab_qc_handover_version() is distinct from '20261125-lab-qc-handover-1' then
    raise exception 'Lab to Final QC Handover report installation failed verification.';
  end if;
end;
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_lab_qc_handover_version() as installed_lab_qc_handover_version;
