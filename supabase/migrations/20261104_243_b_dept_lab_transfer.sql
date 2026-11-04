-- B-DEPT Pass chooses Ready Stock or an assigned Lab visit. Fail stays in B-DEPT.
begin;
do $$begin if public.get_stock_grade_analysis_version()is distinct from '20261104-stock-grade-analysis-1'then raise exception 'Install verified Stock Grade Analysis first.';end if;end;$$;
do $$begin if to_regprocedure('public.get_b_dept_lab_transfer_version()')is not null then if public.get_b_dept_lab_transfer_version()is distinct from '20261104-b-dept-lab-transfer-1'then raise exception 'Existing B-DEPT Lab Transfer requires review.';end if;end if;end;$$;
-- Reuse the checked Parts submission and Lab service validation under the
-- existing B-DEPT entry grant. Copies are private; the original guards stay intact.
do $copy$declare src regprocedure;ddl text;old_name text;dest text;item text;begin
 foreach item in array array['parts','services']loop
  if item='parts'then src:='greenloop_private.ps_submit_original(uuid,integer,jsonb,jsonb)'::regprocedure;dest:='bdt_parts';else select to_regprocedure(implementation)into src from greenloop_private.office_routines where to_regprocedure(identity)='public.save_lab_services_v1(uuid,integer,jsonb)'::regprocedure;dest:='bdt_services';end if;
  if src is null then raise exception 'Reviewed Parts / Services implementation is missing.';end if;
  ddl:=pg_get_functiondef(src);select proname into old_name from pg_proc where oid=src;
  if strpos(ddl,$guard$perform greenloop_private.pf_cap('lab_glass','entry');$guard$)=0 then raise exception 'Reviewed Parts / Services permission boundary differs.';end if;
  ddl:=replace(ddl,'FUNCTION greenloop_private.'||old_name||'(','FUNCTION greenloop_private.'||dest||'(');
  ddl:=replace(ddl,$guard$perform greenloop_private.pf_cap('lab_glass','entry');$guard$,$guard$perform greenloop_private.pf_cap('frame_department','entry');$guard$);execute ddl;
 end loop;
end;$copy$;
create or replace function public.get_b_dept_lab_options_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('frame_department','view');
 return jsonb_build_object('technicians',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',upper(full_name))order by upper(full_name),id)from public.technician_roster where is_active),'[]'),
 'parts',coalesce((select jsonb_agg(jsonb_build_object('name',name)order by lower(name))from(select distinct on(greenloop_private.pp_key(option_value))option_value name from public.entry_options where option_group='part_name'and is_active order by greenloop_private.pp_key(option_value),created_at desc)p),'[]'),
 'services',coalesce((select jsonb_agg(jsonb_build_object('name',name)order by lower(name))from greenloop_private.qc_service_options),'[]'),
 'defaults',coalesce((select jsonb_agg(jsonb_build_object('step_id',f.id,'technician_id',t.id))from public.job_work_order_steps f join public.job_work_orders w on w.id=f.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
 join lateral(select r.id from public.job_work_order_steps l join public.technician_roster r on r.is_active and greenloop_private.ed_matches(l.assigned_technician_roster_id,l.assigned_technician_name,r.id,r.full_name)where l.work_order_id=w.id and l.department in('laboratory','glass')order by l.assigned_at desc nulls last,l.step_order desc,l.id limit 1)t on true where f.department='frame'and f.step_status='in_progress'),'[]'));
end;$$;
create or replace function public.record_b_dept_result_v2(p_work_order_step_id uuid,p_result text,p_final_grade text,p_final_battery_health integer,p_battery_health_unavailable boolean default false,p_notes text default null,p_destination text default 'ready_stock',p_technician_roster_id uuid default null,p_parts jsonb default '[]',p_services jsonb default '[]')returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare outcome text:=lower(btrim(coalesce(p_result,'')));dest text:=lower(btrim(coalesce(p_destination,'')));v record;f public.final_qc_inspections%rowtype;t public.technician_roster%rowtype;l public.job_work_order_steps%rowtype;final_step uuid;final_order integer;highest integer;lab_location uuid;rid uuid;cycle integer;output jsonb;part jsonb;service text;canonical text;parts jsonb:='[]';services jsonb:='[]';qty integer;seen text[]:='{}';
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('frame_department','entry');
 if outcome not in('pass','fail')or dest not in('ready_stock','lab_glass')then raise exception 'Select Pass or Fail and a valid Pass destination.'using errcode='22023';end if;
 -- Existing Ready Stock validation, audit and old clients are preserved.
 if outcome='fail'or dest='ready_stock'then return public.record_b_dept_result_v1(p_work_order_step_id,outcome,p_final_grade,p_final_battery_health,p_battery_health_unavailable,p_notes)||jsonb_build_object('destination',case when outcome='fail'then 'b_dept'else 'ready_stock'end);end if;
 if jsonb_typeof(p_parts)is distinct from 'array'or jsonb_array_length(p_parts)>100 or jsonb_typeof(p_services)is distinct from 'array'or jsonb_array_length(p_services)>100 then raise exception 'Choose valid B-DEPT parts and services.'using errcode='22023';end if;
 for part in select value from jsonb_array_elements(p_parts)loop
  if jsonb_typeof(part)is distinct from 'object'or coalesce(part->>'quantity','')!~'^[0-9]{1,5}$'then raise exception 'Enter a valid part quantity.'using errcode='22023';end if;qty:=(part->>'quantity')::integer;
  select option_value into canonical from public.entry_options where option_group='part_name'and is_active and greenloop_private.pp_key(option_value)=greenloop_private.pp_key(part->>'name')order by created_at desc,id limit 1;
  if canonical is null or qty not between 1 and 10000 or greenloop_private.pp_key(canonical)=any(seen)then raise exception 'Choose one active part per line and a positive whole quantity.'using errcode='22023';end if;seen:=array_append(seen,greenloop_private.pp_key(canonical));parts:=parts||jsonb_build_array(jsonb_build_object('name',canonical,'quantity',qty));
 end loop;
 for service in select value from jsonb_array_elements_text(p_services)loop
  select name into canonical from greenloop_private.qc_service_options where greenloop_private.pp_key(name)=greenloop_private.pp_key(service)limit 1;
  if canonical is null or services @> jsonb_build_array(canonical)then raise exception 'Choose each saved service once.'using errcode='22023';end if;services:=services||jsonb_build_array(canonical);
 end loop;
 if p_battery_health_unavailable is null or p_final_battery_health is not null and p_final_battery_health not between 0 and 100 then raise exception 'Final Battery Health must be a whole number from 0 to 100.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(20420261026);
 perform greenloop_private.begin_capability('record_frame_department_result_v3',jsonb_build_object('p_work_order_step_id',p_work_order_step_id,'p_result','pass','p_final_grade',p_final_grade,'p_notes',p_notes));begin
  perform public.greenloop_require_entry(array['frame_department']::text[]);
  select s.work_order_id,w.job_id,w.device_id,j.current_location_id,d.device_platform into v from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=w.device_id and d.deleted_at is null where s.id=p_work_order_step_id and s.department='frame'and s.step_status='in_progress'for update of s,j,d;
  if v.job_id is null then raise exception 'This phone is no longer waiting in B-DEPT.'using errcode='22023';end if;
  perform greenloop_private.validate_mobile_battery(v.device_platform,p_final_battery_health::smallint,p_battery_health_unavailable,true);
  select *into t from public.technician_roster where id=p_technician_roster_id and is_active for share;
  if t.id is null then raise exception 'Select an active Lab technician before transferring this phone.'using errcode='22023';end if;
  select *into f from public.final_qc_inspections where job_id=v.job_id and device_id=v.device_id and routed_to_frame order by inspected_at desc limit 1 for update;
  if f.id is null then raise exception 'The routed Final QC record is missing. Review this phone in Reports.'using errcode='22023';end if;
  select id,step_order into final_step,final_order from public.job_work_order_steps where work_order_id=v.work_order_id and department='final_qc'and step_status='pending'for update;
  if final_step is null then raise exception 'The pending Final QC step is missing. Nothing was transferred.'using errcode='22023';end if;
  select id into lab_location from public.locations where location_code='LAB'and is_active limit 1;
  if lab_location is null then raise exception 'The Laboratory location is not configured.'using errcode='22023';end if;
  select *into l from public.job_work_order_steps where work_order_id=v.work_order_id and department='laboratory'for update;
  if l.id is not null and l.step_status='in_progress'then raise exception 'This phone already has an active Lab visit. Review its workflow before transferring it.'using errcode='55000';end if;
  select max(step_order)into highest from public.job_work_order_steps where work_order_id=v.work_order_id;
  if l.id is null then
   update public.job_work_order_steps set step_order=highest+2 where id=final_step;
   insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_technician_roster_id,assigned_technician_name,assigned_at)values(v.work_order_id,highest+1,'laboratory','in_progress',t.id,t.full_name,now())returning *into l;cycle:=0;
  else
   if final_order<=l.step_order then update public.job_work_order_steps set step_order=highest+1 where id=final_step;end if;
   update public.job_work_order_steps set step_status='in_progress',assigned_technician_roster_id=t.id,assigned_technician_name=t.full_name,assigned_technician_id=null,assigned_at=now(),returned_at=null,rework_count=rework_count+1 where id=l.id returning *into l;cycle:=l.rework_count;
  end if;
  if exists(select 1 from public.job_part_requests r join jsonb_array_elements(parts)p on greenloop_private.pp_key(r.part_name)=greenloop_private.pp_key(p->>'name')where r.job_id=v.job_id and r.status<>'cancelled'and(r.quantity_requested>r.quantity_issued or r.quantity_issued-r.quantity_returned-r.quantity_installed>0))then raise exception 'This part is already pending or issued. Return the existing part before ordering it again.'using errcode='22023';end if;
  insert into public.frame_department_results(work_order_step_id,job_id,device_id,result,notes,reviewed_by,final_battery_health,final_battery_health_unavailable,previous_final_battery_health,previous_battery_health_unavailable)
   values(p_work_order_step_id,v.job_id,v.device_id,'pass',concat_ws(' | ','B-DEPT passed to Lab & Glass','Technician: '||upper(t.full_name),nullif(btrim(p_notes),'')),auth.uid(),p_final_battery_health,p_battery_health_unavailable,f.final_battery_health,f.final_battery_health_unavailable)returning id into rid;
  update public.final_qc_inspections set final_battery_health=p_final_battery_health,final_battery_health_unavailable=p_battery_health_unavailable where id=f.id;
  update public.job_work_order_steps set step_status='completed',returned_at=now()where id=p_work_order_step_id;
  update public.job_work_orders set status='open'where id=v.work_order_id;
  insert into public.laboratory_work_records(job_id,device_id,work_order_step_id,rework_cycle,assigned_at,started_at,notes)values(v.job_id,v.device_id,l.id,cycle,now(),now(),'B-DEPT passed; additional Lab work required');
  update public.technician_job_timers set stopped_at=now(),elapsed_seconds=greatest(0,extract(epoch from now()-started_at)::integer),stopped_by=auth.uid()where job_id=v.job_id and stopped_at is null and technician_roster_id is distinct from t.id;
  if not exists(select 1 from public.technician_job_timers where job_id=v.job_id and stopped_at is null and technician_roster_id=t.id)then insert into public.technician_job_timers(job_id,device_id,technician_roster_id,technician_name,started_at)values(v.job_id,v.device_id,t.id,t.full_name,now());end if;
  update public.jobs set current_status='laboratory_pending',current_location_id=lab_location where id=v.job_id;
  update public.devices set current_status='laboratory_pending',current_location_id=lab_location where id=v.device_id;
  insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)values(v.device_id,v.job_id,v.current_location_id,lab_location,'B-DEPT passed to Lab & Glass',auth.uid());
  if jsonb_array_length(parts)>0 then perform greenloop_private.bdt_parts(l.id,0,parts,'[]'::jsonb);end if;
  perform greenloop_private.bdt_services(l.id,coalesce((greenloop_private.ps_service_state(l.id)->>'services_revision')::integer,0),services);
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(v.device_id,v.job_id,'b_dept_passed_lab','B-DEPT passed and sent to Lab & Glass',jsonb_build_object('frame_step_id',p_work_order_step_id,'lab_step_id',l.id,'result_id',rid,'destination','lab_glass','parts',parts,'services',services,'technician_id',t.id,'technician_name',t.full_name,'final_battery_health',p_final_battery_health,'previous_final_battery_health',f.final_battery_health),auth.uid());
  output:=jsonb_build_object('completed',true,'next_status','laboratory_pending','destination','lab_glass','result','pass','result_id',rid,'lab_step_id',l.id,'technician_name',upper(t.full_name),'parts',parts,'services',services);
 exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();return output;
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_b_dept_lab_options_v1','{"page":"frame_department","capability":"view","read":true}'),('record_b_dept_result_v2','{"page":"frame_department","capability":"entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_b_dept_lab_options_v1','record_b_dept_result_v2')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),case when f.provolatile='s'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
revoke all on function greenloop_private.bdt_parts(uuid,integer,jsonb,jsonb),greenloop_private.bdt_services(uuid,integer,jsonb)from public,anon,authenticated;
create table if not exists greenloop_private.b_dept_lab_installation(identity text primary key,hash text not null);alter table greenloop_private.b_dept_lab_installation enable row level security;revoke all on greenloop_private.b_dept_lab_installation from public,anon,authenticated;
create or replace function public.get_b_dept_lab_transfer_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_stock_grade_analysis_version()='20261104-stock-grade-analysis-1'
 and(select count(*)=7 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.b_dept_lab_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.b_dept_lab_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.b_dept_lab_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.b_dept_lab_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.b_dept_lab_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_function_privilege('anon','public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)','EXECUTE')and has_function_privilege('authenticated','public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)','EXECUTE')
 then '20261104-b-dept-lab-transfer-1'end;$$;
revoke all on function public.get_b_dept_lab_transfer_version()from public;grant execute on function public.get_b_dept_lab_transfer_version()to anon,authenticated;
insert into greenloop_private.b_dept_lab_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname in('bdt_parts','bdt_services')or p.pronamespace='public'::regnamespace and p.proname in('get_b_dept_lab_options_v1','record_b_dept_result_v2','get_b_dept_lab_transfer_version')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_b_dept_lab_options_v1()'::regprocedure,'public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_b_dept_lab_transfer_version()is distinct from '20261104-b-dept-lab-transfer-1'then raise exception 'B-DEPT Lab Transfer verification failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_b_dept_lab_transfer_version()as installed_b_dept_lab_transfer_version;
