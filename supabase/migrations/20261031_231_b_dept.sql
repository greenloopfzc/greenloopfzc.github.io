-- B-DEPT Final Battery Health. Existing permissions and Initial BH are preserved.
begin;
do $$begin
 if public.get_lab_return_clock_version()is distinct from '20261031-lab-return-clock-1'then raise exception 'Install the verified Lab return clock first.';end if;
 if to_regprocedure('public.get_b_dept_version()')is not null then if public.get_b_dept_version()is distinct from '20261031-b-dept-1'then raise exception 'Existing B-DEPT installation needs review.';end if;end if;
end;$$;
alter table public.frame_department_results add column if not exists final_battery_health smallint check(final_battery_health between 0 and 100),add column if not exists final_battery_health_unavailable boolean,add column if not exists previous_final_battery_health smallint,add column if not exists previous_battery_health_unavailable boolean;
create or replace function public.get_b_dept_rows_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare names boolean;begin
 perform greenloop_private.pf_cap('frame_department','view');
 names:=coalesce(public.get_my_partner_name_access(),false);
 return coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('supplier_name',case when names then r.supplier_name end,'device_platform',d.device_platform,'initial_battery_health_unavailable',d.battery_health_unavailable,'final_battery_health',case when b.id is not null then b.final_battery_health when f.id is not null then f.final_battery_health else d.battery_health end,'final_battery_health_unavailable',case when b.id is not null then b.final_battery_health_unavailable when f.id is not null then f.final_battery_health_unavailable else d.battery_health_unavailable end,'battery_source',case when b.id is not null then 'B-DEPT'when f.id is not null then 'Final QC'else 'Initial BH'end))
 from public.get_frame_department_rows()r join public.jobs j on j.id=r.job_id join public.devices d on d.id=j.device_id
 left join lateral(select x.id,x.final_battery_health,x.final_battery_health_unavailable from public.frame_department_results x where x.work_order_step_id=r.step_id and x.final_battery_health_unavailable is not null order by x.reviewed_at desc,x.id desc limit 1)b on true
 left join lateral(select x.id,x.final_battery_health,x.final_battery_health_unavailable from public.final_qc_inspections x where x.job_id=r.job_id and x.routed_to_frame order by x.inspected_at desc limit 1)f on true),'[]');
end;$$;
create or replace function public.record_b_dept_result_v1(p_work_order_step_id uuid,p_result text,p_final_grade text,p_final_battery_health integer,p_battery_health_unavailable boolean default false,p_notes text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid();result text:=lower(btrim(coalesce(p_result,'')));j uuid;d uuid;platform text;f public.final_qc_inspections%rowtype;rid uuid;output jsonb;begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('frame_department','entry');
 if p_battery_health_unavailable is null or p_final_battery_health is not null and p_final_battery_health not between 0 and 100 then raise exception 'Final Battery Health must be a whole number from 0 to 100.'using errcode='22023';end if;
 if result not in('pass','fail')then raise exception 'Select Pass or Fail.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('record_frame_department_result_v3',jsonb_build_object('p_work_order_step_id',p_work_order_step_id,'p_result',result,'p_final_grade',p_final_grade,'p_notes',p_notes));begin
  perform public.greenloop_require_entry(array['frame_department']::text[]);
  select job.id,device.id,device.device_platform into j,d,platform from public.job_work_order_steps step join public.job_work_orders w on w.id=step.work_order_id join public.jobs job on job.id=w.job_id and job.deleted_at is null join public.devices device on device.id=job.device_id and device.deleted_at is null where step.id=p_work_order_step_id and step.department='frame'and step.step_status='in_progress'for update of step,job,device;
  if j is null then raise exception 'This phone is no longer waiting in B-DEPT.'using errcode='22023';end if;
  perform greenloop_private.validate_mobile_battery(platform,p_final_battery_health::smallint,p_battery_health_unavailable,result='pass');
  select x.*into f from public.final_qc_inspections x where x.job_id=j and x.device_id=d and x.routed_to_frame order by x.inspected_at desc limit 1 for update;
  if result='pass'and f.id is null then raise exception 'The routed inspection record is missing. Review this phone in Reports before passing it.'using errcode='22023';end if;
  insert into public.frame_department_results(work_order_step_id,job_id,device_id,result,notes,reviewed_by,final_battery_health,final_battery_health_unavailable,previous_final_battery_health,previous_battery_health_unavailable)
  values(p_work_order_step_id,j,d,result,nullif(btrim(p_notes),''),actor,p_final_battery_health,p_battery_health_unavailable,f.final_battery_health,f.final_battery_health_unavailable)returning id into rid;
  if result='pass'then
   update public.final_qc_inspections set final_battery_health=p_final_battery_health,final_battery_health_unavailable=p_battery_health_unavailable where id=f.id and job_id=j and device_id=d;
   output:=public.complete_frame_to_ready_stock_with_grade_v2(p_work_order_step_id,p_final_grade,concat_ws(' | ','B-DEPT Pass',nullif(btrim(p_notes),'')));
  else
   update public.job_work_order_steps set rework_count=rework_count+1 where id=p_work_order_step_id;
   output:=jsonb_build_object('completed',false,'next_status','frame_pending');
  end if;
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(d,j,'b_dept_battery_review','B-DEPT Final Battery Health recorded',jsonb_build_object('frame_step_id',p_work_order_step_id,'result_id',rid,'result',result,'previous_final_battery_health',f.final_battery_health,'previous_battery_health_unavailable',f.final_battery_health_unavailable,'final_battery_health',p_final_battery_health,'final_battery_health_unavailable',p_battery_health_unavailable),actor);
 exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();
 return coalesce(output,'{}')||jsonb_build_object('result',result,'result_id',rid,'final_battery_health',p_final_battery_health,'final_battery_health_unavailable',p_battery_health_unavailable);
end;$$;
-- Wrap the two new APIs in the existing office boundary, without changing page/action grants.
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_b_dept_rows_v1','record_b_dept_result_v1')loop
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
 select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
 execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
 insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.b_dept_installation(identity text primary key,hash text not null);
alter table greenloop_private.b_dept_installation enable row level security;revoke all on greenloop_private.b_dept_installation from public,anon,authenticated;
create or replace function public.get_b_dept_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_lab_return_clock_version()='20261031-lab-return-clock-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.b_dept_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.b_dept_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.b_dept_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.b_dept_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and(select count(*)=4 from information_schema.columns where table_schema='public'and table_name='frame_department_results'and column_name in('final_battery_health','final_battery_health_unavailable','previous_final_battery_health','previous_battery_health_unavailable'))
 and not exists(select 1 from greenloop_private.b_dept_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_function_privilege('anon','public.get_b_dept_rows_v1()','EXECUTE')and not has_function_privilege('anon','public.record_b_dept_result_v1(uuid,text,text,integer,boolean,text)','EXECUTE')
 and has_function_privilege('authenticated','public.get_b_dept_rows_v1()','EXECUTE')and has_function_privilege('authenticated','public.record_b_dept_result_v1(uuid,text,text,integer,boolean,text)','EXECUTE')
 then '20261031-b-dept-1'end;
$$;
revoke all on function public.get_b_dept_version()from public;grant execute on function public.get_b_dept_version()to anon,authenticated;
insert into greenloop_private.b_dept_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('public.get_b_dept_rows_v1()'::regprocedure,'public.record_b_dept_result_v1(uuid,text,text,integer,boolean,text)'::regprocedure,'public.get_b_dept_version()'::regprocedure)or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_b_dept_rows_v1()'::regprocedure,'public.record_b_dept_result_v1(uuid,text,text,integer,boolean,text)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_b_dept_version()is distinct from '20261031-b-dept-1'then raise exception 'B-DEPT installation verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_b_dept_version()as installed_b_dept_version;
