-- Audited workflow corrections and physical-parts recovery. No installation backfill.
do $install$
declare old text;updated text;sig text;t record;c record;b record;reviewed jsonb:='[]';sealed text[]:='{}';
begin
perform set_config('search_path','pg_catalog,public',true);
if to_regprocedure('public.get_stage_change_parts_version()')is not null then
 if public.get_stage_change_parts_version()is distinct from '20261119-stage-change-parts-1'then raise exception 'Stage correction integrity differs. Nothing installed.';end if;return;
end if;
if public.get_receipt_supplier_correction_version()is distinct from '20261119-receipt-supplier-correction-1'then raise exception 'Install the verified receipt supplier correction first.';end if;
create table greenloop_private.stage_change_audit(request_id uuid primary key,job_id uuid not null,device_id uuid not null,actor uuid not null,at timestamptz not null default clock_timestamp(),from_stage text not null,to_stage text not null,reason text not null,command jsonb not null,before_data jsonb not null,response jsonb not null);
create index stage_change_phone_history on greenloop_private.stage_change_audit(device_id,at desc);
create table greenloop_private.stage_qc_leases(job_id uuid primary key,work_order_id uuid not null,request_id uuid not null references greenloop_private.stage_change_audit,finished_at timestamptz);
create table greenloop_private.cancelled_phone_cases(id uuid primary key default gen_random_uuid(),source_key text unique not null,job_id uuid not null,device_id uuid not null,stage text not null,technician text,at timestamptz not null default clock_timestamp(),actor uuid,reason text not null,issue_ids uuid[]not null default '{}',before_data jsonb not null);
create index cancelled_phone_job on greenloop_private.cancelled_phone_cases(job_id,at desc);
create index cancelled_phone_issue_membership on greenloop_private.cancelled_phone_cases using gin(issue_ids);
-- Both the cancellation badge and the native return check sum actual
-- installations by issue. Avoid a whole installations-table scan per issue.
create index stage_parts_install_issue_idx on public.part_installations(part_issue_id)include(quantity_installed);
create table greenloop_private.cancelled_part_collections(request_id uuid primary key,case_id uuid not null references greenloop_private.cancelled_phone_cases,actor uuid not null,at timestamptz not null default clock_timestamp(),command jsonb not null,return_id uuid not null);
create or replace function greenloop_private.scp_immutable()returns trigger language plpgsql set search_path=pg_catalog,public as $f$begin raise exception 'Stage correction and collection history is permanent.'using errcode='55000';end;$f$;
create trigger stage_change_immutable before update or delete or truncate on greenloop_private.stage_change_audit for each statement execute function greenloop_private.scp_immutable();
create trigger cancelled_phone_immutable before update or delete or truncate on greenloop_private.cancelled_phone_cases for each statement execute function greenloop_private.scp_immutable();
create trigger cancelled_collection_immutable before update or delete or truncate on greenloop_private.cancelled_part_collections for each statement execute function greenloop_private.scp_immutable();
create or replace function greenloop_private.scp_stage(p_job uuid)returns text language sql stable security definer set search_path=pg_catalog,public as $f$
select case when j.current_status in('received','initial_qc_pending','initial_qc_completed','no_work_required')then case when exists(select 1 from greenloop_private.qc_saved_issuance s where s.job_id=j.id and s.state='awaiting_issuance')then 'issuance'else 'initial_qc'end
when j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','parts_pending','work_required','rework')then 'lab_glass'
when j.current_status in('final_qc_pending','qc_failed')then 'final_qc'when j.current_status in('frame_pending','frame_in_progress')then 'b_dept'
when j.current_status in('production_pending','production_completed','ready_for_packing','ready_for_shipment','qc_passed')then 'ready_stock'else 'unavailable'end from public.jobs j where id=p_job and deleted_at is null;$f$;
create or replace function greenloop_private.scp_label(p_stage text)returns text language sql immutable set search_path=pg_catalog,public as $f$select case p_stage when 'initial_qc'then 'Initial QC'when 'issuance'then 'Lab & Glass Issuance'when 'lab_glass'then 'Lab & Glass'when 'final_qc'then 'Final QC'when 'b_dept'then 'B-DEPT'when 'ready_stock'then 'Ready Stock'else 'Unavailable'end;$f$;
create or replace function greenloop_private.scp_require(p_write boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $f$begin
 perform greenloop_private.wf_guard();if p_write then perform greenloop_private.pf_cap('reports','workflow_stage_change');if not exists(select 1 from public.user_page_permissions where user_id=auth.uid()and page_key='reports'and access_level='edit')then raise exception 'Reports edit access is required.'using errcode='42501';end if;end if;
end;$f$;
create or replace function greenloop_private.scp_scope(p_device uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare j public.jobs%rowtype;d public.devices%rowtype;w public.job_work_orders%rowtype;v jsonb;begin
 select *into strict d from public.devices where id=p_device and deleted_at is null;
 select *into strict j from public.jobs where device_id=p_device and deleted_at is null order by received_at desc nulls last,created_at desc,id desc limit 1;
 if not greenloop_private.company_job_available(j.id)then raise exception 'This phone is with Chaman or in transit. Confirm Greenloop receiving first.'using errcode='22023';end if;
 if exists(select 1 from public.export_box_items where device_id=p_device)then raise exception 'This phone is in a box. Use Box Correction first.'using errcode='22023';end if;
 if exists(select 1 from public.supplier_returns where device_id=p_device and archived_at is null and status in('requested','approved','returned'))then raise exception 'This phone has a supplier return. Resolve the return first.'using errcode='22023';end if;
 if j.ownership_type<>'company_owned'or j.current_status is distinct from d.current_status or greenloop_private.scp_stage(j.id)='unavailable'then raise exception 'This phone is not in an eligible company workflow.'using errcode='22023';end if;
 select *into w from public.job_work_orders where job_id=j.id;
 v:=jsonb_build_object('job',to_jsonb(j),'device',to_jsonb(d),'work_order',to_jsonb(w),
 'steps',coalesce((select jsonb_agg(to_jsonb(x)order by x.id)from public.job_work_order_steps x where work_order_id=w.id),'[]'),
 'inspections',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.initial_qc_inspections x where job_id=j.id),'[]'),
 'requirements',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.initial_qc_part_requirements x where job_id=j.id),'[]'),
 'findings',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.initial_qc_findings x where inspection_id in(select id from public.initial_qc_inspections where job_id=j.id)),'[]'),
 'issuance',(select to_jsonb(x)from greenloop_private.qc_saved_issuance x where job_id=j.id),
 'parts',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.job_part_requests x where job_id=j.id),'[]'),
 'issues',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.part_issue_transactions x where part_request_id in(select id from public.job_part_requests where job_id=j.id)),'[]'),
 'installations',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.part_installations x where part_request_id in(select id from public.job_part_requests where job_id=j.id)),'[]'),
 'orders',coalesce((select jsonb_agg(to_jsonb(x)order by id)from greenloop_private.parts_flow_orders x where job_id=j.id),'[]'),
 'services',coalesce((select jsonb_agg(to_jsonb(x)order by cycle)from greenloop_private.lab_only_services x where job_id=j.id),'[]'),
 'timer',(select to_jsonb(x)from public.technician_job_timers x where job_id=j.id),
 'final_qc',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.final_qc_inspections x where job_id=j.id),'[]'),
 'frame',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.frame_department_results x where job_id=j.id),'[]'),
 'returns',coalesce((select jsonb_agg(to_jsonb(x)order by id)from greenloop_private.parts_flow_returns x where order_id in(select id from greenloop_private.parts_flow_orders where job_id=j.id)),'[]'),
 'legacy_returns',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.lab_part_return_requests x where job_id=j.id),'[]'));
 return v;
end;$f$;
create or replace function greenloop_private.scp_read(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare d jsonb;ctx jsonb;job uuid;st text;inspection uuid;dest jsonb:='[]';k text;why text;blocked jsonb:='[]';begin
 perform greenloop_private.scp_require(false);d:=greenloop_private.wfs_read(p_identifier);ctx:=greenloop_private.scp_scope((d->>'device_id')::uuid);job:=(ctx->'job'->>'id')::uuid;st:=greenloop_private.scp_stage(job);
 inspection:=coalesce((ctx->'work_order'->>'initial_qc_inspection_id')::uuid,(ctx->'issuance'->>'inspection_id')::uuid,(select id from public.initial_qc_inspections where job_id=job order by inspected_at desc,id desc limit 1));
 if exists(select 1 from public.job_part_requests where job_id=job and status in('requested','partially_issued'))then blocked:=blocked||jsonb_build_array('Parts pending. Issue or cancel the pending requests in Parts.');end if;
 if exists(select 1 from greenloop_private.parts_flow_returns where order_id in(select id from greenloop_private.parts_flow_orders where job_id=job)and status='pending')or exists(select 1 from public.lab_part_return_requests where job_id=job and status='pending')then blocked:=blocked||jsonb_build_array('Part return pending. Complete the Parts review first.');end if;
 if st='lab_glass'then
  d:=greenloop_private.lbt_phone(ctx->'device'->>'imei_1');
  if exists(select 1 from jsonb_array_elements_text(d->'reasons')x where x ilike '%service%')then blocked:=blocked||jsonb_build_array('Services pending. Save or resolve the services in Lab & Glass.');end if;
 end if;
 foreach k in array array['initial_qc','issuance','lab_glass','final_qc','b_dept','ready_stock']loop
  if k=st then continue;end if;why:=null;
  if jsonb_array_length(blocked)>0 then why:=blocked->>0;
  elsif k<>'initial_qc'and inspection is null then why:='Complete Initial QC first.';
  elsif st='initial_qc'then why:='Complete the Initial QC review and save it for Issuance first.';
  elsif st in('initial_qc','issuance')and k in('final_qc','b_dept','ready_stock')then why:='Issue and complete the saved work through its normal workflow first.';
  elsif k in('issuance','lab_glass')and nullif(ctx->'device'->>'gc_grade','')is null then why:='Save the Initial QC GL Grade first.';
  elsif k in('final_qc','b_dept','ready_stock')and ctx->'work_order'->>'id'is null then why:='Issue the saved inspection through Issuance first.';
  elsif k='final_qc'and st='lab_glass'and not coalesce((d->>'ready')::boolean,false)then why:='Resolve the pending Lab & Glass work first.';
  elsif k in('b_dept','ready_stock')then
   -- A Reports move cannot manufacture a QC pass. A pass must belong to the
   -- current Final QC visit, after the latest stage correction/rework entry.
   if st<>'final_qc'or not exists(select 1 from public.final_qc_inspections q where q.job_id=job and q.result='pass'and q.inspected_at>=coalesce((select max(at)from greenloop_private.stage_change_audit where job_id=job),'-infinity')and q.inspected_at>=coalesce((select max(assigned_at)from public.job_work_order_steps where work_order_id=(ctx->'work_order'->>'id')::uuid and department='final_qc'),'-infinity')and (k<>'ready_stock'or not q.routed_to_frame))then why:='A current Final QC pass is required. Complete Final QC through its normal inspection.';end if;
  end if;
  dest:=dest||jsonb_build_array(jsonb_build_object('key',k,'label',greenloop_private.scp_label(k),'allowed',why is null,'reason',why));
 end loop;
 return jsonb_build_object('version','20261119-stage-change-parts-1','device_id',ctx->'device'->'id','job_id',job,'imei',ctx->'device'->'imei_1','current_stage',st,'current_label',greenloop_private.scp_label(st),'destinations',dest,'blockers',blocked,'snapshot',md5(ctx::text),
 'technicians',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name)order by full_name,id)from public.technician_roster where is_active),'[]'));
end;$f$;
create or replace function public.get_imei_stage_change_v1(p_identifier text)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $f$select greenloop_private.scp_read(p_identifier);$f$;
create or replace function greenloop_private.scp_cancel_case(p_job uuid,p_device uuid,p_source text,p_stage text,p_reason text,p_before jsonb)returns uuid language plpgsql security definer set search_path=pg_catalog,public as $f$
declare result uuid;tech text;ids uuid[];begin
 select coalesce(nullif(s.assigned_technician_name,''),t.full_name)into tech from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id left join public.technician_roster t on t.id=s.assigned_technician_roster_id where w.job_id=p_job and s.step_status='in_progress'order by s.assigned_at desc nulls last,s.id limit 1;
 tech:=coalesce(nullif(tech,''),(select technician_name from public.technician_job_timers where job_id=p_job),(select assigned_technician_name from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id where w.job_id=p_job and s.department in('laboratory','glass')and nullif(s.assigned_technician_name,'')is not null order by s.assigned_at desc nulls last,s.id limit 1));
 select coalesce(array_agg(i.id order by i.id),'{}')into ids from public.part_issue_transactions i where part_request_id in(select id from public.job_part_requests where job_id=p_job)and not exists(select 1 from greenloop_private.cancelled_phone_cases c where c.issue_ids@>array[i.id]);
 -- Freeze requested/issued membership at cancellation, independently of later
 -- collection, reordering or technician assignment changes.
 p_before:=p_before||jsonb_build_object('cancelled_parts',coalesce((select jsonb_agg(to_jsonb(r)order by id)from public.job_part_requests r where job_id=p_job),'[]'));
 insert into greenloop_private.cancelled_phone_cases(source_key,job_id,device_id,stage,technician,actor,reason,issue_ids,before_data)values(p_source,p_job,p_device,p_stage,tech,auth.uid(),p_reason,ids,p_before)on conflict(source_key)do nothing returning id into result;return result;
end;$f$;
create or replace function greenloop_private.scp_apply(p_device uuid,p_snapshot text,p_destination text,p_technician uuid,p_reason text,p_code text,p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $f$
declare ctx jsonb;review jsonb;cmd jsonb;prior greenloop_private.stage_change_audit%rowtype;j public.jobs%rowtype;w public.job_work_orders%rowtype;tech public.technician_roster%rowtype;st text;dest text:=p_destination;loc uuid;step uuid;inspection uuid;response jsonb;res jsonb;case_id uuid;begin
 perform greenloop_private.scp_require(true);
 if p_request is null or p_code is distinct from '1213'or length(btrim(coalesce(p_reason,'')))not between 5 and 2000 or dest not in('initial_qc','issuance','lab_glass','final_qc','b_dept','ready_stock')then raise exception 'Choose a destination and enter a valid correction reason and code.'using errcode='22023';end if;
 cmd:=jsonb_build_object('device',p_device,'snapshot',p_snapshot,'destination',dest,'technician',p_technician,'reason',p_reason);
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into prior from greenloop_private.stage_change_audit where request_id=p_request;
 if found then if prior.actor<>auth.uid()or prior.command<>cmd then raise exception 'This request belongs to different stage changes.'using errcode='22023';end if;return prior.response||'{"replayed":true}';end if;
 perform 1 from public.jobs where device_id=p_device order by id for update;perform 1 from public.devices where id=p_device for update;
 ctx:=greenloop_private.scp_scope(p_device);if md5(ctx::text)is distinct from p_snapshot then raise exception 'The workflow changed after review. Reload before changing stage.'using errcode='40001';end if;
 review:=greenloop_private.scp_read(ctx->'device'->>'imei_1');
 if not exists(select 1 from jsonb_array_elements(review->'destinations')x where x->>'key'=dest and (x->>'allowed')::boolean)then raise exception '%',coalesce((select x->>'reason'from jsonb_array_elements(review->'destinations')x where x->>'key'=dest),'Choose a different allowed stage.')using errcode='22023';end if;
 select *into strict j from public.jobs where id=(ctx->'job'->>'id')::uuid;select *into w from public.job_work_orders where job_id=j.id;st:=greenloop_private.scp_stage(j.id);
 inspection:=coalesce(w.initial_qc_inspection_id,(ctx->'issuance'->>'inspection_id')::uuid,(select id from public.initial_qc_inspections where job_id=j.id order by inspected_at desc,id desc limit 1));
 if dest='lab_glass'then select *into tech from public.technician_roster where id=p_technician and is_active for share;if not found then raise exception 'Choose an active Lab technician.'using errcode='22023';end if;elsif p_technician is not null then raise exception 'A technician is selected only for Lab & Glass.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('apply_imei_stage_change_v1',jsonb_build_object('p_device_id',p_device));perform greenloop_private.pf_context(true);
 response:=jsonb_build_object('saved',true,'request_id',p_request,'imei',ctx->'device'->>'imei_1','from_stage',st,'to_stage',dest);
 insert into greenloop_private.stage_change_audit(request_id,job_id,device_id,actor,from_stage,to_stage,reason,command,before_data,response)values(p_request,j.id,p_device,auth.uid(),st,dest,p_reason,cmd,ctx,response);
 -- Only abandoning work creates a cancellation notice. A normal completed
 -- Lab handover to Final QC is not a cancelled phone.
 if st in('lab_glass','b_dept','final_qc')and (dest in('initial_qc','issuance','lab_glass')or st='b_dept'and dest='final_qc')then
  case_id:=greenloop_private.scp_cancel_case(j.id,p_device,'stage:'||p_request,greenloop_private.scp_label(st),p_reason,ctx);
 end if;
 if st='lab_glass'and dest='final_qc'then
  select id into strict step from public.job_work_order_steps where work_order_id=w.id and department in('laboratory','glass')and step_status='in_progress';
  res:=public.complete_lab_technician_line(step);
 else
  -- Preserve the previous visit and its clock in the immutable before-scope.
  update public.technician_job_timers set stopped_at=now(),stopped_by=auth.uid(),elapsed_seconds=greatest(0,extract(epoch from now()-started_at)::integer)where job_id=j.id and stopped_at is null;
  update public.job_work_order_steps set step_status='skipped',returned_at=now()where work_order_id=w.id and step_status='in_progress';
  if dest in('initial_qc','issuance')then
   select id into strict loc from public.locations where location_code='INITIAL-QC'and is_active;
   delete from greenloop_private.qc_saved_issuance where job_id=j.id;
   update greenloop_private.stage_qc_leases set finished_at=now()where job_id=j.id and finished_at is null;
   if w.id is not null then insert into greenloop_private.stage_qc_leases(job_id,work_order_id,request_id)values(j.id,w.id,p_request)on conflict(job_id)do update set work_order_id=excluded.work_order_id,request_id=excluded.request_id,finished_at=null;end if;
   if dest='issuance'then
    insert into greenloop_private.qc_saved_issuance(job_id,device_id,inspection_id,request_id,payload_hash,saved_by,saved_by_name)values(j.id,p_device,inspection,p_request,md5(cmd::text),auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'));
   elsif inspection is not null then
    if exists(select 1 from greenloop_private.workflow_reopened_qc where job_id=j.id and resaved_at is null)then raise exception 'This phone already has an open Initial QC review. Reload its current stage.'using errcode='40001';end if;
    insert into greenloop_private.workflow_reopened_qc(request_id,job_id,device_id,inspection_id,original_data)values(p_request,j.id,p_device,inspection,ctx);
   end if;
   update public.jobs set current_status='initial_qc_pending',current_location_id=loc where id=j.id;update public.devices set current_status='initial_qc_pending',current_location_id=loc where id=p_device;
  elsif dest='lab_glass'and st in('initial_qc','issuance')then
   if not exists(select 1 from greenloop_private.qc_saved_issuance where job_id=j.id and state='awaiting_issuance')then raise exception 'Save the Initial QC review for Issuance first.'using errcode='22023';end if;
   res:=public.issue_initial_qc_inspection_v1(j.id,greenloop_private.qcis_revision(j.id),'lab_glass',tech.id,p_request);
  else
   if w.id is null then raise exception 'This phone needs a saved workflow. Issue it through Issuance first.'using errcode='22023';end if;
   select id into strict loc from public.locations where location_code=case dest when 'lab_glass'then 'LAB'when 'final_qc'then 'FINAL-QC'when 'b_dept'then 'FRAME'when 'ready_stock'then 'PRODUCTION'end and is_active;
   update public.job_work_orders set status=case when dest='ready_stock'then 'completed'else 'open'end where id=w.id;
   if dest<>'ready_stock'then
    select id into step from public.job_work_order_steps where work_order_id=w.id and department::text=case dest when 'lab_glass'then 'laboratory'when 'final_qc'then 'final_qc'else 'frame'end;
    if step is null then insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_at)values(w.id,coalesce((select max(step_order)+1 from public.job_work_order_steps where work_order_id=w.id),10),case dest when 'lab_glass'then 'laboratory'::public.work_department when 'final_qc'then 'final_qc'::public.work_department else 'frame'::public.work_department end,'in_progress',now())returning id into step;
    else update public.job_work_order_steps set step_status='in_progress',assigned_at=now(),returned_at=null,rework_count=rework_count+1 where id=step;end if;
   end if;
   update public.jobs set current_status=case dest when 'lab_glass'then 'laboratory_pending'::public.job_status when 'final_qc'then 'final_qc_pending'::public.job_status when 'b_dept'then 'frame_pending'::public.job_status else 'production_pending'::public.job_status end,current_location_id=loc where id=j.id;
   update public.devices set current_status=(select current_status from public.jobs where id=j.id),current_location_id=loc where id=p_device;
   if dest='lab_glass'then
    update public.job_work_order_steps set assigned_technician_roster_id=tech.id,assigned_technician_id=null,assigned_technician_name=tech.full_name where id=step;
    insert into public.laboratory_work_records(job_id,device_id,work_order_step_id,rework_cycle,assigned_at,started_at,notes)values(j.id,p_device,step,(select rework_count from public.job_work_order_steps where id=step),now(),now(),'Reports stage correction: '||p_reason);
    perform greenloop_private.handover_technician_timer(j.id,p_device,tech.id,'Reports stage correction');
    -- Final QC follows this new Lab visit, even when an earlier QC visit
    -- already occupies its unique department step.
    update public.job_work_order_steps set step_status='pending',step_order=(select max(step_order)+1 from public.job_work_order_steps where work_order_id=w.id)where work_order_id=w.id and department='final_qc';
    if not found then insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(w.id,(select max(step_order)+1 from public.job_work_order_steps where work_order_id=w.id),'final_qc','pending');end if;
   end if;
  end if;
  if res is null then insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)values(p_device,j.id,j.current_location_id,loc,'Reports stage correction: '||greenloop_private.scp_label(st)||' to '||greenloop_private.scp_label(dest),auth.uid());end if;
 end if;
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(p_device,j.id,'reports_stage_correction','Reports stage correction',jsonb_build_object('audit_id',p_request,'before',jsonb_build_object('stage',greenloop_private.scp_label(st)),'after',jsonb_build_object('stage',greenloop_private.scp_label(dest)),'reason',p_reason,'technician_name',tech.full_name,'cancelled_case_id',case_id),auth.uid());
 insert into greenloop_private.workflow_stage_audit(request_id,device_id,actor,reason,command,before_data,after_data,response)values(p_request,p_device,auth.uid(),p_reason,jsonb_build_object('action','stage_change','kind','stage','row_key',j.id),jsonb_build_object('stage',greenloop_private.scp_label(st)),jsonb_build_object('stage',greenloop_private.scp_label(dest)),response);
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();return response;
end;$f$;
create or replace function public.apply_imei_stage_change_v1(p_device_id uuid,p_snapshot text,p_destination text,p_technician uuid,p_reason text,p_code text,p_request_id uuid)returns jsonb language sql security definer set search_path=pg_catalog,public as $f$select greenloop_private.scp_apply(p_device_id,p_snapshot,p_destination,p_technician,p_reason,p_code,p_request_id);$f$;

-- A narrowly scoped lease lets the existing reinspection and Issuance paths
-- reuse their one work order. Their original validation and audit remain active.
sig:='greenloop_private.bdept_return_order(uuid)';old:=pg_get_functiondef(sig::regprocedure);
if not exists(select 1 from greenloop_private.bdept_qc_return_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Reinspection source integrity differs.';end if;
if md5(regexp_replace(old,'\s','','g'))<>'50fe2b2c0e4b1d5e333fa9885da78d67'then raise exception 'Reinspection helper shape differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
create or replace function greenloop_private.bdept_return_order(p_job uuid)returns uuid language sql stable set search_path=pg_catalog,public as $f$
 select work_order_id from greenloop_private.bdept_qc_returns where job_id=p_job and finished_at is null
 union all select l.work_order_id from greenloop_private.stage_qc_leases l where l.job_id=p_job and l.finished_at is null and not exists(select 1 from greenloop_private.bdept_qc_returns where job_id=p_job and finished_at is null) limit 1;$f$;
create or replace function greenloop_private.scp_close_lease()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $f$begin if new.state='issued'and old.state='awaiting_issuance'then update greenloop_private.stage_qc_leases set finished_at=now()where job_id=new.job_id and finished_at is null;end if;return new;end;$f$;
create trigger stage_lease_finished after update on greenloop_private.qc_saved_issuance for each row execute function greenloop_private.scp_close_lease();
sig:='greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)';old:=pg_get_functiondef(sig::regprocedure);
if position('''Bulk IMEI Correction'''in old)=0 or position('Unknown technician timer handover.'in old)=0 then raise exception 'Technician handover boundary differs.';end if;
-- The prior installation receipts must match before extending this private helper.
if not exists(select 1 from greenloop_private.technician_timer_handover_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Technician handover source integrity differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
updated:=regexp_replace(old,$q$'Bulk IMEI Correction'\s*\)$q$,$q$'Bulk IMEI Correction','Reports stage correction')$q$);if updated=old then raise exception 'Technician source pattern differs.';end if;execute updated;
sig:='greenloop_private.wfs_read(text)';old:=pg_get_functiondef(sig::regprocedure);
if not exists(select 1 from greenloop_private.workflow_stage_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Workflow correction history integrity differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
updated:=regexp_replace(old,$q$'before'\s*,\s*case\s+when\s+a\.command\s*->>\s*'action'\s*=\s*'move_back'$q$,$q$'before',case when a.command->>'action'='stage_change'then a.before_data when a.command->>'action'='move_back'$q$);
updated:=regexp_replace(updated,$q$'after'\s*,\s*case\s+when\s+a\.command\s*->>\s*'action'\s*=\s*'move_back'$q$,$q$'after',case when a.command->>'action'='stage_change'then a.after_data when a.command->>'action'='move_back'$q$);
if updated=old or position($q$'stage_change'then a.before_data$q$in updated)=0 or position($q$'stage_change'then a.after_data$q$in updated)=0 then raise exception 'Workflow stage history pattern differs.';end if;execute updated;

-- Actual cancelled work orders are captured without relabelling ordinary
-- completed work. This trigger does not run during installation.
create or replace function greenloop_private.scp_work_cancelled()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $f$begin
 if new.status='cancelled'and old.status is distinct from new.status then perform greenloop_private.scp_cancel_case(new.job_id,new.device_id,'work-order:'||new.id||':'||txid_current(),'Lab & Glass','Work order cancelled',jsonb_build_object('work_order',to_jsonb(old)));end if;return new;
end;$f$;
create trigger stage_work_cancelled after update on public.job_work_orders for each row execute function greenloop_private.scp_work_cancelled();

create or replace function greenloop_private.scp_unused(p_ids uuid[])returns table(issue_id uuid,request_id uuid,order_id uuid,part_name text,available integer,pending integer)language sql stable security definer set search_path=pg_catalog,public as $f$
select i.id,i.part_request_id,m.order_id,r.part_name,
 greatest(0,i.quantity_issued-coalesce(i.quantity_returned,0)-coalesce((select sum(quantity_installed)from public.part_installations where part_issue_id=i.id),0))::integer,
 coalesce((select sum(quantity)from greenloop_private.parts_flow_returns where issue_id=i.id and status='pending'),0)::integer
 +coalesce((select sum(quantity)from public.lab_part_return_requests where part_request_id=i.part_request_id and status='pending'),0)::integer
from public.part_issue_transactions i join public.job_part_requests r on r.id=i.part_request_id left join greenloop_private.parts_flow_requests m on m.request_id=r.id where i.id=any(p_ids);$f$;
create or replace function greenloop_private.scp_parts_cases(p_tab text,p_offset integer,p_snapshot text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare rows jsonb;token text;n bigint;pending_count bigint;begin
 perform greenloop_private.pf_cap('parts','view');if p_tab not in('pending','completed')or p_offset is null or p_offset<0 or p_offset%50<>0 then raise exception 'Choose a valid 50-phone cancellation page.'using errcode='22023';end if;
 with cases as(select c.*,exists(select 1 from greenloop_private.scp_unused(c.issue_ids)where available>0)needs_collection from greenloop_private.cancelled_phone_cases c)
 select count(distinct device_id)filter(where needs_collection),md5(coalesce(jsonb_agg(jsonb_build_array(id,needs_collection,(select jsonb_agg(to_jsonb(x)order by issue_id)from greenloop_private.scp_unused(issue_ids)x))order by at desc,id),'[]')::text)into pending_count,token from cases;
 if(p_offset>0 and p_snapshot is null)or(p_snapshot is not null and p_snapshot<>token)then raise exception 'Cancelled phone records changed. Refresh before paging.'using errcode='40001';end if;
 select count(*)into n from greenloop_private.cancelled_phone_cases c where exists(select 1 from greenloop_private.scp_unused(c.issue_ids)where available>0)=(p_tab='pending');
 select coalesce(jsonb_agg(x order by at desc,id),'[]')into rows from(select c.id,c.stage,c.technician,c.at,c.reason,coalesce(u.full_name,'Not recorded')actor_name,d.imei_1 imei,d.model,d.storage_gb,d.color,
 coalesce((select jsonb_agg(distinct r->>'part_name')from jsonb_array_elements(c.before_data->'cancelled_parts')r where (r->>'quantity_issued')::integer>0),'[]')issued_parts,
 coalesce((select jsonb_agg(distinct r->>'part_name')from jsonb_array_elements(c.before_data->'cancelled_parts')r where r->>'status'in('requested','partially_issued')and (r->>'quantity_requested')::integer>(r->>'quantity_issued')::integer),'[]')pending_parts,
 'This phone was cancelled from '||c.stage||'. Please collect any parts that need to be returned by '||coalesce(nullif(c.technician,''),'the assigned technician')||'.'message
 from greenloop_private.cancelled_phone_cases c join public.devices d on d.id=c.device_id left join public.user_profiles u on u.id=c.actor
 where exists(select 1 from greenloop_private.scp_unused(c.issue_ids)where available>0)=(p_tab='pending')order by c.at desc,c.id offset p_offset limit 50)x;
 return jsonb_build_object('version','20261119-stage-change-parts-1','rows',rows,'total',n,'pending_count',pending_count,'offset',p_offset,'snapshot',token);
end;$f$;
create or replace function public.get_cancelled_parts_phones_v1(p_tab text default 'pending',p_offset integer default 0,p_snapshot text default null)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $f$select greenloop_private.scp_parts_cases(p_tab,p_offset,p_snapshot);$f$;
create or replace function public.get_cancelled_phone_parts_v1(p_case_id uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare c greenloop_private.cancelled_phone_cases%rowtype;v jsonb;begin perform greenloop_private.pf_cap('parts','view');select *into strict c from greenloop_private.cancelled_phone_cases where id=p_case_id;
 select coalesce(jsonb_agg(to_jsonb(x)order by issue_id),'[]')into v from greenloop_private.scp_unused(c.issue_ids)x;
 return jsonb_build_object('case_id',c.id,'parts',v,'snapshot',md5(v::text));end;$f$;
create or replace function public.collect_cancelled_phone_part_v1(p_case_id uuid,p_issue_id uuid,p_snapshot text,p_quantity integer,p_classification text,p_notes text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $f$
declare c greenloop_private.cancelled_phone_cases%rowtype;x record;cmd jsonb;prior greenloop_private.cancelled_part_collections%rowtype;v jsonb;ret uuid;rev integer;begin
 perform greenloop_private.pf_cap('parts','return');perform pg_advisory_xact_lock(19920261026);
 cmd:=jsonb_build_object('case',p_case_id,'issue',p_issue_id,'snapshot',p_snapshot,'quantity',p_quantity,'classification',p_classification,'notes',p_notes);
 if p_request_id is null or p_quantity is null or p_quantity<1 then raise exception 'Confirm the actual quantity collected.'using errcode='22023';end if;
 select *into prior from greenloop_private.cancelled_part_collections where request_id=p_request_id;if found then if prior.actor<>auth.uid()or prior.command<>cmd then raise exception 'This collection request belongs to different parts.'using errcode='22023';end if;return jsonb_build_object('saved',true,'request_id',p_request_id,'return_id',prior.return_id,'replayed',true);end if;
 select *into strict c from greenloop_private.cancelled_phone_cases where id=p_case_id;perform 1 from public.part_issue_transactions where id=any(c.issue_ids)order by id for update;
 v:=public.get_cancelled_phone_parts_v1(p_case_id);if v->>'snapshot'is distinct from p_snapshot then raise exception 'Parts changed. Reload before confirming collection.'using errcode='40001';end if;
 select *into x from greenloop_private.scp_unused(c.issue_ids)where issue_id=p_issue_id;
 if x.issue_id is null or x.order_id is null or p_quantity>x.available-x.pending then raise exception 'These parts are installed, returned, pending review or not available. Use the existing return review for legacy issues.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('collect_cancelled_phone_part_v1',jsonb_build_object('p_case_id',p_case_id));perform greenloop_private.pf_context(true);
 select revision into strict rev from greenloop_private.parts_flow_orders where id=x.order_id for update;
 insert into greenloop_private.parts_flow_returns(order_id,issue_id,quantity,notes,requested_by)values(x.order_id,p_issue_id,p_quantity,'Cancelled phone collection: '||coalesce(p_notes,c.reason),auth.uid())returning id into ret;
 perform public.review_parts_flow_return_v1(x.order_id,rev,ret,true,p_classification,false,p_notes);
 if p_classification='not_needed'and not exists(select 1 from public.job_part_requests r where r.job_id=c.job_id and greenloop_private.pp_key(r.part_name)=greenloop_private.pp_key(x.part_name)and r.status<>'cancelled'and r.quantity_requested>r.quantity_returned+r.quantity_installed)then
  perform greenloop_private.pf_context(true);
  update public.initial_qc_part_requirements set status='not_required',reviewed_by=auth.uid(),reviewed_at=now()where job_id=c.job_id and greenloop_private.pp_key(part_name)=greenloop_private.pp_key(x.part_name)and status not in('not_required','cancelled');
 end if;
 insert into greenloop_private.cancelled_part_collections(request_id,case_id,actor,command,return_id)values(p_request_id,p_case_id,auth.uid(),cmd,ret);
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();return jsonb_build_object('saved',true,'request_id',p_request_id,'return_id',ret);
end;$f$;
create or replace function public.get_parts_pending_counts_v2()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$declare v jsonb;n bigint;begin
 perform greenloop_private.pf_cap('parts','view');v:=public.get_parts_pending_imei_counts_v1();
 select count(distinct device_id)into n from greenloop_private.cancelled_phone_cases c where exists(select 1 from greenloop_private.scp_unused(c.issue_ids)where available>0);
 return v||jsonb_build_object('cancelled',n);end;$f$;

-- All source changes above are checked against their exact prior receipts.
for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
end loop;
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"workflow_stage_change","label":"Change IMEI workflow stage (audited)","write":true}]'::jsonb where page_key='reports';
update greenloop_private.user_page_capabilities uc set capabilities=jsonb_set(capabilities,'{reports}',coalesce(capabilities->'reports','[]')||'["workflow_stage_change"]')where capabilities->'reports'?'workflow_correction'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=uc.user_id and r.role_key::text in('owner','super_admin'));
update greenloop_private.report_access_sections set config=jsonb_set(config,'{actions}',(config->'actions')||'["workflow_stage_change"]')where report_key='data_correction';
insert into greenloop_private.report_access_dependencies values('workflow_stage_change','"report_imei_correction"')on conflict(capability)do update set required_views=excluded.required_views;
insert into greenloop_private.capability_rpc_rules values('get_imei_stage_change_v1','{"page":"reports","capability":"workflow_correction","read":true}'),('apply_imei_stage_change_v1','{"page":"reports","capability":"workflow_stage_change"}'),('get_cancelled_parts_phones_v1','{"page":"parts","capability":"view","read":true}'),('get_cancelled_phone_parts_v1','{"page":"parts","capability":"view","read":true}'),('collect_cancelled_phone_part_v1','{"page":"parts","capability":"return"}'),('get_parts_pending_counts_v2','{"page":"parts","capability":"view","read":true}'),('get_stage_change_parts_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by page_key)::text)from greenloop_private.page_capability_catalog r)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table greenloop_private.stage_change_parts_installation(identity text primary key,hash text not null);
for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relname in('stage_change_audit','stage_qc_leases','cancelled_phone_cases','cancelled_part_collections','stage_change_parts_installation')loop execute format('alter table %s enable row level security;revoke all on %s from public,anon,authenticated',t.name,t.name);end loop;
-- Seal every new helper/API and the two reviewed existing helpers.
sealed:=array['greenloop_private.scp_immutable()','greenloop_private.scp_stage(uuid)','greenloop_private.scp_label(text)','greenloop_private.scp_require(boolean)','greenloop_private.scp_scope(uuid)','greenloop_private.scp_read(text)','greenloop_private.scp_cancel_case(uuid,uuid,text,text,text,jsonb)','greenloop_private.scp_apply(uuid,text,text,uuid,text,text,uuid)','greenloop_private.scp_close_lease()','greenloop_private.scp_work_cancelled()','greenloop_private.scp_unused(uuid[])','greenloop_private.scp_parts_cases(text,integer,text)','greenloop_private.bdept_return_order(uuid)','greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)','public.get_imei_stage_change_v1(text)','public.apply_imei_stage_change_v1(uuid,text,text,uuid,text,text,uuid)','public.get_cancelled_parts_phones_v1(text,integer,text)','public.get_cancelled_phone_parts_v1(uuid)','public.collect_cancelled_phone_part_v1(uuid,uuid,text,integer,text,text,uuid)','public.get_stage_change_parts_version()'];
sealed:=sealed||array['public.get_parts_pending_counts_v2()'];
sealed:=sealed||array['greenloop_private.wfs_read(text)'];
foreach sig in array sealed loop if to_regprocedure(sig)is null and sig<>'public.get_stage_change_parts_version()'then raise exception 'Stage installation routine missing: %',sig;end if;if sig<>'public.get_stage_change_parts_version()'then execute format('revoke all on function %s from public,anon,authenticated',sig);if sig like 'public.%'then execute format('grant execute on function %s to authenticated',sig);end if;end if;end loop;
create or replace function public.get_stage_change_parts_version()returns text language sql stable security definer set search_path=pg_catalog,public as $f$
select case when public.get_receipt_supplier_correction_version()='20261119-receipt-supplier-correction-1'and(select count(*)=22 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.stage_change_parts_installation)
and not exists(select 1 from greenloop_private.stage_change_parts_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_trigger where tgname='stage_change_immutable'and tgenabled='O'and tgfoid='greenloop_private.scp_immutable()'::regprocedure)
and exists(select 1 from pg_trigger where tgname='stage_lease_finished'and tgenabled='O'and tgfoid='greenloop_private.scp_close_lease()'::regprocedure)
and(select count(*)=3 from pg_trigger where(tgname='cancelled_phone_immutable'and tgrelid='greenloop_private.cancelled_phone_cases'::regclass and tgfoid='greenloop_private.scp_immutable()'::regprocedure or tgname='cancelled_collection_immutable'and tgrelid='greenloop_private.cancelled_part_collections'::regclass and tgfoid='greenloop_private.scp_immutable()'::regprocedure or tgname='stage_work_cancelled'and tgrelid='public.job_work_orders'::regclass and tgfoid='greenloop_private.scp_work_cancelled()'::regprocedure)and tgenabled='O')
and not exists(select 1 from greenloop_private.stage_change_parts_installation where identity like 'public.%'and identity<>'public.get_stage_change_parts_version()'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or not has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities@>'[{"key":"workflow_stage_change","write":true}]')
and exists(select 1 from greenloop_private.report_access_sections where report_key='data_correction'and config->'actions'?'workflow_stage_change')
and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='apply_imei_stage_change_v1'and rule='{"page":"reports","capability":"workflow_stage_change"}'::jsonb)
and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='collect_cancelled_phone_part_v1'and rule='{"page":"parts","capability":"return"}'::jsonb)
and not exists(select 1 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in('stage_change_audit','stage_qc_leases','cancelled_phone_cases','cancelled_part_collections','stage_change_parts_installation')and(not relrowsecurity or has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
and(select count(*)=5 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in('stage_change_audit','stage_qc_leases','cancelled_phone_cases','cancelled_part_collections','stage_change_parts_installation'))
and exists(select 1 from pg_index where indexrelid=to_regclass('public.stage_parts_install_issue_idx')and indrelid='public.part_installations'::regclass and indisvalid and indisready and indnkeyatts=1 and indnatts=2 and indkey[0]=(select attnum from pg_attribute where attrelid='public.part_installations'::regclass and attname='part_issue_id')and indkey[1]=(select attnum from pg_attribute where attrelid='public.part_installations'::regclass and attname='quantity_installed'))
then '20261119-stage-change-parts-1'end;$f$;
revoke all on function public.get_stage_change_parts_version()from public;grant execute on function public.get_stage_change_parts_version()to anon,authenticated;
insert into greenloop_private.stage_change_parts_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_stage_change_parts_version()is distinct from '20261119-stage-change-parts-1'then raise exception 'Stage correction verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_stage_change_parts_version()as installed_stage_change_parts_version;
