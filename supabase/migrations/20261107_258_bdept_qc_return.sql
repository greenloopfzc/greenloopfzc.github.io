-- Reopen the existing job, inspection and work order when B-DEPT passes a phone back.
begin;
set local statement_timeout = '90s';
do $$begin
  if public.get_b_dept_destinations_version() is distinct from '20261106-b-dept-routes-1' then
    raise exception 'Install the previous B-DEPT destinations update first.';
  end if;
  if to_regprocedure('public.get_b_dept_qc_return_version()') is not null then
    if public.get_b_dept_qc_return_version() is distinct from '20261107-bdept-qc-return-1' then
      raise exception 'Existing B-DEPT QC return installation requires review.';
    end if;
  end if;
end$$;

create table if not exists greenloop_private.bdept_qc_returns (
  result_id uuid primary key, job_id uuid not null, work_order_id uuid not null,
  inspection_id uuid not null, destination text not null check(destination in ('initial_qc','issuance')),
  previous_receipt jsonb, finished_at timestamptz
);
create unique index if not exists bdept_qc_open_return on greenloop_private.bdept_qc_returns(job_id) where finished_at is null;
alter table greenloop_private.bdept_qc_returns enable row level security;
revoke all on greenloop_private.bdept_qc_returns from public, anon, authenticated;

create or replace function greenloop_private.bdept_return_order(p_job uuid)
returns uuid language sql stable set search_path=pg_catalog,public as $$
  select work_order_id from greenloop_private.bdept_qc_returns where job_id=p_job and finished_at is null
$$;
revoke all on function greenloop_private.bdept_return_order(uuid) from public,anon,authenticated;

create or replace function greenloop_private.bdept_return_to_qc(
  p_step uuid, p_destination text, p_bh integer, p_unavailable boolean, p_notes text)
returns jsonb language plpgsql set search_path=pg_catalog,public as $$
declare
  phone record;
  inspection public.initial_qc_inspections%rowtype;
  previous_receipt jsonb;
  previous_qc public.final_qc_inspections%rowtype;
  result_id uuid;
  initial_location uuid;
  label text;
begin
  perform greenloop_private.require_office_network();
  perform greenloop_private.pf_cap('frame_department','entry');
  perform pg_advisory_xact_lock(20420261026);
  perform pg_advisory_xact_lock(19920261026);
  perform greenloop_private.begin_capability('record_frame_department_result_v3',
    jsonb_build_object('p_work_order_step_id',p_step,'p_result','pass','p_final_grade',null,'p_notes',p_notes));
  perform public.greenloop_require_entry(array['frame_department']);
  select w.id as work_order_id, w.initial_qc_inspection_id, j.id as job_id, d.id as device_id,
         j.current_location_id, d.device_platform into strict phone
  from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id
  join public.jobs j on j.id=w.job_id and j.deleted_at is null
  join public.devices d on d.id=w.device_id and d.id=j.device_id and d.deleted_at is null
  where s.id=p_step and s.department='frame' and s.step_status='in_progress'
    and j.current_status in ('frame_pending','frame_in_progress') and d.current_status=j.current_status
  for update of s,w,j,d;
  perform greenloop_private.validate_mobile_battery(phone.device_platform,p_bh::smallint,p_unavailable,true);
  select * into strict inspection from public.initial_qc_inspections where id=phone.initial_qc_inspection_id
    and job_id=phone.job_id and device_id=phone.device_id for update;
  select * into strict previous_qc from public.final_qc_inspections where job_id=phone.job_id and routed_to_frame
    order by attempt_number desc limit 1 for update;
  select id into strict initial_location from public.locations where location_code='INITIAL-QC' and is_active;
  select to_jsonb(s) into previous_receipt from greenloop_private.qc_saved_issuance s where job_id=phone.job_id for update;
  label:=case when p_destination='issuance' then 'Lab & Glass Issuance' else 'Initial QC' end;
  insert into public.frame_department_results(work_order_step_id,job_id,device_id,result,notes,reviewed_by,
    final_battery_health,final_battery_health_unavailable,previous_final_battery_health,previous_battery_health_unavailable)
  values(p_step,phone.job_id,phone.device_id,'pass',concat_ws(' | ','B-DEPT passed to '||label,p_notes),auth.uid(),
    p_bh,p_unavailable,previous_qc.final_battery_health,previous_qc.final_battery_health_unavailable) returning id into result_id;
  insert into greenloop_private.bdept_qc_returns(result_id,job_id,work_order_id,inspection_id,destination,previous_receipt)
    values(result_id,phone.job_id,phone.work_order_id,inspection.id,p_destination,previous_receipt);
  update public.final_qc_inspections set final_battery_health=p_bh,final_battery_health_unavailable=p_unavailable where id=previous_qc.id;
  update public.job_work_order_steps set step_status='completed',returned_at=now() where id=p_step;
  update public.technician_job_timers set stopped_at=now(),stopped_by=auth.uid(),
    elapsed_seconds=greatest(0,extract(epoch from now()-started_at)::integer) where job_id=phone.job_id and stopped_at is null;
  update public.jobs set current_status='initial_qc_pending',current_location_id=initial_location where id=phone.job_id;
  update public.devices set current_status='initial_qc_pending',current_location_id=initial_location where id=phone.device_id;
  delete from greenloop_private.qc_saved_issuance where job_id=phone.job_id;
  if p_destination='issuance' then
    insert into greenloop_private.qc_saved_issuance(job_id,device_id,inspection_id,request_id,payload_hash,saved_by,saved_by_name)
    values(phone.job_id,phone.device_id,inspection.id,result_id,md5(result_id::text),auth.uid(),
      coalesce((select upper(full_name) from public.user_profiles where id=auth.uid()),'STAFF'));
  else
    insert into greenloop_private.workflow_reopened_qc(request_id,job_id,device_id,inspection_id,original_data)
    values(result_id,phone.job_id,phone.device_id,inspection.id,jsonb_build_object('inspection',to_jsonb(inspection),'receipt',previous_receipt,
      'requirements',(select jsonb_agg(to_jsonb(r)) from public.initial_qc_part_requirements r where r.inspection_id=inspection.id),
      'findings',(select jsonb_agg(to_jsonb(f)) from public.initial_qc_findings f where f.inspection_id=inspection.id)));
  end if;
  insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)
    values(phone.device_id,phone.job_id,phone.current_location_id,initial_location,'B-DEPT passed to '||label,auth.uid());
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
    values(phone.device_id,phone.job_id,'b_dept_passed_'||p_destination,'B-DEPT passed to '||label,
      jsonb_build_object('destination',p_destination,'result_id',result_id,'frame_step_id',p_step,'inspection_id',inspection.id),auth.uid());
  perform greenloop_private.end_capability();
  return jsonb_build_object('completed',true,'result','pass','next_status','initial_qc_pending','destination',p_destination,'result_id',result_id);
end$$;
revoke all on function greenloop_private.bdept_return_to_qc(uuid,text,integer,boolean,text) from public,anon,authenticated;
-- Apply each revision to exactly one reviewed clause of the installed function.
create or replace function pg_temp.bdept_replace(body text, original text, replacement text)
returns text language plpgsql as $$
begin
  if cardinality(string_to_array(body,original))<>2 then
    raise exception 'B-DEPT return installation: expected clause missing or ambiguous: %',left(original,100);
  end if;
  return replace(body,original,replacement);
end$$;
create table if not exists greenloop_private.bdept_qc_return_installation(identity text primary key,hash text not null);
alter table greenloop_private.bdept_qc_return_installation enable row level security;
revoke all on greenloop_private.bdept_qc_return_installation from public,anon,authenticated;
do $patch$
declare target regprocedure; body text; changed regprocedure[]:='{}'; t record;
begin
  if to_regprocedure('public.get_b_dept_qc_return_version()') is not null then return; end if;
  select to_regprocedure(implementation) into strict target from greenloop_private.office_routines where to_regprocedure(identity)='public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,$old$dest not in('ready_stock','lab_glass','final_qc')$old$,$new$dest not in('ready_stock','lab_glass','final_qc','initial_qc','issuance')$new$);
  body:=pg_temp.bdept_replace(body,$old$ if outcome='pass'and dest='final_qc'then$old$,$new$ if outcome='pass' and dest in ('initial_qc','issuance') then
   if p_technician_roster_id is not null then raise exception 'Choose a technician in Issuance.'; end if;
   return greenloop_private.bdept_return_to_qc(p_work_order_step_id,dest,p_final_battery_health,p_battery_health_unavailable,p_notes);
 end if;
 if outcome='pass'and dest='final_qc'then$new$);
  execute body;
  changed:=array_append(changed,target);

  target:='greenloop_private.wfs_qc_resave(uuid,jsonb,jsonb,text,text,text,uuid,boolean)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,'order by reopened_at desc for update limit 1','order by (resaved_at is null) desc,reopened_at desc,request_id for update limit 1');
  body:=pg_temp.bdept_replace(body,$old$if exists(select 1 from public.job_work_orders where job_id=p_job_id)or$old$,$new$if (greenloop_private.bdept_return_order(p_job_id) is null and exists(select 1 from public.job_work_orders where job_id=p_job_id))or$new$);
  body:=pg_temp.bdept_replace(body,$old$ delete from public.initial_qc_part_requirements$old$,$new$ if greenloop_private.bdept_return_order(p_job_id) is null then
 delete from public.initial_qc_part_requirements$new$);
  body:=pg_temp.bdept_replace(body,$old$ if p_direct_ready then r:=$old$,$new$ end if;
 if p_direct_ready then r:=$new$);
  execute body;
  changed:=array_append(changed,target);

  select to_regprocedure(implementation) into strict target from greenloop_private.office_routines where to_regprocedure(identity)='public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,$old$  if exists(select 1 from public.initial_qc_inspections$old$,$new$  if greenloop_private.bdept_return_order(p_job_id) is not null then
    select w.initial_qc_inspection_id into strict inspection from public.job_work_orders w where w.id=greenloop_private.bdept_return_order(p_job_id) and w.job_id=p_job_id;
    insert into greenloop_private.qc_saved_issuance(job_id,device_id,inspection_id,request_id,payload_hash,saved_by,saved_by_name)
    values(p_job_id,dev,inspection,request,fingerprint,actor,coalesce((select upper(full_name) from public.user_profiles where id=actor),'STAFF'));
    update public.jobs set supplier_grade=sg where id=p_job_id;
    update public.devices set gc_grade=gl where id=dev;
    -- Initial QC selects part names; retain recorded quantities for a selected existing part.
    select coalesce(jsonb_agg(x || jsonb_build_object('quantity',coalesce(
        (select p.quantity_required from public.initial_qc_part_requirements p
         where p.inspection_id=inspection and p.status not in('not_required','cancelled')
           and greenloop_private.pp_key(p.part_name)=greenloop_private.pp_key(x->>'part_name')
         order by p.identified_at,p.id limit 1),(x->>'quantity')::int))), '[]')
      into parts from jsonb_array_elements(parts)x;
    perform greenloop_private.qcie_save(p_job_id,greenloop_private.qcis_revision(p_job_id),parts,coalesce(
      (select jsonb_agg(x->>'check_item') from jsonb_array_elements(p_findings)x where public.is_initial_qc_service(x->>'check_item')),'[]'),request);
    update public.initial_qc_inspections set notes=nullif(btrim(p_notes),'') where id=inspection;
    insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id) values
      (dev,p_job_id,'initial_qc_resaved','Initial QC reinspection saved',jsonb_build_object('inspection_id',inspection,'gl_grade',gl,'supplier_grade',sg),actor);
    perform greenloop_private.end_capability();
    return jsonb_build_object('saved',true,'job_id',p_job_id,'inspection_id',inspection,'state','awaiting_issuance');
  end if;
  if exists(select 1 from public.initial_qc_inspections$new$);
  execute body;
  changed:=array_append(changed,target);

  target:='greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,$old$if r.job_id is null or exists(select 1 from public.job_work_orders where job_id=p_job_id)
  or exists(select 1 from public.job_part_requests where job_id=p_job_id)then$old$,$new$if r.job_id is null or (greenloop_private.bdept_return_order(p_job_id) is null and (exists(select 1 from public.job_work_orders where job_id=p_job_id)
  or exists(select 1 from public.job_part_requests where job_id=p_job_id)))then$new$);
  body:=pg_temp.bdept_replace(body,$old$  update public.initial_qc_part_requirements p set status='not_required'$old$,$new$  if greenloop_private.bdept_return_order(p_job_id) is not null then
    if exists(select 1 from public.initial_qc_part_requirements p where p.inspection_id=s.inspection_id
      and p.status not in ('identified','not_required','cancelled') and not exists(select 1 from jsonb_array_elements(parts)x
        where greenloop_private.pp_key(x->>'part_name')=greenloop_private.pp_key(p.part_name) and (x->>'quantity')::int=p.quantity_required))
    then raise exception 'An already ordered part must be changed through Parts.'; end if;
    perform greenloop_private.pf_context(true);
  end if;
  update public.initial_qc_part_requirements p set status='not_required'$new$);
  body:=pg_temp.bdept_replace(body,$old$where id=rid and(quantity_required$old$,$new$where id=rid and (greenloop_private.bdept_return_order(p_job_id) is null or status in ('identified','not_required','cancelled')) and(quantity_required$new$);
  body:=pg_temp.bdept_replace(body,$old$exception when others then$old$,$new$if greenloop_private.bdept_return_order(p_job_id) is not null then perform greenloop_private.pf_context(false);end if;
 exception when others then$new$);
  execute body;
  changed:=array_append(changed,target);

  target:='greenloop_private.qdr_save(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,$old$or exists(select 1 from public.job_work_orders where job_id=p_job_id)$old$,$new$or (greenloop_private.bdept_return_order(p_job_id) is null and exists(select 1 from public.job_work_orders where job_id=p_job_id))$new$);
  body:=pg_temp.bdept_replace(body,$old$  result:=jsonb_build_object($old$,$new$  update greenloop_private.bdept_qc_returns set finished_at=now() where job_id=p_job_id and finished_at is null;
  result:=jsonb_build_object($new$);
  execute body;
  changed:=array_append(changed,target);

  select to_regprocedure(implementation) into strict target from greenloop_private.office_routines where to_regprocedure(identity)='public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure;
  body:=replace(pg_get_functiondef(target),chr(13)||chr(10),chr(10));
  body:=pg_temp.bdept_replace(body,$old$if exists(select 1 from public.job_work_orders where job_id=p_job_id)then$old$,$new$if greenloop_private.bdept_return_order(p_job_id) is null and exists(select 1 from public.job_work_orders where job_id=p_job_id)then$new$);
  body:=pg_temp.bdept_replace(body,$old$  insert into public.job_work_orders(work_order_number$old$,$new$  wo:=greenloop_private.bdept_return_order(p_job_id);
  if wo is not null then
    update public.job_work_orders set status='open',work_required=dest='lab_glass' where id=wo and job_id=p_job_id and initial_qc_inspection_id=s.inspection_id returning work_order_number into strict number;
  else
  insert into public.job_work_orders(work_order_number$new$);
  body:=pg_temp.bdept_replace(body,$old$returning id,work_order_number into wo,number;$old$,$new$returning id,work_order_number into wo,number;
  end if;$new$);
  body:=pg_temp.bdept_replace(body,$old$insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_technician_roster_id,assigned_technician_name,assigned_at)values(wo,10,'laboratory','in_progress',t.id,t.full_name,now())returning id into step;$old$,$new$if greenloop_private.bdept_return_order(p_job_id) is not null then
     update public.job_work_order_steps set step_status='in_progress',assigned_technician_roster_id=t.id,
       assigned_technician_name=t.full_name,assigned_technician_id=null,assigned_at=now(),returned_at=null,rework_count=rework_count+1
       where work_order_id=wo and department='laboratory' returning id into step;
     if step is null then
       insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_technician_roster_id,assigned_technician_name,assigned_at)
       values(wo,(select max(step_order)+1 from public.job_work_order_steps where work_order_id=wo),'laboratory','in_progress',t.id,t.full_name,now())returning id into step;
     end if;
     update public.job_work_order_steps set step_status='pending',step_order=(select max(step_order)+1 from public.job_work_order_steps where work_order_id=wo)
       where work_order_id=wo and department='final_qc';
   else
   insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_technician_roster_id,assigned_technician_name,assigned_at)values(wo,10,'laboratory','in_progress',t.id,t.full_name,now())returning id into step;$new$);
  body:=pg_temp.bdept_replace(body,$old$values(wo,20,'final_qc','pending');$old$,$new$values(wo,20,'final_qc','pending');
   end if;$new$);
  body:=pg_temp.bdept_replace(body,$old$values(p_job_id,s.device_id,step,0,now(),now()$old$,$new$values(p_job_id,s.device_id,step,(select rework_count from public.job_work_order_steps where id=step),now(),now()$new$);
  body:=pg_temp.bdept_replace(body,$old$perform greenloop_private.wp_seed_services(p_job_id);$old$,$new$
   if greenloop_private.bdept_return_order(p_job_id) is not null then
     with seeded as (
       insert into greenloop_private.lab_only_services(job_id,cycle,step_id,revision,names,saved_by)
       values(p_job_id,greenloop_private.pf_cycle(p_job_id),step,1,r.services,actor)
       on conflict(job_id,cycle) do nothing returning job_id,cycle,names
     )
     insert into greenloop_private.lab_only_services_audit(job_id,cycle,action,actor,previous_names,names)
       select job_id,cycle,'initial_qc_services_saved',actor,'[]',names from seeded;
   end if;
   perform greenloop_private.wp_seed_services(p_job_id);$new$);
  body:=pg_temp.bdept_replace(body,$old$insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(wo,10,'final_qc','in_progress');$old$,$new$if greenloop_private.bdept_return_order(p_job_id) is not null then
     update public.job_work_order_steps set step_status='in_progress',assigned_at=now(),returned_at=null where work_order_id=wo and department='final_qc';
   else
     insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(wo,10,'final_qc','in_progress');
   end if;$new$);
  body:=pg_temp.bdept_replace(body,$old$  update greenloop_private.qc_saved_issuance set state='issued'$old$,$new$  update greenloop_private.bdept_qc_returns set finished_at=now() where job_id=p_job_id and finished_at is null;
  update greenloop_private.qc_saved_issuance set state='issued'$new$);
  execute body;
  changed:=array_append(changed,target);

  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))where to_regprocedure(implementation)=any(changed);
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(changed) or to_regprocedure(implementation)=any(changed);
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private' and c.table_name like '%installation' and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity') loop
    execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using changed;
  end loop;
  insert into greenloop_private.bdept_qc_return_installation select f::text,md5(pg_get_functiondef(f)) from unnest(changed || array[
    'greenloop_private.bdept_return_order(uuid)'::regprocedure,'greenloop_private.bdept_return_to_qc(uuid,text,integer,boolean,text)'::regprocedure]) f;
end;$patch$;
create or replace function public.get_b_dept_qc_return_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when (select count(*)=8 and bool_and(coalesce(md5(pg_get_functiondef(to_regprocedure(identity)))=hash,false)) from greenloop_private.bdept_qc_return_installation)
 and not exists(select 1 from greenloop_private.bdept_qc_return_installation where has_function_privilege('anon',to_regprocedure(identity),'execute') or has_function_privilege('authenticated',to_regprocedure(identity),'execute'))
 and not has_table_privilege('authenticated','greenloop_private.bdept_qc_returns','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then '20261107-bdept-qc-return-1' end
$$;
revoke all on function public.get_b_dept_qc_return_version() from public;
grant execute on function public.get_b_dept_qc_return_version() to anon,authenticated;
do $$begin
 if public.get_b_dept_qc_return_version() is distinct from '20261107-bdept-qc-return-1' or public.get_b_dept_destinations_version() is distinct from '20261106-b-dept-routes-1' then raise exception 'B-DEPT return verification failed.'; end if;
end$$;
notify pgrst,'reload schema';
commit;
select public.get_b_dept_qc_return_version() as installed_b_dept_qc_return_version;

