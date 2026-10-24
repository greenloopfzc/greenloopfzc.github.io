-- Read-only Lab / Glass waiting-age report and historical delay evidence.
begin;
do $$begin if public.get_box_recheck_version() is distinct from '20261024-box-recheck-1' then raise exception 'Verified Box Recheck must be installed first.';end if;if to_regprocedure('public.get_lab_delay_version()') is not null then if public.get_lab_delay_version() is distinct from '20261024-lab-delay-1' then raise exception 'Existing Lab Delay installation needs review.';end if;end if;end;$$;
create index if not exists greenloop_lab_delay_movements_idx on public.device_location_history(job_id,moved_at);

create or replace function greenloop_private.require_lab_delay_cap(p_page text,p_cap text) returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if p_page not in ('overview','imei_search','ready_stock_journey') or greenloop_private.damage_tv_only(auth.uid()) or not coalesce(public.has_page_capability_v1(p_page,p_cap),false) then raise exception 'This report is not allowed for your account.' using errcode='42501';end if;
end;$$;

-- A stay starts at a recorded external -> LAB/GLASS movement and ends at the
-- first LAB/GLASS -> external movement. Internal transfers and reassignment do
-- not restart it. Repeated entry records without an exit describe the same stay.
create or replace function greenloop_private.lab_stays_v1(p_device uuid default null)
returns table(device_id uuid,job_id uuid,entered_at timestamptz,exited_at timestamptz,elapsed_seconds numeric,ongoing boolean)
language sql stable security definer set search_path=pg_catalog,public as $$
 with movements as materialized (
 select h.device_id,h.job_id,h.moved_at,
 coalesce(f.location_code in ('LAB','GLASS'),false) from_lab,t.location_code in ('LAB','GLASS') to_lab
 from public.device_location_history h join public.locations t on t.id=h.to_location_id left join public.locations f on f.id=h.from_location_id
 join public.jobs j on j.id=h.job_id and j.deleted_at is null join public.devices d on d.id=h.device_id and d.deleted_at is null
 where (p_device is null or h.device_id=p_device) and h.moved_at<=now()
 ), entries as (
 select e.device_id,e.job_id,e.moved_at,(select min(x.moved_at) from movements x where x.job_id=e.job_id and x.device_id=e.device_id and x.from_lab and not x.to_lab and x.moved_at>=e.moved_at) ended
 from movements e where e.to_lab and not e.from_lab
 ), stays as(select e.device_id,e.job_id,min(e.moved_at) arrived,e.ended from entries e group by e.device_id,e.job_id,e.ended)
 select s.device_id,s.job_id,s.arrived,s.ended,extract(epoch from coalesce(s.ended,now())-s.arrived),s.ended is null
 from stays s join public.jobs j on j.id=s.job_id join public.devices d on d.id=s.device_id
 where s.ended is not null or (
 j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress') and d.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
 and j.id=(select latest.id from public.jobs latest where latest.device_id=d.id and latest.deleted_at is null order by latest.created_at desc,latest.id desc limit 1));
$$;

create or replace function public.get_lab_overdue_v1(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_key text default 'elapsed_seconds',p_sort_direction text default 'desc') returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare f date;t date;s text;dep text;tech text;model_filter text;result jsonb;begin
 perform greenloop_private.require_lab_delay_cap('overview','view');
 if jsonb_typeof(p_filters) is distinct from 'object' or exists(select 1 from jsonb_object_keys(p_filters) k where k not in ('_from','_to','_search','department','technician_name','model')) or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or p_sort_key is null or p_sort_key not in ('elapsed_seconds','entered_at','imei','model','storage_gb','color','technician_name','department') or p_sort_direction is null or p_sort_direction not in ('asc','desc') then raise exception 'Select valid report filters and sorting.' using errcode='22023';end if;
 if p_filters<>'{}' then perform greenloop_private.require_lab_delay_cap('overview','search');end if;
 if p_sort_key<>'elapsed_seconds' or p_sort_direction<>'desc' then perform greenloop_private.require_lab_delay_cap('overview','sort');end if;
 f:=nullif(p_filters->>'_from','')::date;t:=nullif(p_filters->>'_to','')::date;s:=lower(btrim(coalesce(p_filters->>'_search','')));dep:=nullif(p_filters->>'department','');tech:=nullif(p_filters->>'technician_name','');model_filter:=nullif(p_filters->>'model','');
 if f>t or length(s)>120 or dep is not null and dep not in ('Laboratory','Glass') then raise exception 'Select valid dates and department.' using errcode='22023';end if;
 with overdue as materialized(
 select distinct on(st.device_id) st.device_id,st.job_id,d.imei_1 imei,d.device_number,d.model,d.storage_gb,d.color,
 coalesce(nullif(to_jsonb(j)->>'company_final_grade',''),nullif(to_jsonb(j)->>'company_initial_grade',''),nullif(to_jsonb(j)->>'supplier_grade',''),d.original_grade) grade,
 case when j.current_status in ('glass_pending','glass_in_progress') then 'Glass' else 'Laboratory' end department,
 coalesce((select string_agg(distinct coalesce(nullif(btrim(step.assigned_technician_name),''),nullif(btrim(roster.full_name),''),nullif(btrim(profile.full_name),'')),', ' order by coalesce(nullif(btrim(step.assigned_technician_name),''),nullif(btrim(roster.full_name),''),nullif(btrim(profile.full_name),''))) from public.job_work_orders wo join public.job_work_order_steps step on step.work_order_id=wo.id left join public.technician_roster roster on roster.id=step.assigned_technician_roster_id left join public.user_profiles profile on profile.id=step.assigned_technician_id where wo.job_id=j.id and step.department=case when j.current_status in ('glass_pending','glass_in_progress') then 'glass'::public.work_department else 'laboratory'::public.work_department end and step.step_status in ('pending','in_progress')),'Unassigned') technician_name,
 st.entered_at,st.elapsed_seconds,j.job_number,sp.supplier_code
 from greenloop_private.lab_stays_v1(null) st join public.jobs j on j.id=st.job_id join public.devices d on d.id=st.device_id left join public.suppliers sp on sp.id=j.supplier_id
 where st.ongoing and st.elapsed_seconds>=172800 order by st.device_id,st.entered_at desc,st.job_id
 ),q as materialized(select * from overdue where (f is null or (entered_at at time zone 'Asia/Dubai')::date>=f) and(t is null or(entered_at at time zone 'Asia/Dubai')::date<=t) and (s='' or strpos(lower(concat_ws(' ',imei,device_number,model,storage_gb,color,grade,technician_name,supplier_code,job_number)),s)>0) and(dep is null or department=dep) and(tech is null or technician_name=tech) and(model_filter is null or model=model_filter)),
 page_rows as(select * from q order by
 case when p_sort_key='elapsed_seconds' and p_sort_direction='asc' then elapsed_seconds end asc,case when p_sort_key='elapsed_seconds' and p_sort_direction='desc' then elapsed_seconds end desc,
 case when p_sort_key='entered_at' and p_sort_direction='asc' then entered_at end asc,case when p_sort_key='entered_at' and p_sort_direction='desc' then entered_at end desc,
 case when p_sort_key='storage_gb' and p_sort_direction='asc' then storage_gb end asc nulls last,case when p_sort_key='storage_gb' and p_sort_direction='desc' then storage_gb end desc nulls last,
 case when p_sort_direction='asc' then case p_sort_key when 'imei' then imei when 'model' then model when 'color' then color when 'technician_name' then technician_name when 'department' then department end end asc nulls last,
 case when p_sort_direction='desc' then case p_sort_key when 'imei' then imei when 'model' then model when 'color' then color when 'technician_name' then technician_name when 'department' then department end end desc nulls last,device_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from q),'overdue_total',(select count(*) from overdue),'server_time',now(),'threshold_hours',48,'rows',coalesce((select jsonb_agg(to_jsonb(p)) from page_rows p),'[]'),'facets',jsonb_build_object('department',(select coalesce(jsonb_agg(distinct department),'[]') from overdue),'technician_name',(select coalesce(jsonb_agg(distinct technician_name),'[]') from overdue),'model',(select coalesce(jsonb_agg(distinct model)filter(where model is not null),'[]') from overdue))) into result;return result;
end;$$;

create or replace function public.get_lab_delay_history_v1(p_identifier text,p_page text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;v_device uuid;begin
 if nullif(btrim(p_identifier),'') is null or length(p_identifier)>120 then raise exception 'Select a phone.' using errcode='22023';end if;
 if p_page is null or p_page not in ('imei_search','ready_stock_journey') then raise exception 'Open an authorised device history page.' using errcode='42501';end if;
 perform greenloop_private.require_lab_delay_cap(p_page,'view');
 select d.id into v_device from public.devices d where d.deleted_at is null and (d.id::text=p_identifier or d.imei_1=p_identifier or d.device_number=p_identifier) order by case when d.imei_1=p_identifier then 0 else 1 end,d.id limit 1;
 select jsonb_build_object('device_id',v_device,'threshold_hours',48,'server_time',now(),'stays',coalesce(jsonb_agg(jsonb_build_object('job_number',j.job_number,'entered_at',s.entered_at,'exited_at',s.exited_at,'elapsed_seconds',s.elapsed_seconds,'ongoing',s.ongoing) order by s.entered_at desc),'[]')) into result from greenloop_private.lab_stays_v1(v_device) s join public.jobs j on j.id=s.job_id where v_device is not null and s.elapsed_seconds>=172800;
 return result;
end;$$;

insert into greenloop_private.capability_rpc_rules values('get_lab_overdue_v1','{"page":"overview","capability":"view","read":true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_lab_delay_history_v1','{"dynamic":"filter_source","parameter":"p_page","imei_search":{"page":"imei_search","capability":"view","read":true},"ready_stock_journey":{"page":"ready_stock_journey","capability":"view","read":true}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r) where identity='rules';
-- Register the added APIs with the existing office boundary and its audit snapshots.
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid) ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_lab_overdue_v1','get_lab_delay_history_v1') loop
  impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');
  impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);
  select coalesce(string_agg('$'||i,',' order by i),'') into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s) returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's' then 'stable' else 'volatile' end,body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid))) on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
 revoke all on function greenloop_private.require_lab_delay_cap(text,text),greenloop_private.lab_stays_v1(uuid) from public,anon,authenticated;
end;$wrap$;
create table if not exists greenloop_private.lab_delay_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_delay_installation enable row level security;
revoke all on greenloop_private.lab_delay_installation from public,anon,authenticated;
insert into greenloop_private.lab_delay_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where (p.pronamespace='public'::regnamespace and p.proname in ('get_lab_overdue_v1','get_lab_delay_history_v1')) or(p.pronamespace='greenloop_private'::regnamespace and p.proname in ('require_lab_delay_cap','lab_stays_v1')) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_lab_delay_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_office_access_version()='20261024-office-access-1' and public.get_box_recheck_version()='20261024-box-recheck-1'
 and (select count(*)=4 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.lab_delay_installation)
 and not has_table_privilege('authenticated','greenloop_private.lab_delay_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.lab_delay_installation where identity like 'greenloop_private.%' and (has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE') or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261024-lab-delay-1' end;$$;
revoke all on function public.get_lab_delay_version() from public;grant execute on function public.get_lab_delay_version() to anon,authenticated;
do $$begin if public.get_lab_delay_version() is distinct from '20261024-lab-delay-1' then raise exception 'Lab Delay installation verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_lab_delay_version() as installed_lab_delay_version;
