-- Reports-only bulk inline correction; no business rows change during installation.
begin;
do $$begin if public.get_workflow_stage_controls_version()is distinct from '20261105-workflow-stage-controls-1'then raise exception 'Install verified Workflow Stage Controls first.';end if;end;$$;
create table if not exists greenloop_private.bulk_imei_audit(request_id uuid primary key,actor uuid not null,changed_at timestamptz not null default now(),reason text not null,payload_hash text not null,changes jsonb not null,response jsonb not null);
alter table greenloop_private.bulk_imei_audit enable row level security;revoke all on greenloop_private.bulk_imei_audit from public,anon,authenticated;
drop trigger if exists bulk_imei_audit_immutable on greenloop_private.bulk_imei_audit;
create trigger bulk_imei_audit_immutable before update or delete on greenloop_private.bulk_imei_audit for each row execute function greenloop_private.wf_audit_immutable();
do $$begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @>'[{"key":"bulk_imei_correction"}]')then
 update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"bulk_imei_correction","label":"Bulk IMEI Correction (editable table)","write":true}]'where page_key='reports';
 update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',(capabilities->'reports')||'["bulk_imei_correction"]')where capabilities->'reports'?'workflow_correction'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
 end if;
 update greenloop_private.report_access_sections set config=jsonb_set(config,'{actions}',(config->'actions')||'["bulk_imei_correction"]')where report_key='data_correction'and not(config->'actions'?'bulk_imei_correction');
end;$$;
create or replace function greenloop_private.bci_guard()returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.wf_guard();perform greenloop_private.pf_cap('reports','bulk_imei_correction');end;$$;
create or replace function greenloop_private.bci_options()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.bci_guard();return jsonb_build_object(
 'receipts',coalesce((select jsonb_agg(to_jsonb(r)order by r.received_at desc,r.batch_id)from greenloop_private.sc_receipts()r),'[]'),
 'models',coalesce((select jsonb_agg(n order by n)from(select distinct option_value n from public.entry_options where option_group='model'and is_active)x),'[]'),
 'colors',coalesce((select jsonb_agg(n order by n)from(select distinct option_value n from public.entry_options where option_group='color'and is_active)x),'[]'),
 'parts',coalesce((select jsonb_agg(n order by n)from(select distinct option_value n from public.entry_options where option_group='part_name'and is_active)x),'[]'),
 'services',coalesce((select jsonb_agg(name order by name)from greenloop_private.qc_service_options),'[]'),
 'supplier_grades',coalesce((select jsonb_agg(name order by name)from greenloop_private.qc_grade_options where kind='supplier_grade'),'[]'),
 'gl_grades',coalesce((select jsonb_agg(name order by name)from greenloop_private.qc_grade_options where kind='gc_grade'),'[]'));
end;$$;
create or replace function greenloop_private.bci_row(p_device uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d public.devices%rowtype;j public.jobs%rowtype;i public.initial_qc_inspections%rowtype;f public.final_qc_inspections%rowtype;o greenloop_private.parts_flow_orders%rowtype;stock record;step uuid;mode text:='none';parts jsonb:='[]';services jsonb:='[]';plan jsonb;locked text;fp text;final_bh integer;begin
 select *into d from public.devices where id=p_device and deleted_at is null;if d.id is null then return null;end if;
 select *into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1;if j.id is null then return null;end if;
 select *into stock from greenloop_private.sc_receipts()where batch_id=j.receiving_batch_id;
 select *into i from public.initial_qc_inspections where job_id=j.id order by inspected_at desc,created_at desc,id desc limit 1;
 select *into f from public.final_qc_inspections where job_id=j.id order by inspected_at desc,created_at desc,id desc limit 1;
 select *into o from greenloop_private.parts_flow_orders where job_id=j.id and cycle=greenloop_private.pf_cycle(j.id)limit 1;
 select s.id into step from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id where w.job_id=j.id and s.department in('laboratory','glass')and s.step_status='in_progress'order by s.created_at desc,s.id desc limit 1;
 if i.id is not null and not exists(select 1 from public.job_work_orders where job_id=j.id)and not exists(select 1 from public.job_part_requests where job_id=j.id and status<>'cancelled')and j.current_status='initial_qc_pending'then mode:='inspection';
 elsif step is not null and o.id is not null and o.completed_at is null and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')then mode:='lab';end if;
 if mode='lab'then plan:=greenloop_private.pp_plan(step);select coalesce(jsonb_agg(distinct x->>'name'),'[]')into parts from jsonb_array_elements(plan->'parts')x;select names into services from greenloop_private.lab_only_services where job_id=j.id and cycle=o.cycle;
 else select coalesce(jsonb_agg(distinct part_name),'[]')into parts from public.initial_qc_part_requirements where inspection_id=i.id and status not in('not_required','cancelled');end if;
 if services is null or mode<>'lab'then select coalesce(jsonb_agg(distinct check_item),'[]')into services from public.initial_qc_findings where inspection_id=i.id and issue_found and public.is_initial_qc_service(check_item);end if;
 final_bh:=f.final_battery_health;if f.id is null then select battery_health into final_bh from greenloop_private.qc_direct_ready where job_id=j.id;end if;
 if exists(select 1 from public.export_box_items where device_id=d.id)then locked:='Phone is recorded in a box. Use Box Correction / recheck first.';
 elsif exists(select 1 from public.supplier_returns where device_id=d.id and archived_at is null and status in('requested','approved','returned'))then locked:='Supplier Return hold or completed return. Use Return/Replacement workflow.';end if;
 fp:=md5(jsonb_build_object('device',to_jsonb(d),'job',to_jsonb(j),'rows',(select jsonb_agg(to_jsonb(x)order by kind,row_key)from greenloop_private.wf_rows(d.id)x),'issuance',(select to_jsonb(s)from greenloop_private.qc_saved_issuance s where job_id=j.id),'direct',(select to_jsonb(q)from greenloop_private.qc_direct_ready q where job_id=j.id),'order',to_jsonb(o))::text);
 return jsonb_build_object('device_id',d.id,'job_id',j.id,'imei',d.imei_1,'revision',fp,'current_stage',greenloop_private.jrl_location(j.current_status::text,greenloop_private.jst_stage(j.current_status::text,j.id,d.id)),'read_only_reason',locked,'work_mode',mode,'can_change_receipt',not exists(select 1 from public.job_work_orders where job_id=j.id)and not exists(select 1 from public.job_part_requests where job_id=j.id and status<>'cancelled')and f.id is null and not exists(select 1 from greenloop_private.qc_direct_ready where job_id=j.id),'has_final_bh',f.id is not null or exists(select 1 from greenloop_private.qc_direct_ready where job_id=j.id),
 'supplier_label',concat_ws(' ',coalesce(stock.supplier_code,(select supplier_code from public.suppliers where id=j.supplier_id))||case when stock.received_quantity is null then ''else '-('||stock.received_quantity||')'end,stock.supplier_name),'batch_number',stock.batch_number,'invoice_number',stock.invoice_number,'stock_received',stock.received_quantity,'stock_returned',stock.returned_quantity,'stock_replaced',stock.replacement_quantity,'stock_balance',stock.balance_quantity,
 'values',jsonb_build_object('model',d.model,'storage_gb',d.storage_gb,'color',d.color,'initial_bh',d.battery_health,'final_bh',final_bh,'batch_id',j.receiving_batch_id,'supplier_grade',j.supplier_grade,'gl_grade',d.gc_grade,'parts',coalesce(parts,'[]'),'services',coalesce(services,'[]')));
end;$$;
create or replace function greenloop_private.bci_read(p_imeis text[],p_batch_id uuid,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.bci_guard();if p_offset is null or p_offset<0 or(p_batch_id is null and coalesce(cardinality(p_imeis),0)=0)or(p_batch_id is not null and coalesce(cardinality(p_imeis),0)>0)or exists(select 1 from unnest(p_imeis)x where x!~'^[0-9]{15}$')then raise exception 'Choose one batch or a valid list of 15-digit IMEIs.'using errcode='22023';end if;
 with matches as materialized(select d.id,min(coalesce(a.n,1))ord from public.devices d join lateral(select *from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by received_at desc,created_at desc,id desc limit 1)j on true left join unnest(p_imeis)with ordinality a(imei,n)on a.imei=d.imei_1 or a.imei=d.imei_2 where d.deleted_at is null and(case when p_batch_id is not null then j.receiving_batch_id=p_batch_id else a.imei is not null end)group by d.id),page as(select id,ord from matches order by ord,id offset p_offset limit 50)
 select jsonb_build_object('total',(select count(*)from matches),'rows',coalesce((select jsonb_agg(greenloop_private.bci_row(id)order by ord,id)from page),'[]'),'missing',coalesce((select jsonb_agg(x)from(select distinct x from unnest(p_imeis)x where not exists(select 1 from public.devices d join public.jobs j on j.device_id=d.id and j.deleted_at is null where d.deleted_at is null and(x=d.imei_1 or x=d.imei_2)))m),'[]'))into result;return result;
end;$$;
create or replace function greenloop_private.bci_work(p_job uuid,p_parts jsonb,p_services jsonb)returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.jobs%rowtype;i uuid;o greenloop_private.parts_flow_orders%rowtype;step uuid;mode text;r record;n text;rid uuid;begin
 select *into j from public.jobs where id=p_job and deleted_at is null;mode:=greenloop_private.bci_row(j.device_id)->>'work_mode';
 if mode='none'then raise exception 'Parts/services require an active saved inspection or Lab line. Use normal inspection or Rework first.'using errcode='22023';end if;
 if jsonb_typeof(p_parts)is distinct from 'array'or jsonb_typeof(p_services)is distinct from 'array'or exists(select 1 from jsonb_array_elements(p_parts||p_services)x where jsonb_typeof(x)<>'string'or length(x#>>'{}')not between 1 and 120)then raise exception 'Choose valid parts and services.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements_text(p_parts)x group by greenloop_private.pp_key(x)having count(*)>1)or exists(select 1 from jsonb_array_elements_text(p_services)x group by greenloop_private.pp_key(x)having count(*)>1)then raise exception 'Each part or service can appear only once.'using errcode='22023';end if;
 for n in select value from jsonb_array_elements_text(p_parts)loop
 if not exists(select 1 from public.entry_options where option_group='part_name'and is_active and option_value=n)and not exists(select 1 from jsonb_array_elements_text(greenloop_private.bci_row(j.device_id)->'values'->'parts')x where x=n)then raise exception 'Choose a saved part: %',n using errcode='22023';end if;end loop;
 for n in select value from jsonb_array_elements_text(p_services)loop
 if not exists(select 1 from greenloop_private.qc_service_options where name=n and(mode='lab'or initial_qc))and not exists(select 1 from jsonb_array_elements_text(greenloop_private.bci_row(j.device_id)->'values'->'services')x where x=n)then raise exception 'Choose a saved service: %',n using errcode='22023';end if;end loop;
 select id into i from public.initial_qc_inspections where job_id=p_job order by inspected_at desc,created_at desc,id desc limit 1;
 if mode='lab'then
 select *into o from greenloop_private.parts_flow_orders where job_id=p_job and cycle=greenloop_private.pf_cycle(p_job)for update;
 step:=o.step_id;perform greenloop_private.pf_step(step);
 for r in select q.*from public.job_part_requests q join greenloop_private.parts_flow_requests m on m.request_id=q.id where m.order_id=o.id and q.status<>'cancelled'and exists(select 1 from jsonb_array_elements(greenloop_private.pp_plan(step)->'parts')x where x->>'request_id'=q.id::text)loop
 if not exists(select 1 from jsonb_array_elements_text(p_parts)x where greenloop_private.pp_key(x)=greenloop_private.pp_key(r.part_name))then
 if r.quantity_issued>0 then raise exception 'Return the issued % part first. Its physical issue cannot be removed by correction.',r.part_name using errcode='22023';end if;
 update public.job_part_requests set status='cancelled',updated_at=now()where id=r.id;
 update public.initial_qc_part_requirements set status='not_required',reviewed_by=auth.uid(),reviewed_at=now()where inspection_id=i and greenloop_private.pp_key(part_name)=greenloop_private.pp_key(r.part_name);
 end if;end loop;
 for n in select value from jsonb_array_elements_text(p_parts)loop
 if not exists(select 1 from public.job_part_requests q join greenloop_private.parts_flow_requests m on m.request_id=q.id where m.order_id=o.id and q.status<>'cancelled'and exists(select 1 from jsonb_array_elements(greenloop_private.pp_plan(step)->'parts')x where x->>'request_id'=q.id::text)and greenloop_private.pp_key(q.part_name)=greenloop_private.pp_key(n))then
 if exists(select 1 from public.job_part_requests q join greenloop_private.parts_flow_requests m on m.request_id=q.id where m.order_id=o.id and q.quantity_issued>0 and greenloop_private.pp_key(q.part_name)=greenloop_private.pp_key(n))then raise exception 'Use Lab Return / replacement order for the previously issued % part.',n using errcode='22023';end if;
 insert into public.job_part_requests(job_id,device_id,part_name,quantity_requested,request_source,requested_by,requested_for_technician)values(p_job,j.device_id,n,1,'technician_additional',auth.uid(),(select assigned_technician_name from public.job_work_order_steps where id=step))returning id into rid;
 insert into greenloop_private.parts_flow_requests(request_id,order_id)values(rid,o.id);
 end if;end loop;
 insert into greenloop_private.lab_only_services(job_id,cycle,step_id,names,saved_by)values(p_job,o.cycle,step,p_services,auth.uid())on conflict(job_id,cycle)do update set names=excluded.names,saved_at=now(),saved_by=excluded.saved_by,revision=greenloop_private.lab_only_services.revision+1;
 update greenloop_private.parts_flow_orders set revision=revision+1 where id=o.id;
 insert into greenloop_private.parts_flow_audit(order_id,action,actor,details)values(o.id,'reports_bulk_correction',auth.uid(),jsonb_build_object('parts',p_parts,'services',p_services));
 else
 update public.initial_qc_part_requirements set status='not_required'where inspection_id=i and status not in('not_required','cancelled')and not exists(select 1 from jsonb_array_elements_text(p_parts)x where greenloop_private.pp_key(x)=greenloop_private.pp_key(part_name));
 for n in select value from jsonb_array_elements_text(p_parts)loop
 select id into rid from public.initial_qc_part_requirements where inspection_id=i and greenloop_private.pp_key(part_name)=greenloop_private.pp_key(n)order by(status not in('not_required','cancelled'))desc,identified_at,id limit 1;
 if rid is null then insert into public.initial_qc_part_requirements(job_id,device_id,inspection_id,part_name,quantity_required,identified_by)values(p_job,j.device_id,i,n,1,auth.uid());else update public.initial_qc_part_requirements set status='identified'where id=rid;end if;
 end loop;
 update public.initial_qc_findings set issue_found=false where inspection_id=i and issue_found and(public.is_initial_qc_service(check_item)or exists(select 1 from public.initial_qc_part_requirements p where p.inspection_id=i and greenloop_private.pp_key(p.part_name)=greenloop_private.pp_key(check_item)))and not exists(select 1 from jsonb_array_elements_text(p_parts||p_services)x where greenloop_private.pp_key(x)=greenloop_private.pp_key(check_item));
 for n in select value from jsonb_array_elements_text(p_parts||p_services)loop
 select id into rid from public.initial_qc_findings where inspection_id=i and greenloop_private.pp_key(check_item)=greenloop_private.pp_key(n)order by issue_found desc,id limit 1;
 if rid is null then insert into public.initial_qc_findings(inspection_id,check_item,issue_found,action_required,department,priority)values(i,n,true,n,'laboratory','normal');else update public.initial_qc_findings set issue_found=true where id=rid;end if;
 end loop;
 update public.initial_qc_inspections set work_required=jsonb_array_length(p_parts||p_services)>0 where id=i;
 insert into greenloop_private.qc_issuance_amendments(request_id,job_id,device_id,inspection_id,actor_id,payload_hash,before_revision,after_revision,before_work,after_work)select gen_random_uuid(),p_job,j.device_id,i,auth.uid(),md5((p_parts||p_services)::text),repeat('0',32),coalesce(greenloop_private.qcis_revision(p_job),repeat('0',32)),'{}',jsonb_build_object('parts',p_parts,'services',p_services);
 end if;
end;$$;
create or replace function greenloop_private.bci_save(p_rows jsonb,p_reason text,p_code text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare x jsonb;old jsonb;nowrow jsonb;patch jsonb;v jsonb;a jsonb:='[]';seen uuid[]:='{}';dev uuid;job uuid;before_j public.jobs%rowtype;newbatch public.receiving_batches%rowtype;prior greenloop_private.bulk_imei_audit%rowtype;fingerprint text;result jsonb;begin
 perform greenloop_private.bci_guard();if p_code is distinct from '1213'or p_request_id is null or length(btrim(coalesce(p_reason,'')))not between 5 and 2000 or jsonb_typeof(p_rows)is distinct from 'array'or jsonb_array_length(p_rows)=0 then raise exception 'Enter changed rows, a reason and valid correction code.'using errcode='22023';end if;
 fingerprint:=md5(jsonb_build_object('rows',p_rows,'reason',p_reason)::text);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into prior from greenloop_private.bulk_imei_audit where request_id=p_request_id;
 if found then if prior.actor<>auth.uid()or prior.payload_hash<>fingerprint then raise exception 'This save request belongs to different changes.'using errcode='22023';end if;return prior.response||'{"replayed":true}';end if;
 for x in select value from jsonb_array_elements(p_rows)loop
 dev:=(x->>'device_id')::uuid;job:=(x->>'job_id')::uuid;
 if dev is null or dev=any(seen)then raise exception 'Choose each phone once.'using errcode='22023';end if;seen:=array_append(seen,dev);
 perform 1 from public.jobs where device_id=dev and deleted_at is null order by id for update;perform 1 from public.devices where id=dev and deleted_at is null for update;
 old:=greenloop_private.bci_row(dev);
 if old is null or old->>'job_id'is distinct from job::text or old->>'revision'is distinct from x->>'revision'then raise exception 'IMEI % changed. Reload before saving. No changes were saved.',coalesce(old->>'imei',dev::text)using errcode='40001';end if;
 if old->>'read_only_reason'is not null then raise exception '%',old->>'read_only_reason'using errcode='22023';end if;
 patch:=x->'patch';if jsonb_typeof(patch)is distinct from 'object'or patch='{}'or exists(select 1 from jsonb_object_keys(patch)k where k not in('model','storage_gb','color','initial_bh','final_bh','batch_id','supplier_grade','gl_grade','parts','services'))then raise exception 'Choose supported correction cells.'using errcode='22023';end if;
 v:=(old->'values')||patch;
 if nullif(btrim(v->>'model'),'')is null or length(v->>'model')>120 or length(coalesce(v->>'color',''))>120 or(v->>'storage_gb')is null or(v->>'storage_gb')::integer not between 1 and 16384 then raise exception 'Enter valid Model, GB and Color.'using errcode='22023';end if;
 if(patch?'initial_bh'and(patch->>'initial_bh')is not null and(patch->>'initial_bh')::integer not between 0 and 100)or(patch?'final_bh'and((patch->>'final_bh')is null or(patch->>'final_bh')::integer not between 1 and 100 or not(old->>'has_final_bh')::boolean))then raise exception 'Enter valid Battery Health; Final BH requires an existing result.'using errcode='22023';end if;
 if patch?'supplier_grade'and not greenloop_private.qc_grade_allowed('supplier_grade',patch->>'supplier_grade')or patch?'gl_grade'and not greenloop_private.qc_grade_allowed('gc_grade',patch->>'gl_grade')then raise exception 'Choose a saved Supplier or GL Grade.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('save_bulk_imei_correction_v1',jsonb_build_object('p_device_id',dev));perform greenloop_private.pf_context(true);
 if patch?'batch_id'and patch->'batch_id'is distinct from old->'values'->'batch_id'then
 if not(old->>'can_change_receipt')::boolean then raise exception 'This phone already has downstream work. Use Full Workflow Correction for linked receipt changes.'using errcode='22023';end if;
 select *into newbatch from public.receiving_batches where id=(patch->>'batch_id')::uuid for update;
 if newbatch.id is null or newbatch.supplier_id is null or exists(select 1 from public.suppliers where id=newbatch.supplier_id and deleted_at is not null)then raise exception 'Choose a valid saved Stock/Batch.'using errcode='22023';end if;
 if newbatch.planned_quantity is not null and newbatch.planned_quantity<=(select count(*)from public.jobs where receiving_batch_id=newbatch.id and deleted_at is null)then raise exception 'This Stock/Batch has no remaining capacity.'using errcode='22023';end if;
 update public.jobs set receiving_batch_id=newbatch.id,supplier_id=newbatch.supplier_id where id=job;
 end if;
 update public.devices set model=case when patch?'model'then btrim(v->>'model')else model end,storage_gb=case when patch?'storage_gb'then(v->>'storage_gb')::integer else storage_gb end,color=case when patch?'color'then nullif(btrim(v->>'color'),'')else color end,battery_health=case when patch?'initial_bh'then(v->>'initial_bh')::smallint else battery_health end,battery_health_unavailable=case when patch?'initial_bh'then(v->>'initial_bh')is null else battery_health_unavailable end,original_grade=case when patch?'supplier_grade'then v->>'supplier_grade'else original_grade end,gc_grade=case when patch?'gl_grade'then v->>'gl_grade'else gc_grade end where id=dev;
 if patch?'supplier_grade'then update public.jobs set supplier_grade=v->>'supplier_grade'where id=job;end if;
 if patch?'final_bh'then
 if exists(select 1 from public.final_qc_inspections where job_id=job)then update public.final_qc_inspections set final_battery_health=(v->>'final_bh')::smallint,final_battery_health_unavailable=false where id=(select id from public.final_qc_inspections where job_id=job order by inspected_at desc,created_at desc,id desc limit 1);
 else update greenloop_private.qc_direct_ready set battery_health=(v->>'final_bh')::smallint where job_id=job;end if;end if;
 if patch?'parts'or patch?'services'then perform greenloop_private.bci_work(job,v->'parts',v->'services');end if;
 nowrow:=greenloop_private.bci_row(dev);a:=a||jsonb_build_array(jsonb_build_object('device_id',dev,'job_id',job,'imei',old->>'imei','before',old->'values','after',nowrow->'values'));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(dev,job,'bulk_imei_corrected','IMEI corrected in Reports table',jsonb_build_object('audit_id',p_request_id,'reason',btrim(p_reason),'before',old->'values','after',nowrow->'values'),auth.uid());
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();
 end loop;
 update greenloop_private.qc_work_usage_cache set built_at='-infinity'where singleton=true;
 update public.workflow_notification_signal set revision=revision+1 where id=1;
 result:=jsonb_build_object('saved',true,'request_id',p_request_id,'phones',jsonb_array_length(a));
 insert into greenloop_private.bulk_imei_audit(request_id,actor,reason,payload_hash,changes,response)values(p_request_id,auth.uid(),btrim(p_reason),fingerprint,a,result);return result;
end;$$;
create or replace function public.get_bulk_imei_correction_options_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.bci_options();end;$$;
create or replace function public.get_bulk_imei_correction_v1(p_imeis text[] default null,p_batch_id uuid default null,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.bci_read(p_imeis,p_batch_id,p_offset);end;$$;
create or replace function public.save_bulk_imei_correction_v1(p_rows jsonb,p_reason text,p_code text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.bci_save(p_rows,p_reason,p_code,p_request_id);end;$$;

create or replace function greenloop_private.bci_history(d jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_set(d,'{history}',coalesce(d->'history','[]')||coalesce((select jsonb_agg(jsonb_build_object('id',a.request_id,'changed_at',a.changed_at,'actor',coalesce(p.full_name,'Staff'),'reason',a.reason,'changes',jsonb_build_array(jsonb_build_object('kind','bulk_table','before',x->'before','after',x->'after')))order by a.changed_at desc)from greenloop_private.bulk_imei_audit a left join public.user_profiles p on p.id=a.actor cross join lateral jsonb_array_elements(a.changes)x where x->>'device_id'=d->>'device_id'),'[]'));
$$;
create or replace function public.get_full_imei_workflow_v2(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.bci_history(greenloop_private.wfs_read(p_identifier));end;$$;
update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef('public.get_full_imei_workflow_v2(text)'::regprocedure))where to_regprocedure(identity)='public.get_full_imei_workflow_v2(text)'::regprocedure;
update greenloop_private.workflow_stage_installation set hash=md5(pg_get_functiondef('public.get_full_imei_workflow_v2(text)'::regprocedure))where to_regprocedure(identity)='public.get_full_imei_workflow_v2(text)'::regprocedure;

insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)select a,b,md5(pg_get_functiondef(to_regprocedure(b))),md5(pg_get_functiondef(to_regprocedure(a)))from(values('public.get_bulk_imei_correction_options_v1()','greenloop_private.bci_options()'),('public.get_bulk_imei_correction_v1(text[],uuid,integer)','greenloop_private.bci_read(text[],uuid,integer)'),('public.save_bulk_imei_correction_v1(jsonb,text,text,uuid)','greenloop_private.bci_save(jsonb,text,text,uuid)'))x(a,b)on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_bulk_imei_correction_options_v1','{"page":"reports","capability":"bulk_imei_correction","read":true}'),('get_bulk_imei_correction_v1','{"page":"reports","capability":"bulk_imei_correction","read":true}'),('save_bulk_imei_correction_v1','{"page":"reports","capability":"bulk_imei_correction"}'),('get_bulk_imei_correction_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.report_access_dependencies(capability,required_views)values('bulk_imei_correction','"report_imei_correction"')on conflict(capability)do update set required_views=excluded.required_views;
update greenloop_private.report_access_config_seal set dependencies_hash=(select md5(jsonb_agg(to_jsonb(d)order by capability)::text)from greenloop_private.report_access_dependencies d),sections_hash=(select md5(jsonb_agg(to_jsonb(s)order by report_key)::text)from greenloop_private.report_access_sections s)where singleton;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $$declare f record;begin for f in select oid::regprocedure id from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'bci_%'loop execute format('revoke all on function %s from public,anon,authenticated',f.id);end loop;for f in select oid::regprocedure id from pg_proc where pronamespace='public'::regnamespace and proname in('get_bulk_imei_correction_options_v1','get_bulk_imei_correction_v1','save_bulk_imei_correction_v1')loop execute format('revoke all on function %s from public,anon,authenticated',f.id);execute format('grant execute on function %s to authenticated',f.id);end loop;end;$$;
create table if not exists greenloop_private.bulk_imei_installation(identity text primary key,hash text not null);alter table greenloop_private.bulk_imei_installation enable row level security;revoke all on greenloop_private.bulk_imei_installation from public,anon,authenticated;
insert into greenloop_private.bulk_imei_installation select oid::regprocedure::text,md5(pg_get_functiondef(oid))from pg_proc where(pronamespace='greenloop_private'::regnamespace and proname like 'bci_%')or(pronamespace='public'::regnamespace and proname in('get_bulk_imei_correction_options_v1','get_bulk_imei_correction_v1','save_bulk_imei_correction_v1','get_full_imei_workflow_v2'))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_bulk_imei_correction_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_workflow_stage_controls_version()='20261105-workflow-stage-controls-1'and(select count(*)=11 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.bulk_imei_installation)and not exists(select 1 from greenloop_private.bulk_imei_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))and not has_table_privilege('authenticated','greenloop_private.bulk_imei_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261106-bulk-imei-correction-1'end;$$;
revoke all on function public.get_bulk_imei_correction_version()from public;grant execute on function public.get_bulk_imei_correction_version()to anon,authenticated;
do $$begin if public.get_bulk_imei_correction_version()is distinct from '20261106-bulk-imei-correction-1'then raise exception 'Bulk IMEI Correction verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_bulk_imei_correction_version()as installed_bulk_imei_correction_version;

