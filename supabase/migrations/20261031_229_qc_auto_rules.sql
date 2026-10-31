-- Grade D Housing and installed Diagnostic Battery defaults. No historical backfill.
begin;
do $$begin
 if public.get_admin_password_change_version()is distinct from '20261030-user-password-1'then raise exception 'Install the verified Admin Password update first.';end if;
 if to_regprocedure('public.get_qc_auto_rules_version()')is not null then if public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'then raise exception 'Existing QC automatic rules need review.';end if;end if;
end;$$;
create or replace function greenloop_private.qca_housing(p_grade text,p_parts jsonb)returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$
declare parts jsonb:=coalesce(p_parts,'[]');begin
 if jsonb_typeof(parts)is distinct from 'array'then raise exception 'Choose a valid parts list.'using errcode='22023';end if;
 if upper(btrim(p_grade))='D'and not exists(select 1 from jsonb_array_elements(parts)x where greenloop_private.pp_key(x->>'part_name')='housing')then
  parts:=parts||jsonb_build_array(jsonb_build_object('part_name','Housing','quantity',1,'notes','Automatically required for GL Grade D'));
 end if;return parts;
end;$$;
create or replace function greenloop_private.qca_battery_changed(p_step uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(
  select 1 from public.job_work_order_steps f
  join public.job_work_orders w on w.id=f.work_order_id
  join public.jobs j on j.id=w.job_id and j.deleted_at is null
  join public.devices d on d.id=j.device_id and d.deleted_at is null
  join public.job_work_order_steps lab on lab.work_order_id=w.id and lab.department in('laboratory','glass')
  join greenloop_private.parts_flow_orders o on o.step_id=lab.id and o.job_id=j.id and o.device_id=d.id and o.completed_at is not null
  join greenloop_private.parts_flow_requests m on m.order_id=o.id
  join public.job_part_requests r on r.id=m.request_id and r.job_id=j.id and r.device_id=d.id and r.status<>'cancelled'
  join public.part_issue_transactions i on i.part_request_id=r.id
  join public.part_installations used on used.part_issue_id=i.id and used.part_request_id=r.id and used.job_id=j.id and used.device_id=d.id and used.quantity_installed>0
  where f.id=p_step and f.department='final_qc'and greenloop_private.pp_key(r.part_name)='diagnostic battery'
   and i.quantity_issued-i.quantity_returned-coalesce((select sum(ret.quantity)from greenloop_private.parts_flow_returns ret where ret.issue_id=i.id and ret.status='pending'),0)>0
 );
$$;
create or replace function greenloop_private.qca_job_battery(p_job uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id where w.job_id=p_job and s.department='final_qc'and s.step_status='in_progress'and greenloop_private.qca_battery_changed(s.id));
$$;
create or replace function public.get_final_qc_battery_defaults_v1(p_step_ids uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set statement_timeout='15s' as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_capability_v1('final_qc','view'),false)then raise exception 'Final QC view access is required.'using errcode='42501';end if;
 if p_step_ids is null or cardinality(p_step_ids)>500 or array_position(p_step_ids,null)is not null then raise exception 'Choose at most 500 Final QC phones.'using errcode='22023';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('step_id',x.id,'diagnostic_battery_installed',x.changed,'final_battery_health',case when x.changed then 100 else x.battery_health end,'battery_health_unavailable',case when x.changed then false else x.device_platform='android'and x.battery_health_unavailable end)order by x.id)
 from(select s.id,d.battery_health,d.device_platform,d.battery_health_unavailable,greenloop_private.qca_battery_changed(s.id)changed
  from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.id=any(p_step_ids)and s.department='final_qc'and s.step_status='in_progress'and j.current_status='final_qc_pending')x),'[]');
end;$$;
revoke all on function greenloop_private.qca_housing(text,jsonb),greenloop_private.qca_battery_changed(uuid),greenloop_private.qca_job_battery(uuid)from public,anon,authenticated;
revoke all on function public.get_final_qc_battery_defaults_v1(uuid[])from public,anon,authenticated;
grant execute on function public.get_final_qc_battery_defaults_v1(uuid[])to authenticated;
do $wrap$declare f record;impl text;sig text;body text;begin
 select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature into f from pg_proc p where p.oid='public.get_final_qc_battery_defaults_v1(uuid[])'::regprocedure;
 if strpos(f.ddl,'greenloop-office-wrapper-196')=0 then
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'(uuid[])';execute replace(f.ddl,'FUNCTION public.get_final_qc_battery_defaults_v1(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||E'($1);\nend;';
  execute format('create or replace function public.get_final_qc_battery_defaults_v1(p_step_ids uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set statement_timeout=''15s'' as %L',body);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end if;
end;$wrap$;


-- Only reviewed implementations change. Existing public role, page/action,
-- Office Only and stock/workflow guards remain in place.
do $patch$declare impl text;ddl text;needle text;replacement text;f regprocedure;changed regprocedure[]:='{}';t record;begin
 select implementation into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_initial_qc_lab_first(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed Lab-first Initial QC routine is missing.';end if;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-auto-rules-229')=0 then
  needle:='  perform greenloop_private.qdp_validate(p_part_requests);';if strpos(ddl,needle)=0 then raise exception 'Initial QC Parts validation boundary differs.';end if;
  ddl:=replace(ddl,needle,E'  -- greenloop-qc-auto-rules-229\n  p_part_requests:=greenloop_private.qca_housing(p_gc_grade,p_part_requests);\n'||needle);
  needle:='  v_routing_findings jsonb := coalesce(p_findings, ''[]''::jsonb);';if strpos(ddl,needle)=0 then raise exception 'Initial QC routing declaration differs.';end if;ddl:=replace(ddl,needle,needle||E'\n  v_qca_context text;');
  needle:='  select *'||chr(10)||'    into v_result'||chr(10)||'  from public.complete_scanned_initial_qc_with_roster_and_grades(';if strpos(ddl,needle)=0 then raise exception 'Initial QC delegate boundary differs.';end if;
  ddl:=replace(ddl,needle,E'  v_qca_context:=current_setting(''greenloop.qca_lab_entry'',true);\n  perform set_config(''greenloop.qca_lab_entry'',p_job_id::text,true);\n'||needle);
  needle:='  for v_part in';if strpos(ddl,needle)=0 then raise exception 'Initial QC requirements boundary differs.';end if;ddl:=replace(ddl,needle,E'  perform set_config(''greenloop.qca_lab_entry'',coalesce(v_qca_context,''''),true);\n\n'||needle);execute ddl;
 end if;changed:=array_append(changed,to_regprocedure(impl));
 select implementation into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_scanned_initial_qc_with_roster_and_grades(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed graded Initial QC routine is missing.';end if;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-auto-rules-229')=0 then
  needle:='  select job.device_id';if strpos(ddl,needle)=0 then raise exception 'Graded Initial QC completion boundary differs.';end if;
  replacement:=E'  -- greenloop-qc-auto-rules-229\n  if v_gc_grade=''D''and current_setting(''greenloop.qca_lab_entry'',true)is distinct from p_job_id::text then\n    return query select *from public.complete_initial_qc_lab_first(p_job_id,p_overall_condition,p_cosmetic_condition,p_notes,p_findings,p_part_requests,p_assigned_technician_roster_id,p_supplier_grade,p_gc_grade);\n    return;\n  end if;\n\n';execute replace(ddl,needle,replacement||needle);
 end if;changed:=array_append(changed,to_regprocedure(impl));
 select implementation into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_initial_qc_direct_to_frame_v2(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed direct Frame routine is missing.';end if;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-auto-rules-229')=0 then
  needle:='  if jsonb_typeof(coalesce(p_findings';if strpos(ddl,needle)=0 then raise exception 'Direct Frame validation boundary differs.';end if;
  execute replace(ddl,needle,E'  -- greenloop-qc-auto-rules-229\n  if upper(btrim(p_gc_grade))=''D''then raise exception ''Grade D requires Housing. Send this phone to Lab & Parts.''using errcode=''22023'';end if;\n'||needle);
 end if;changed:=array_append(changed,to_regprocedure(impl));
 for impl in select implementation from greenloop_private.capability_routines where to_regprocedure(identity)in('public.complete_final_qc_with_final_grade_v2(uuid,final_qc_result,text,smallint,text,work_department,text,jsonb,boolean)'::regprocedure,'public.route_final_qc_pass_to_frame_v3(uuid,text,smallint,text,boolean)'::regprocedure)loop
  ddl:=pg_get_functiondef(to_regprocedure(impl));
  if strpos(ddl,'greenloop-qc-auto-rules-229')=0 then
   needle:='  perform greenloop_private.validate_mobile_battery(v_platform,p_final_battery_health,p_battery_health_unavailable,';if strpos(ddl,needle)=0 then raise exception 'Final battery validation boundary differs.';end if;
   execute replace(ddl,needle,E'  -- greenloop-qc-auto-rules-229\n  if greenloop_private.qca_job_battery(p_job_id)then p_final_battery_health:=100;p_battery_health_unavailable:=false;end if;\n'||needle);
  end if;changed:=array_append(changed,to_regprocedure(impl));
 end loop;
 if cardinality(changed)<>5 then raise exception 'All five reviewed QC implementations are required.';end if;
 foreach f in array changed loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  -- Re-seal only rows for the five reviewed functions, across existing manifests.
  for t in select c.table_name from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name='hash' where c.table_schema='greenloop_private'and c.column_name='identity'and c.table_name like '%\_installation'escape '\'loop
   execute format('update greenloop_private.%I set hash=md5(pg_get_functiondef($1))where to_regprocedure(identity)=$1',t.table_name)using f;
  end loop;
 end loop;
end;$patch$;
create table if not exists greenloop_private.qc_auto_rules_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_auto_rules_installation enable row level security;
revoke all on greenloop_private.qc_auto_rules_installation from public,anon,authenticated;
create or replace function public.get_qc_auto_rules_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_admin_password_change_version()='20261030-user-password-1'
 and(select count(*)=11 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_auto_rules_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.qc_auto_rules_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.qc_auto_rules_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.qc_auto_rules_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.qc_auto_rules_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_function_privilege('anon','public.get_final_qc_battery_defaults_v1(uuid[])','EXECUTE')and has_function_privilege('authenticated','public.get_final_qc_battery_defaults_v1(uuid[])','EXECUTE')
 then '20261031-qc-auto-rules-1'end;
$$;
revoke all on function public.get_qc_auto_rules_version()from public;grant execute on function public.get_qc_auto_rules_version()to anon,authenticated;
insert into greenloop_private.qc_auto_rules_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname in('qca_housing','qca_battery_changed','qca_job_battery')or p.pronamespace='public'::regnamespace and p.proname in('get_final_qc_battery_defaults_v1','get_qc_auto_rules_version')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_final_qc_battery_defaults_v1(uuid[])'::regprocedure)or p.oid in(select to_regprocedure(implementation)from greenloop_private.capability_routines where to_regprocedure(identity)in('public.complete_initial_qc_lab_first(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure,'public.complete_scanned_initial_qc_with_roster_and_grades(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure,'public.complete_initial_qc_direct_to_frame_v2(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure,'public.complete_final_qc_with_final_grade_v2(uuid,final_qc_result,text,smallint,text,work_department,text,jsonb,boolean)'::regprocedure,'public.route_final_qc_pass_to_frame_v3(uuid,text,smallint,text,boolean)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'then raise exception 'QC automatic rules verification failed. No change was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_auto_rules_version()as installed_qc_auto_rules_version;
