-- Technician activity by UAE work date, using recorded completions and installations.
begin;
set local lock_timeout='5s';

do $permissions$
begin
  if not exists (
    select 1 from greenloop_private.page_capability_catalog
    where page_key='reports' and capabilities @> '[{"key":"report_technician_work"}]'
  ) then
    insert into greenloop_private.user_page_capabilities(user_id,capabilities)
    select id,greenloop_private.user_capabilities(id) from public.user_profiles
    on conflict(user_id) do nothing;

    update greenloop_private.page_capability_catalog
    set capabilities=capabilities||'[
      {"key":"report_technician_work","label":"View Technician Work Report","write":false},
      {"key":"report_technician_work_search","label":"Change Technician Work report dates","write":false}
    ]'::jsonb where page_key='reports';

    update greenloop_private.user_page_capabilities u
    set capabilities=jsonb_set(u.capabilities,'{reports}',(u.capabilities->'reports')||
      '["report_technician_work","report_technician_work_search"]'::jsonb)
    where u.capabilities->'reports'?'view'
      and exists (
        select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
        where ur.user_id=u.user_id and r.role_key::text in('owner','super_admin')
      );
  end if;
end;
$permissions$;

insert into greenloop_private.report_access_sections(report_key,config)
values ('technician_work','{"label":"Technician Work Report","view":"report_technician_work",
  "actions":["report_technician_work_search"],"search":"report_technician_work_search"}')
on conflict(report_key) do nothing;
insert into greenloop_private.report_access_dependencies(capability,required_views)
values('report_technician_work_search','"report_technician_work"') on conflict(capability) do nothing;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_technician_work_report_v1','{"page":"reports","capability":"report_technician_work","read":true}'),
  ('get_technician_work_report_version','{"read":true}')
on conflict(rpc_name) do nothing;

update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
where identity='catalog';
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';
update greenloop_private.report_access_config_seal
set sections_hash=(select md5(jsonb_agg(to_jsonb(s) order by report_key)::text) from greenloop_private.report_access_sections s),
    dependencies_hash=(select md5(jsonb_agg(to_jsonb(d) order by capability)::text) from greenloop_private.report_access_dependencies d)
where singleton;

create index if not exists technician_work_completion_date_idx
  on public.device_events(created_at) where event_type='laboratory_completed';
create index if not exists technician_work_installed_date_idx
  on public.part_installations(installed_at);
create index if not exists technician_work_service_completion_idx
  on greenloop_private.lab_only_services_audit(created_at,job_id,cycle) where action='lab_completed';
create index if not exists technician_work_timer_history_job_idx
  on greenloop_private.technician_timer_handovers(job_id);

create or replace function greenloop_private.technician_work_employee(
  p_job uuid,p_step uuid,p_at timestamptz
) returns table(employee_id uuid,employee_name text)
language sql stable security definer set search_path=pg_catalog,public as $person$
  with step_at as (
    select s.assigned_technician_roster_id id,s.assigned_technician_name name,s.department
    from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id
    where s.id=p_step and w.job_id=p_job and s.assigned_at<=p_at
  ), timers as (
    select t.technician_roster_id id,t.technician_name name,t.started_at,0 priority
    from public.technician_job_timers t
    where t.job_id=p_job and t.started_at<=p_at and (t.stopped_at is null or t.stopped_at>=p_at)
    union all
    select (h.closed_timer->>'technician_roster_id')::uuid,h.closed_timer->>'technician_name',
           (h.closed_timer->>'started_at')::timestamptz,1
    from greenloop_private.technician_timer_handovers h
    where h.job_id=p_job and (h.closed_timer->>'started_at')::timestamptz<=p_at
      and (h.closed_timer->>'stopped_at')::timestamptz>=p_at
  ), timer_at as (
    select id,name from timers order by started_at desc,priority,id nulls last limit 1
  ), attribution as (
    select id,name,0 priority from step_at where department='frame'
    union all select id,name,1 from timer_at
    union all select id,name,2 from step_at
  ), recorded as (
    select id,nullif(btrim(name),'') name from attribution
    where id is not null or nullif(btrim(name),'') is not null
    order by priority limit 1
  )
  select coalesce(r.id,legacy.id),r.name
  from recorded r
  left join lateral (
    select (array_agg(t.id order by t.id))[1] id
    from public.technician_roster t
    where r.id is null and greenloop_private.ed_key(t.full_name)=greenloop_private.ed_key(r.name)
    having count(*)=1
  ) legacy on true;
$person$;
revoke all on function greenloop_private.technician_work_employee(uuid,uuid,timestamptz)
from public,anon,authenticated;

create or replace function public.get_technician_work_report_v1(
  p_from date default null,p_to date default null,p_offset integer default 0
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $report$
declare
  today date:=(now() at time zone 'Asia/Dubai')::date;
  from_day date:=coalesce(p_from,today);
  to_day date:=coalesce(p_to,today);
  from_at timestamptz;
  until_at timestamptz;
  result jsonb;
begin
  perform greenloop_private.rp_require('technician_work');
  if (p_from is null)<>(p_to is null) or not isfinite(from_day) or not isfinite(to_day)
     or from_day>to_day or to_day>today or p_offset is null or p_offset<0 or mod(p_offset,50)<>0 then
    raise exception 'Choose a valid date range and report page.' using errcode='22023';
  end if;
  if from_day<>today or to_day<>today then
    perform greenloop_private.rp_require('technician_work','search');
  end if;
  from_at:=from_day::timestamp at time zone 'Asia/Dubai';
  until_at:=(to_day+1)::timestamp at time zone 'Asia/Dubai';

  with service_visits as materialized (
    select a.job_id,coalesce(s.step_id,o.step_id) step_id,a.created_at completed_at,a.names
    from greenloop_private.lab_only_services_audit a
    left join greenloop_private.lab_only_services s on s.job_id=a.job_id and s.cycle=a.cycle
    left join greenloop_private.parts_flow_orders o on o.job_id=a.job_id and o.cycle=a.cycle
    where a.action='lab_completed' and a.created_at>=from_at and a.created_at<until_at
    union all
    select s.job_id,s.step_id,s.completed_at,s.names from greenloop_private.lab_only_services s
    where s.completed_at>=from_at and s.completed_at<until_at
      and not exists(select 1 from greenloop_private.lab_only_services_audit a
        where a.job_id=s.job_id and a.cycle=s.cycle and a.action='lab_completed')
  ), activity as (
    select 'job'::text kind,e.job_id,s.id step_id,e.created_at at,null::text item,0 quantity
    from public.device_events e
    join public.job_work_order_steps s on s.id=case when e.event_data->>'step_id'~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
      then (e.event_data->>'step_id')::uuid end
    where e.event_type='laboratory_completed' and e.created_at>=from_at and e.created_at<until_at
    union all
    select 'job',l.job_id,l.work_order_step_id,l.completed_at,null,0
    from public.laboratory_work_records l where l.completed_at>=from_at and l.completed_at<until_at
    union all
    select 'job',g.job_id,g.work_order_step_id,g.completed_at,null,0
    from public.glass_work_records g where g.completed_at>=from_at and g.completed_at<until_at
    union all
    select 'job',b.job_id,b.work_order_step_id,b.reviewed_at,null,0
    from public.frame_department_results b where b.result='pass' and b.reviewed_at>=from_at and b.reviewed_at<until_at
    union all
    select 'part',i.job_id,o.step_id,i.installed_at,r.part_name,i.quantity_installed
    from public.part_installations i
    join public.job_part_requests r on r.id=i.part_request_id and r.job_id=i.job_id and r.device_id=i.device_id
    left join greenloop_private.parts_flow_requests m on m.request_id=r.id
    left join greenloop_private.parts_flow_orders o on o.id=m.order_id and o.job_id=i.job_id
    where i.quantity_installed>0 and i.installed_at>=from_at and i.installed_at<until_at
    union all
    select 'part',i.job_id,i.work_order_step_id,i.installed_at,i.part_name,i.quantity
    from public.lab_manual_part_installations i
    where i.quantity>0 and i.installed_at>=from_at and i.installed_at<until_at
    union all
    select 'service',v.job_id,v.step_id,v.completed_at,min(coalesce(n.value->>'name',n.value#>>'{}')),1
    from service_visits v
    cross join lateral jsonb_array_elements(v.names) n(value)
    where jsonb_typeof(n.value)='string' or (jsonb_typeof(n.value)='object' and n.value?'name')
    group by v.job_id,v.step_id,v.completed_at,greenloop_private.pp_key(coalesce(n.value->>'name',n.value#>>'{}'))
  ), saved as materialized (
    select a.* from activity a join public.jobs j on j.id=a.job_id and j.deleted_at is null
    join public.devices d on d.id=j.device_id and d.deleted_at is null
  ), people_at as materialized (
    select t.*,p.employee_id,p.employee_name
    from (select distinct job_id,step_id,at from saved) t
    left join lateral greenloop_private.technician_work_employee(t.job_id,t.step_id,t.at) p on true
  ), attributed as materialized (
    select a.job_id,a.kind,a.quantity,
      coalesce(p.employee_id::text,'legacy:'||greenloop_private.ed_key(p.employee_name),'unrecorded') employee_key,
      coalesce(r.full_name,p.employee_name,'Technician not recorded') employee_name,
      case when a.kind='part' and regexp_replace(greenloop_private.pp_key(a.item),'[^a-z0-9]','','g') in('housing','housing4g','housing5g') then 'Housing'
           when a.kind='part' and greenloop_private.pp_key(a.item) in('mic','microphone') then 'Mic'
           else nullif(regexp_replace(btrim(a.item),'\s+',' ','g'),'') end item
    from saved a
    join people_at p on p.job_id=a.job_id and p.at=a.at
      and p.step_id is not distinct from a.step_id
    left join public.technician_roster r on r.id=p.employee_id
  ), employees as (
    select employee_key,min(employee_name) name from (
      select id::text employee_key,full_name employee_name from public.technician_roster where is_active
      union all select employee_key,employee_name from attributed
    ) names group by employee_key
  ), completed as (
    select employee_key,count(distinct job_id)::integer quantity from attributed where kind='job' group by employee_key
  ), items as (
    select employee_key,kind,min(item) item,sum(quantity)::bigint quantity from attributed
    where kind in ('part','service') and item is not null
    group by employee_key,kind,greenloop_private.pp_key(item)
  ), breakdown as (
    select employee_key,
      jsonb_agg(jsonb_build_object('name',item,'quantity',quantity) order by lower(item),item) filter(where kind='part') parts,
      jsonb_agg(jsonb_build_object('name',item,'quantity',quantity) order by lower(item),item) filter(where kind='service') services
    from items group by employee_key
  ), page as (
    select e.employee_key,e.name,coalesce(c.quantity,0) completed_jobs,
      coalesce(b.parts,'[]'::jsonb) parts,coalesce(b.services,'[]'::jsonb) services
    from employees e left join completed c using(employee_key) left join breakdown b using(employee_key)
    order by lower(e.name),e.employee_key offset p_offset limit 50
  )
  select jsonb_build_object(
    'from',from_day,'to',to_day,'offset',p_offset,
    'total',(select count(*) from employees),
    'rows',coalesce((select jsonb_agg(to_jsonb(p) order by lower(p.name),p.employee_key) from page p),'[]'::jsonb)
  ) into result;
  return result;
end;
$report$;
revoke all on function public.get_technician_work_report_v1(date,date,integer) from public,anon,authenticated;
grant execute on function public.get_technician_work_report_v1(date,date,integer) to authenticated;

create table if not exists greenloop_private.technician_work_report_installation(identity text primary key,hash text not null);
alter table greenloop_private.technician_work_report_installation enable row level security;
revoke all on greenloop_private.technician_work_report_installation from public,anon,authenticated;
insert into greenloop_private.technician_work_report_installation
select sig,md5(pg_get_functiondef(sig::regprocedure)) from unnest(array[
  'greenloop_private.technician_work_employee(uuid,uuid,timestamptz)',
  'public.get_technician_work_report_v1(date,date,integer)'
]) sig on conflict(identity) do update set hash=excluded.hash;

create or replace function public.get_technician_work_report_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when (select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
                    from greenloop_private.technician_work_report_installation)
    and not has_function_privilege('anon','public.get_technician_work_report_v1(date,date,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.get_technician_work_report_v1(date,date,integer)','EXECUTE')
    and not has_function_privilege('authenticated','greenloop_private.technician_work_employee(uuid,uuid,timestamptz)','EXECUTE')
    and exists(select 1 from greenloop_private.report_access_sections where report_key='technician_work'
      and config->>'view'='report_technician_work' and config->>'search'='report_technician_work_search')
    then '20261123-technician-work-report-1' end;
$version$;
revoke all on function public.get_technician_work_report_version() from public;
grant execute on function public.get_technician_work_report_version() to anon,authenticated;

do $verify$
begin
  if public.get_technician_work_report_version() is distinct from '20261123-technician-work-report-1' then
    raise exception 'Technician Work Report could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_technician_work_report_version() as installed_technician_work_report_version;
