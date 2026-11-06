-- Saved requirements do not prevent B-DEPT routing. B-DEPT only routes work.
begin;
set local statement_timeout='90s';
do $$begin
 if public.get_bulk_imei_correction_version() is distinct from '20261106-bulk-imei-correction-1' then raise exception 'Install verified Bulk IMEI Correction first.';end if;
 if to_regprocedure('public.get_b_dept_destinations_version()') is not null then
  if public.get_b_dept_destinations_version() is distinct from '20261106-b-dept-routes-1' then raise exception 'Existing B-DEPT routing requires review.';end if;
 end if;
end;$$;
do $patch$declare impl regprocedure;ddl text;needle text;replacement text;ids regprocedure[]:='{}';t record;begin
 select to_regprocedure(implementation) into impl from greenloop_private.office_routines where to_regprocedure(identity)='public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure;
 if impl is null then raise exception 'Issuance office boundary is missing.';end if;
 ddl:=pg_get_functiondef(impl);
 needle:=$text$  if jsonb_array_length(r.parts)>0 or jsonb_array_length(r.services)>0 or upper(coalesce(r.gl_grade,''))='D'then raise exception 'B-DEPT direct routing keeps the existing no-parts/no-services rule. Send this repair phone to Lab & Glass.'using errcode='22023';end if;$text$;
 if strpos(ddl,'-- bdr unrestricted saved requirements')=0 then
  if strpos(ddl,needle)=0 then raise exception 'Issuance routing guard differs. Nothing changed.';end if;
  execute replace(ddl,needle,'  -- bdr unrestricted saved requirements: preserve inspection; publish only when Lab starts.');
 end if;
 ids:=array_append(ids,impl);
 select to_regprocedure(implementation) into impl from greenloop_private.office_routines where to_regprocedure(identity)='public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)'::regprocedure;
 if impl is null then raise exception 'B-DEPT office boundary is missing.';end if;
 ddl:=pg_get_functiondef(impl);
 if strpos(ddl,'-- bdr routing-only destinations')=0 then
  if strpos(ddl,$text$dest not in('ready_stock','lab_glass')$text$)=0 or strpos(ddl,'perform greenloop_private.bdt_services')=0 then raise exception 'B-DEPT routing implementation differs.';end if;
  ddl:=replace(ddl,$text$dest not in('ready_stock','lab_glass')$text$,$text$dest not in('ready_stock','lab_glass','final_qc')$text$);
  needle:=$text$ -- Existing Ready Stock validation, audit and old clients are preserved.$text$;
  replacement:=$body$
 -- bdr routing-only destinations. Requirements are managed in Issuance / Lab.
 if p_parts is distinct from '[]'::jsonb or p_services is distinct from '[]'::jsonb then raise exception 'Manage parts and services in Issuance or Lab & Glass, not B-DEPT.'using errcode='22023';end if;
 if p_battery_health_unavailable is null or p_final_battery_health is not null and p_final_battery_health not between 0 and 100 then raise exception 'Final Battery Health must be from 0 to 100.'using errcode='22023';end if;
 if outcome='pass'and dest='final_qc'then
  if p_technician_roster_id is not null then raise exception 'Direct Final QC does not assign a Lab technician.'using errcode='22023';end if;
  perform pg_advisory_xact_lock(20420261026);
  perform greenloop_private.begin_capability('record_frame_department_result_v3',jsonb_build_object('p_work_order_step_id',p_work_order_step_id,'p_result','pass','p_final_grade',null,'p_notes',p_notes));begin
   perform public.greenloop_require_entry(array['frame_department']::text[]);
   select s.work_order_id,w.job_id,w.device_id,j.current_location_id,d.device_platform into v from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=w.device_id and d.deleted_at is null where s.id=p_work_order_step_id and s.department='frame'and s.step_status='in_progress'for update of s,j,d;
   if v.job_id is null then raise exception 'This phone is no longer waiting in B-DEPT.'using errcode='22023';end if;
   perform greenloop_private.validate_mobile_battery(v.device_platform,p_final_battery_health::smallint,p_battery_health_unavailable,true);
   select *into f from public.final_qc_inspections where job_id=v.job_id and device_id=v.device_id and routed_to_frame order by inspected_at desc limit 1 for update;
   if f.id is null then raise exception 'Routed QC history is missing. Review this phone in Reports.'using errcode='22023';end if;
   select id into final_step from public.job_work_order_steps where work_order_id=v.work_order_id and department='final_qc'and step_status='pending'for update;
   if final_step is null then raise exception 'The pending Final QC step is missing. Nothing transferred.'using errcode='22023';end if;
   select id into lab_location from public.locations where location_code='FINAL-QC'and is_active limit 1;
   if lab_location is null then raise exception 'Final QC location is not configured.'using errcode='22023';end if;
   insert into public.frame_department_results(work_order_step_id,job_id,device_id,result,notes,reviewed_by,final_battery_health,final_battery_health_unavailable,previous_final_battery_health,previous_battery_health_unavailable)
    values(p_work_order_step_id,v.job_id,v.device_id,'pass',concat_ws(' | ','B-DEPT passed to Final QC',nullif(btrim(p_notes),'')),auth.uid(),p_final_battery_health,p_battery_health_unavailable,f.final_battery_health,f.final_battery_health_unavailable)returning id into rid;
   update public.final_qc_inspections set final_battery_health=p_final_battery_health,final_battery_health_unavailable=p_battery_health_unavailable where id=f.id;
   update public.job_work_order_steps set step_status='completed',returned_at=now()where id=p_work_order_step_id;
   update public.job_work_order_steps set step_status='in_progress',assigned_at=coalesce(assigned_at,now())where id=final_step;
   update public.job_work_orders set status='open'where id=v.work_order_id;
   update public.technician_job_timers set stopped_at=now(),elapsed_seconds=greatest(0,extract(epoch from now()-started_at)::integer),stopped_by=auth.uid()where job_id=v.job_id and stopped_at is null;
   update public.jobs set current_status='final_qc_pending',current_location_id=lab_location where id=v.job_id;
   update public.devices set current_status='final_qc_pending',current_location_id=lab_location where id=v.device_id;
   insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)values(v.device_id,v.job_id,v.current_location_id,lab_location,'B-DEPT passed to Final QC',auth.uid());
   insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(v.device_id,v.job_id,'b_dept_passed_final_qc','B-DEPT passed and sent to Final QC',jsonb_build_object('frame_step_id',p_work_order_step_id,'final_qc_step_id',final_step,'result_id',rid,'destination','final_qc','final_battery_health',p_final_battery_health),auth.uid());
   output:=jsonb_build_object('completed',true,'next_status','final_qc_pending','destination','final_qc','result','pass','result_id',rid);
  exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();return output;
 end if;
 -- Existing Ready Stock validation, audit and old clients are preserved.
$body$;
  if strpos(ddl,needle)=0 then raise exception 'B-DEPT insertion boundary differs.';end if;ddl:=replace(ddl,needle,replacement);
  needle:=$text$  perform greenloop_private.bdt_services(l.id,coalesce((greenloop_private.ps_service_state(l.id)->>'services_revision')::integer,0),services);$text$;
  replacement:=E'\n  update public.job_work_orders set work_required=true where id=v.work_order_id;\n  perform greenloop_private.qdp_publish(v.job_id,(select initial_qc_inspection_id from public.job_work_orders where id=v.work_order_id));\n  perform greenloop_private.wp_seed_services(v.job_id);';
  if strpos(ddl,needle)=0 then raise exception 'B-DEPT Lab work boundary differs.';end if;execute replace(ddl,needle,replacement);
 end if;
 ids:=array_append(ids,impl);
 -- Refresh only definitions changed above, after a fully verified prerequisite.
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))where to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using ids;end loop;
end;$patch$;
create table if not exists greenloop_private.b_dept_routes_installation(identity text primary key,hash text not null);
alter table greenloop_private.b_dept_routes_installation enable row level security;
revoke all on greenloop_private.b_dept_routes_installation from public,anon,authenticated;
create or replace function public.get_b_dept_destinations_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.b_dept_routes_installation)
 and not has_table_privilege('authenticated','greenloop_private.b_dept_routes_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.b_dept_routes_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 then '20261106-b-dept-routes-1'end;
$$;
revoke all on function public.get_b_dept_destinations_version()from public;
grant execute on function public.get_b_dept_destinations_version()to anon,authenticated;
insert into greenloop_private.b_dept_routes_installation select implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines where to_regprocedure(identity)in('public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure,'public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.b_dept_routes_installation values('public.get_b_dept_destinations_version()',md5(pg_get_functiondef('public.get_b_dept_destinations_version()'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_bulk_imei_correction_version()is distinct from '20261106-bulk-imei-correction-1'or public.get_b_dept_destinations_version()is distinct from '20261106-b-dept-routes-1'then raise exception 'B-DEPT routing verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_b_dept_destinations_version()as installed_b_dept_destinations_version;
