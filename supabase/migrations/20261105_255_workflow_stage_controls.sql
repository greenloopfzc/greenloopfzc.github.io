-- Reports-only stage drill-down and audited operations. No install-time business changes.
begin;
do $$begin if public.get_lab_overdue_card_version()is distinct from '20261105-lab-overdue-card-1'then raise exception 'Install verified Lab Overdue Card first.';end if;end;$$;
create table if not exists greenloop_private.workflow_stage_audit(request_id uuid primary key,device_id uuid not null,actor uuid not null,changed_at timestamptz not null default now(),reason text not null,command jsonb not null,before_data jsonb not null,after_data jsonb not null,response jsonb not null);
alter table greenloop_private.workflow_stage_audit enable row level security;
revoke all on greenloop_private.workflow_stage_audit from public,anon,authenticated;
drop trigger if exists workflow_stage_audit_immutable on greenloop_private.workflow_stage_audit;
create trigger workflow_stage_audit_immutable before update or delete on greenloop_private.workflow_stage_audit for each row execute function greenloop_private.wf_audit_immutable();
create table if not exists greenloop_private.workflow_reopened_qc(request_id uuid primary key,job_id uuid not null,device_id uuid not null,inspection_id uuid not null,original_data jsonb not null,reopened_at timestamptz not null default now(),resaved_at timestamptz,resave_request uuid unique,response jsonb);
create unique index if not exists workflow_reopened_qc_open on greenloop_private.workflow_reopened_qc(job_id)where resaved_at is null;
alter table greenloop_private.workflow_reopened_qc add column if not exists resave_payload_hash text;
alter table greenloop_private.workflow_reopened_qc enable row level security;revoke all on greenloop_private.workflow_reopened_qc from public,anon,authenticated;
do $$declare x jsonb;begin
 for x in select value from jsonb_array_elements('[{"key":"workflow_delete","label":"Delete IMEI workflow entries (Reports only)","write":true},{"key":"workflow_move_back","label":"Move Issuance back to Initial QC (Reports only)","write":true}]')loop
  if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @>jsonb_build_array(jsonb_build_object('key',x->>'key')))then
   update greenloop_private.page_capability_catalog set capabilities=capabilities||jsonb_build_array(x)where page_key='reports';
   update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',coalesce(capabilities->'reports','[]')||jsonb_build_array(x->>'key'))where capabilities->'reports'?'workflow_correction'and exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=c.user_id and ro.role_key::text in('owner','super_admin'));
  end if;
 end loop;
 update greenloop_private.report_access_sections set config=jsonb_set(config,'{actions}',(config->'actions')||'["workflow_delete","workflow_move_back"]')where report_key='data_correction'and not(config->'actions'?'workflow_delete');
end;$$;

create or replace function greenloop_private.wfs_qc_prefill(d jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select case when exists(select 1 from greenloop_private.workflow_reopened_qc a where a.job_id=(d->'job'->>'id')::uuid and a.resaved_at is null)then d||jsonb_build_object('reopened_inspection',(
 select jsonb_build_object('parts',coalesce((select jsonb_agg(p.part_name order by p.identified_at,p.id)from public.initial_qc_part_requirements p where p.inspection_id=a.inspection_id and p.status not in('not_required','cancelled')),'[]'),
 'services',coalesce((select jsonb_agg(f.check_item order by f.created_at,f.id)from public.initial_qc_findings f where f.inspection_id=a.inspection_id and f.issue_found),'[]'))from greenloop_private.workflow_reopened_qc a where a.job_id=(d->'job'->>'id')::uuid and a.resaved_at is null))else d end;
$$;

create or replace function greenloop_private.wfs_qc_resave(p_job_id uuid,p_findings jsonb,p_part_requests jsonb,p_supplier_grade text,p_gc_grade text,p_notes text,p_request_id uuid,p_direct_ready boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.workflow_reopened_qc%rowtype;r jsonb;fingerprint text;begin
 perform greenloop_private.qcis_require(true);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 if p_request_id is null then raise exception 'A save request is required.'using errcode='22023';end if;
 fingerprint:=md5(jsonb_build_array(p_job_id,p_findings,p_part_requests,p_supplier_grade,p_gc_grade,p_notes,p_direct_ready)::text);
 select *into a from greenloop_private.workflow_reopened_qc where job_id=p_job_id order by reopened_at desc for update limit 1;
 if a.job_id is null then raise exception 'This phone was not reopened for Initial QC.'using errcode='22023';end if;
 if a.resaved_at is not null then if a.resave_request=p_request_id and a.resave_payload_hash=fingerprint then return a.response;end if;raise exception 'This reopened inspection has already been saved. Reload its current stage.'using errcode='22023';end if;
 if exists(select 1 from public.job_work_orders where job_id=p_job_id)or exists(select 1 from greenloop_private.qc_saved_issuance where job_id=p_job_id)or not exists(select 1 from public.jobs where id=p_job_id and deleted_at is null and current_status='initial_qc_pending')then raise exception 'This phone has already advanced. Reload before saving.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('save_reopened_initial_qc_v1',jsonb_build_object('p_job_id',p_job_id));perform greenloop_private.pf_context(true);
 delete from public.initial_qc_part_requirements where inspection_id=a.inspection_id;
 delete from public.initial_qc_findings where inspection_id=a.inspection_id;
 delete from public.initial_qc_inspections where id=a.inspection_id and job_id=p_job_id;
 if p_direct_ready then r:=public.save_initial_qc_direct_ready_v1(p_job_id,p_findings,p_part_requests,p_supplier_grade,p_gc_grade,p_notes,p_request_id);
 else r:=public.save_initial_qc_inspection_v1(p_job_id,p_findings,p_part_requests,p_supplier_grade,p_gc_grade,p_notes,p_request_id);end if;
 update greenloop_private.workflow_reopened_qc set resaved_at=now(),resave_request=p_request_id,resave_payload_hash=fingerprint,response=r where request_id=a.request_id;
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();return r;
end;$$;

create or replace function greenloop_private.wfs_save(p_device_id uuid,p_snapshot text,p_changes jsonb,p_reason text,p_code text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare d jsonb;x jsonb;e jsonb;old_changes jsonb;result jsonb;before_data jsonb;request uuid:=gen_random_uuid();begin
 perform greenloop_private.wf_guard();if p_code is distinct from '1213'or length(btrim(coalesce(p_reason,'')))not between 5 and 2000 or jsonb_typeof(p_changes)is distinct from 'array'or jsonb_array_length(p_changes)not between 1 and 1000 then raise exception 'Enter valid changes, reason and correction code.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);perform 1 from public.jobs where device_id=p_device_id and deleted_at is null order by id for update;
 d:=greenloop_private.wfs_read((select imei_1 from public.devices where id=p_device_id and deleted_at is null));if d->>'snapshot'is distinct from p_snapshot then raise exception 'This workflow changed. Reload before saving.'using errcode='40001';end if;
 select coalesce(jsonb_agg(c),'[]')into old_changes from jsonb_array_elements(p_changes)c where c->>'kind'not in('supplier_return','direct_ready');
 if jsonb_array_length(old_changes)>0 then result:=public.save_full_imei_workflow_v1(p_device_id,d->>'legacy_snapshot',old_changes,p_reason,p_code);end if;
 for x in select value from jsonb_array_elements(p_changes)where value->>'kind'='direct_ready'loop
  select value into e from jsonb_array_elements(d->'entries')where value->>'kind'='direct_ready'and value->>'row_key'=x->>'row_key';
  if e is null or e->>'revision'is distinct from x->>'revision'or jsonb_typeof(x->'patch')is distinct from 'object'or exists(select 1 from jsonb_object_keys(x->'patch')k where k not in('final_grade','final_battery_health'))then raise exception 'Choose valid direct Ready Stock corrections.'using errcode='22023';end if;
  if x->'patch'?'final_grade'and not greenloop_private.qc_grade_allowed('gc_grade',x->'patch'->>'final_grade')then raise exception 'Choose a saved GL grade.'using errcode='22023';end if;
  if x->'patch'?'final_battery_health'and(x->'patch'->>'final_battery_health'is null or(x->'patch'->>'final_battery_health')::integer not between 1 and 100)then raise exception 'Final BH must be 1 to 100.'using errcode='22023';end if;
  if exists(select 1 from public.export_box_items where device_id=p_device_id)then raise exception 'This phone is recorded in a box. Use Box Correction/recheck before changing its stock outcome.'using errcode='22023';end if;
  select to_jsonb(r)into before_data from greenloop_private.qc_direct_ready r where job_id=(x->>'row_key')::uuid and device_id=p_device_id for update;
  update greenloop_private.qc_direct_ready set final_grade=case when x->'patch'?'final_grade'then x->'patch'->>'final_grade'else final_grade end,battery_health=case when x->'patch'?'final_battery_health'then(x->'patch'->>'final_battery_health')::smallint else battery_health end where job_id=(x->>'row_key')::uuid and device_id=p_device_id;
  insert into greenloop_private.workflow_stage_audit(request_id,device_id,actor,reason,command,before_data,after_data,response)values(request,p_device_id,auth.uid(),p_reason,jsonb_build_object('action','edit','kind','direct_ready','row_key',x->>'row_key'),before_data,(select to_jsonb(r)from greenloop_private.qc_direct_ready r where job_id=(x->>'row_key')::uuid),'{"saved":true}');request:=gen_random_uuid();
 end loop;
 for x in select value from jsonb_array_elements(p_changes)where value->>'kind'='supplier_return'loop
  select value into e from jsonb_array_elements(d->'entries')where value->>'kind'='supplier_return'and value->>'row_key'=x->>'row_key';
  if e is null or e->>'revision'is distinct from x->>'revision'or jsonb_typeof(x->'patch')is distinct from 'object'or exists(select 1 from jsonb_object_keys(x->'patch')k where k not in('reason','notes'))or coalesce(x->'patch'->>'reason',e->'values'->>'reason','')not in('dead','icloud_locked','other')or(coalesce(x->'patch'->>'reason',e->'values'->>'reason')='other'and nullif(btrim(coalesce(x->'patch'->>'notes',e->'values'->>'notes')),'')is null) or length(coalesce(x->'patch'->>'notes',''))>2000 then raise exception 'Use valid return reason/notes for this phone. Settlement and quantities require the Return/Replacement workflow.'using errcode='22023';end if;
  select to_jsonb(r)into before_data from public.supplier_returns r where id=(x->>'row_key')::uuid and device_id=p_device_id for update;
  perform greenloop_private.begin_capability('save_full_imei_workflow_v2',jsonb_build_object('p_device_id',p_device_id));
  insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),(x->>'row_key')::uuid)on conflict do nothing;
  update public.supplier_returns set reason=case when x->'patch'?'reason'then x->'patch'->>'reason'else reason end,notes=case when x->'patch'?'notes'then x->'patch'->>'notes'else notes end where id=(x->>'row_key')::uuid and device_id=p_device_id;
  insert into greenloop_private.workflow_stage_audit(request_id,device_id,actor,reason,command,before_data,after_data,response)values(request,p_device_id,auth.uid(),p_reason,jsonb_build_object('action','edit','kind','supplier_return','row_key',x->>'row_key'),before_data,(select to_jsonb(r)from public.supplier_returns r where id=(x->>'row_key')::uuid),'{"saved":true}');
  delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id=(x->>'row_key')::uuid;
  request:=gen_random_uuid();perform greenloop_private.end_capability();
 end loop;
 return coalesce(result,jsonb_build_object('saved',true,'imei',d->>'imei'));
end;$$;

create or replace function greenloop_private.wfs_extra(p_device uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(e),'[]')from(
 select jsonb_build_object('kind','issuance','row_key',s.job_id,'job_id',s.job_id,'revision',md5(to_jsonb(s)::text),'label','Saved inspection / Issuance','section','Lab & Glass Issuance','state',s.state,'context',coalesce(s.destination,'Awaiting technician / destination'),'values',jsonb_build_object('saved_at',s.saved_at,'issued_at',s.issued_at),'fields','[]'::jsonb,'read_only_reason','Requirements are corrected using the Initial QC records in this section. Move back reopens inspection without losing its saved work.')e
 from greenloop_private.qc_saved_issuance s join public.jobs j on j.id=s.job_id and j.deleted_at is null where s.device_id=p_device
 union all select jsonb_build_object('kind','direct_ready','row_key',r.job_id,'job_id',r.job_id,'revision',md5(to_jsonb(r)::text),'label','Direct Initial QC Ready Stock outcome','section','Ready Stock','state','recorded release','context','Initial QC - no work required','values',jsonb_build_object('final_grade',r.final_grade,'final_battery_health',r.battery_health,'ready_at',r.ready_at),'fields',jsonb_build_array(jsonb_build_object('key','final_grade','type','text','nullable',false),jsonb_build_object('key','final_battery_health','type','number','nullable',false)))from greenloop_private.qc_direct_ready r where r.device_id=p_device
 union all select jsonb_build_object('kind','supplier_return','row_key',r.id,'job_id',r.job_id,'revision',md5(to_jsonb(r)::text),'label','Supplier Return / Replacement','section','Return/Replacement','state',r.status,'context',r.return_number,'values',jsonb_build_object('reason',r.reason,'notes',r.notes,'requested_at',r.requested_at,'handed_over_at',r.handed_over_at,'settlement_reference',r.settlement_reference),'fields',jsonb_build_array(jsonb_build_object('key','reason','type','select','nullable',false,'choices',jsonb_build_array('dead','icloud_locked','other')),jsonb_build_object('key','notes','type','text','nullable',true)))
 from public.supplier_returns r where r.device_id=p_device and r.archived_at is null
 union all select jsonb_build_object('kind','box_item','row_key',i.id,'job_id',i.job_id,'revision',md5(jsonb_build_array(to_jsonb(i),to_jsonb(w))::text),'label','Box scan / Accounts verification','section','Box Entry','sections',jsonb_build_array('Box Entry')||case when w.state in('accounts','recheck','exported')then '["Accounts"]'::jsonb else '[]'::jsonb end||case when w.state='exported'then '["Stock Exported"]'::jsonb else '[]'::jsonb end,'state',coalesce(w.state,'draft'),'context',b.box_number,'values',jsonb_build_object('scanned_at',i.scanned_at,'model',i.model,'storage_gb',i.storage_gb,'color',i.color,'final_grade',i.final_grade,'verified_at',w.verified_at),'fields','[]'::jsonb,'read_only_reason','Phone details and QC outcomes are corrected at their source. Saved/verified boxes retain their linked records; use Box Correction when a recheck is required.')
 from public.export_box_items i join public.export_boxes b on b.id=i.box_id left join greenloop_private.box_workflow w on w.box_id=i.box_id where i.device_id=p_device
 union all select jsonb_build_object('kind','replacement','row_key',x.id,'job_id',j.id,'revision',md5(to_jsonb(x)::text),'label','Received replacement stock','section','Return/Replacement','state','received','context',b.batch_number,'values',jsonb_build_object('received_at',x.received_at),'fields','[]'::jsonb,'read_only_reason','This stock receipt links multiple phones. Correct the phone identity at IMEI Entry; receipt settlement and stock quantity require the Return/Replacement workflow.')
 from greenloop_private.srp_receipts x join public.jobs j on j.receiving_batch_id=x.replacement_batch_id and j.deleted_at is null join public.receiving_batches b on b.id=x.replacement_batch_id where j.device_id=p_device
 )q;
$$;

create or replace function greenloop_private.wfs_read(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare d jsonb;extras jsonb;entries jsonb;dev uuid;begin
 perform greenloop_private.wf_guard();d:=public.get_full_imei_workflow_v1(p_identifier);dev:=(d->>'device_id')::uuid;extras:=greenloop_private.wfs_extra(dev);
 select coalesce(jsonb_agg(e||jsonb_build_object('section',case e->>'kind'when 'device'then 'IMEI Entry'when 'job'then 'Stock Received'when 'frame'then 'B-DEPT'when 'final_qc'then 'Final QC'when 'movement'then 'Stock Journey'when 'step'then case when r.data->>'department'='frame'then 'B-DEPT'when r.data->>'department'='final_qc'then 'Final QC'else 'Lab & Glass'end else e->>'section'end,
 'sections',case when e->>'kind'in('initial_qc','finding','requirement')and exists(select 1 from greenloop_private.qc_saved_issuance s where s.job_id=(e->>'job_id')::uuid)then '["Initial QC","Lab & Glass Issuance"]'::jsonb when e->>'kind'='final_qc'then case when e->>'state'='pass'then '["Final QC","Ready Stock"]'::jsonb else '["Final QC"]'::jsonb end when e->>'kind'='device'then '["IMEI Entry"]'::jsonb when e->>'kind'='movement'then '["Stock Journey","Ready Stock"]'::jsonb else '[]'::jsonb end)),'[]')into entries
 from jsonb_array_elements(d->'entries')e left join lateral(select data from greenloop_private.wf_rows(dev)x where x.kind=e->>'kind'and x.row_key=e->>'row_key')r on true;
 return d||jsonb_build_object('legacy_snapshot',d->>'snapshot','snapshot',md5(jsonb_build_array(d->>'snapshot',extras)::text),'entries',entries||extras,
 'stage_actions',coalesce((select jsonb_agg(jsonb_build_object('job_id',s.job_id,'label','Move back to Initial QC','from_stage','Lab & Glass Issuance','to_stage','Initial QC'))from greenloop_private.qc_saved_issuance s join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'where s.device_id=dev and s.state='awaiting_issuance'),'[]'),
 'history',(d->'history')||coalesce((select jsonb_agg(jsonb_build_object('id',a.request_id,'changed_at',a.changed_at,'actor',coalesce(p.full_name,'Staff'),'reason',a.reason,'changes',jsonb_build_array(jsonb_build_object('kind',a.command->>'kind','before',case when a.command->>'action'='move_back'then jsonb_build_object('stage','Lab & Glass Issuance')when a.command->>'kind'='supplier_return'then jsonb_build_object('reason',a.before_data->'reason','notes',a.before_data->'notes')when a.command->>'kind'='direct_ready'then jsonb_build_object('final_grade',a.before_data->'final_grade','final_battery_health',a.before_data->'battery_health')else greenloop_private.wf_public_values(a.command->>'kind',a.before_data,coalesce((d->>'prices_visible')::boolean,false))end,'after',case when a.command->>'action'='move_back'then jsonb_build_object('stage','Initial QC','saved_requirements_preserved',true)when a.command->>'action'='delete'then jsonb_build_object('deleted',true)when a.command->>'kind'='supplier_return'then jsonb_build_object('reason',a.after_data->'reason','notes',a.after_data->'notes')when a.command->>'kind'='direct_ready'then jsonb_build_object('final_grade',a.after_data->'final_grade','final_battery_health',a.after_data->'battery_health')else jsonb_build_object('action',a.command->>'action')end)))order by a.changed_at desc)from greenloop_private.workflow_stage_audit a left join public.user_profiles p on p.id=a.actor where a.device_id=dev),'[]'));
end;$$;

-- Every destructive action has its own permission, reason, code, snapshot and
-- replay receipt. No free-form SQL, status or table names are accepted.
create or replace function greenloop_private.wfs_action(p_device_id uuid,p_snapshot text,p_action text,p_kind text,p_row_key text,p_reason text,p_code text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare d jsonb;e jsonb;before_data jsonb;after_data jsonb;locked_row jsonb;cmd jsonb;prior greenloop_private.workflow_stage_audit%rowtype;s greenloop_private.qc_saved_issuance%rowtype;sp jsonb;rec record;fk record;sql text;linked boolean;result jsonb;loc uuid;begin
 perform greenloop_private.wf_guard();perform greenloop_private.pf_cap('reports',case when p_action='move_back'then 'workflow_move_back'else 'workflow_delete'end);
 if p_action not in('move_back','delete')or p_request_id is null or p_code is distinct from '1213'or length(btrim(coalesce(p_reason,'')))not between 5 and 2000 then raise exception 'Choose an action and enter a valid reason and correction code.'using errcode='22023';end if;
 cmd:=jsonb_build_object('action',p_action,'kind',p_kind,'row_key',p_row_key,'snapshot',p_snapshot,'reason',p_reason);
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into prior from greenloop_private.workflow_stage_audit where request_id=p_request_id;if found then if prior.device_id<>p_device_id or prior.actor<>auth.uid()or prior.command<>cmd then raise exception 'This action request belongs to a different correction.'using errcode='22023';end if;return prior.response||'{"replayed":true}';end if;
 perform 1 from public.jobs where device_id=p_device_id and deleted_at is null order by id for update;perform 1 from public.devices where id=p_device_id and deleted_at is null for update;
 d:=greenloop_private.wfs_read((select imei_1 from public.devices where id=p_device_id and deleted_at is null));
 if d->>'snapshot'is distinct from p_snapshot then raise exception 'This workflow changed. Reload before applying the action.'using errcode='40001';end if;
 select x into e from jsonb_array_elements(d->'entries')x where x->>'kind'=p_kind and x->>'row_key'=p_row_key;if e is null then raise exception 'This entry does not belong to the selected phone.'using errcode='22023';end if;
 before_data:=e;
 perform greenloop_private.begin_capability('apply_imei_workflow_stage_action_v1',jsonb_build_object('p_device_id',p_device_id));perform greenloop_private.pf_context(true);
 if p_action='move_back'then
  if p_kind<>'issuance'then raise exception 'Move back is available for an untransferred Lab & Glass Issuance entry.'using errcode='22023';end if;
  select *into s from greenloop_private.qc_saved_issuance where job_id=p_row_key::uuid and device_id=p_device_id for update;
  if s.state is distinct from 'awaiting_issuance'or exists(select 1 from public.job_work_orders where job_id=s.job_id)or exists(select 1 from public.job_part_requests where job_id=s.job_id)or exists(select 1 from public.export_box_items where device_id=p_device_id)or exists(select 1 from public.supplier_returns where device_id=p_device_id and archived_at is null and status in('requested','approved','returned'))then raise exception 'This phone has downstream work, parts, a box or a supplier return. It cannot be moved back from Issuance.'using errcode='22023';end if;
  if not exists(select 1 from public.jobs where id=s.job_id and current_status='initial_qc_pending')then raise exception 'This phone has already left Issuance.'using errcode='22023';end if;
  -- The inspection is retained. Its queue receipt is removed so QC can reopen
  -- the same recorded inspection rather than duplicate it.
  before_data:=jsonb_build_object('receipt',to_jsonb(s),'inspection',(select to_jsonb(i)from public.initial_qc_inspections i where id=s.inspection_id),'parts',coalesce((select jsonb_agg(to_jsonb(p))from public.initial_qc_part_requirements p where inspection_id=s.inspection_id),'[]'),'findings',coalesce((select jsonb_agg(to_jsonb(f))from public.initial_qc_findings f where inspection_id=s.inspection_id),'[]'));
  insert into greenloop_private.workflow_reopened_qc(request_id,job_id,device_id,inspection_id,original_data)values(p_request_id,s.job_id,p_device_id,s.inspection_id,before_data);
  delete from greenloop_private.qc_saved_issuance where job_id=s.job_id;
  after_data:=jsonb_build_object('stage','Initial QC','inspection_id',s.inspection_id,'preserved_inspection',true);
 else
  if p_kind in('issuance','job','device','movement','work_order','step','issue','installation','part_price','part_return','legacy_return','supplier_return','replacement','box_item','direct_ready')then raise exception 'This entry controls linked stock, physical issues, returns or stage history. Use Move back, Box Correction or its normal return/cancellation workflow; it cannot be deleted independently.'using errcode='22023';end if;
  select x into sp from jsonb_array_elements(greenloop_private.wf_spec())x where x->>'kind'=p_kind;
  select *into rec from greenloop_private.wf_rows(p_device_id)x where x.kind=p_kind and x.row_key=p_row_key;
  if sp is null or rec.kind is null then raise exception 'This entry is not available for independent deletion.'using errcode='22023';end if;
  if p_kind='lab_services'then raise exception 'Use the service editor to remove saved service names without losing the completed-work ledger.'using errcode='22023';end if;
  execute format('select to_jsonb(t)from %s t where %I::text=$1 for update',sp->>'table',sp->>'key')into locked_row using p_row_key;
  if locked_row is null or md5(locked_row::text)is distinct from rec.revision then raise exception 'This entry changed. Reload before deleting.'using errcode='40001';end if;before_data:=locked_row;
  if p_kind in('manual_part','lab_work','glass_work')and coalesce((rec.data->>'material_cost')::numeric,(rec.data->>'unit_cost')::numeric,0)>0 then perform greenloop_private.pf_cap('parts','view');end if;
  if p_kind in('initial_qc','finding','requirement')and exists(select 1 from greenloop_private.qc_saved_issuance where job_id=rec.job_id)then raise exception 'Move the phone back from Issuance before deleting inspection entries.'using errcode='22023';end if;
  if p_kind in('final_qc','frame')and exists(select 1 from public.jobs where id=rec.job_id and current_status::text in('production_pending','exported','stocked_out'))then raise exception 'This result supports Ready Stock or an export. Correct or rework the phone before removing the result.'using errcode='22023';end if;
  if p_kind='part_request'and coalesce((rec.data->>'quantity_issued')::numeric,0)>0 then raise exception 'An issued part request cannot be deleted. Return the physical part first.'using errcode='22023';end if;
  -- Reject references even when the FK uses CASCADE: never silently delete
  -- another record or orphan a linked quantity.
  for fk in select c.*,c.conrelid::regclass child from pg_constraint c where c.contype='f'and c.confrelid=(sp->>'table')::regclass loop
   select string_agg(format('child.%I=parent.%I',ca.attname,pa.attname),' and 'order by u.n)into sql from unnest(fk.conkey,fk.confkey)with ordinality u(a,b,n)join pg_attribute ca on ca.attrelid=fk.conrelid and ca.attnum=u.a join pg_attribute pa on pa.attrelid=fk.confrelid and pa.attnum=u.b;
   execute format('select exists(select 1 from %s child join %s parent on %s where parent.%I::text=$1)',fk.child,sp->>'table',sql,sp->>'key')into linked using p_row_key;
   if linked then raise exception 'Linked records exist in %. Correct or remove those dependencies first. No records were deleted.',fk.child using errcode='22023';end if;
  end loop;
  if p_kind='lab_services'then raise exception 'Use the service editor to remove saved service names without losing the completed-work ledger.'using errcode='22023';end if;
  execute format('delete from %s where %I::text=$1',sp->>'table',sp->>'key')using p_row_key;
  after_data:='{"deleted":true}';
 end if;
 result:=jsonb_build_object('saved',true,'action',p_action,'request_id',p_request_id,'imei',d->>'imei');
 insert into greenloop_private.workflow_stage_audit(request_id,device_id,actor,reason,command,before_data,after_data,response)values(p_request_id,p_device_id,auth.uid(),p_reason,cmd,before_data,after_data,result);
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(p_device_id,null,'workflow_stage_correction',case when p_action='move_back'then 'Returned to Initial QC'else 'Audited workflow entry deletion'end,jsonb_build_object('audit_id',p_request_id,'action',p_action,'kind',p_kind,'next_status',case when p_action='move_back'then 'initial_qc_pending'else null end),auth.uid());
 update public.workflow_notification_signal set revision=revision+1 where id=1;
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();return result;
end;$$;

create or replace function public.get_full_imei_workflow_v2(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.wfs_read(p_identifier);end;$$;
create or replace function public.save_full_imei_workflow_v2(p_device_id uuid,p_snapshot text,p_changes jsonb,p_reason text,p_code text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.wfs_save(p_device_id,p_snapshot,p_changes,p_reason,p_code);end;$$;
create or replace function public.apply_imei_workflow_stage_action_v1(p_device_id uuid,p_snapshot text,p_action text,p_kind text,p_row_key text,p_reason text,p_code text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.wfs_action(p_device_id,p_snapshot,p_action,p_kind,p_row_key,p_reason,p_code,p_request_id);end;$$;
create or replace function public.save_reopened_initial_qc_v1(p_job_id uuid,p_findings jsonb,p_part_requests jsonb,p_supplier_grade text,p_gc_grade text,p_notes text,p_request_id uuid,p_direct_ready boolean default false)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.wfs_qc_resave(p_job_id,p_findings,p_part_requests,p_supplier_grade,p_gc_grade,p_notes,p_request_id,p_direct_ready);end;$$;
do $prefill$declare target text;body text;begin
 select implementation into target from greenloop_private.office_routines where to_regprocedure(identity)='public.get_initial_qc_work_item_v1(text)'::regprocedure;
 if target is null then raise exception 'Reviewed Initial QC reader is missing.';end if;
 body:='begin -- greenloop-office-wrapper-196'||chr(10)||'perform greenloop_private.require_office_network();return greenloop_private.wfs_qc_prefill('||split_part(target,'(',1)||'(p_identifier));end;';
 execute format('create or replace function public.get_initial_qc_work_item_v1(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as %L',body);
end;$prefill$;
do $acl$declare f record;begin
 for f in select oid::regprocedure id from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'wfs_%'loop execute format('revoke all on function %s from public,anon,authenticated',f.id);end loop;
 for f in select oid::regprocedure id from pg_proc where pronamespace='public'::regnamespace and proname in('get_full_imei_workflow_v2','save_full_imei_workflow_v2','apply_imei_workflow_stage_action_v1','save_reopened_initial_qc_v1')loop execute format('revoke all on function %s from public,anon,authenticated',f.id);execute format('grant execute on function %s to authenticated',f.id);end loop;
end;$acl$;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
select x.identity,x.impl,md5(pg_get_functiondef(to_regprocedure(x.impl))),md5(pg_get_functiondef(to_regprocedure(x.identity)))from(values
 ('public.get_full_imei_workflow_v2(text)','greenloop_private.wfs_read(text)'),
 ('public.save_full_imei_workflow_v2(uuid,text,jsonb,text,text)','greenloop_private.wfs_save(uuid,text,jsonb,text,text)'),
 ('public.apply_imei_workflow_stage_action_v1(uuid,text,text,text,text,text,text,uuid)','greenloop_private.wfs_action(uuid,text,text,text,text,text,text,uuid)'),
 ('public.save_reopened_initial_qc_v1(uuid,jsonb,jsonb,text,text,text,uuid,boolean)','greenloop_private.wfs_qc_resave(uuid,jsonb,jsonb,text,text,text,uuid,boolean)'))x(identity,impl)
on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values
 ('get_full_imei_workflow_v2','{"page":"reports","capability":"workflow_correction","read":true}'),('save_full_imei_workflow_v2','{"page":"reports","capability":"workflow_correction"}'),
 ('apply_imei_workflow_stage_action_v1','{"page":"reports","capability":"workflow_correction"}'),('save_reopened_initial_qc_v1','{"page":"initial_qc","capability":"entry"}'),('get_workflow_stage_controls_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
insert into greenloop_private.report_access_dependencies(capability,required_views)values('workflow_delete','"report_imei_correction"'),('workflow_move_back','"report_imei_correction"')on conflict(capability)do update set required_views=excluded.required_views;
update greenloop_private.report_access_config_seal set dependencies_hash=(select md5(jsonb_agg(to_jsonb(d)order by capability)::text)from greenloop_private.report_access_dependencies d),sections_hash=(select md5(jsonb_agg(to_jsonb(s)order by report_key)::text)from greenloop_private.report_access_sections s)where singleton;
-- Re-seal the single reviewed QC wrapper. Its original implementation stays intact.
do $seal$declare t record;id regprocedure:='public.get_initial_qc_work_item_v1(text)'::regprocedure;begin
 update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(id))where to_regprocedure(identity)=id;
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
 end loop;
end;$seal$;
create table if not exists greenloop_private.workflow_stage_installation(identity text primary key,hash text not null);
alter table greenloop_private.workflow_stage_installation enable row level security;revoke all on greenloop_private.workflow_stage_installation from public,anon,authenticated;
insert into greenloop_private.workflow_stage_installation select oid::regprocedure::text,md5(pg_get_functiondef(oid))from pg_proc where(pronamespace='greenloop_private'::regnamespace and proname like 'wfs_%')or(pronamespace='public'::regnamespace and proname in('get_full_imei_workflow_v2','save_full_imei_workflow_v2','apply_imei_workflow_stage_action_v1','save_reopened_initial_qc_v1','get_initial_qc_work_item_v1'))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_workflow_stage_controls_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_lab_overdue_card_version()='20261105-lab-overdue-card-1'
 and(select count(*)=11 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.workflow_stage_installation)
 and not exists(select 1 from greenloop_private.workflow_stage_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_table_privilege('authenticated','greenloop_private.workflow_stage_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261105-workflow-stage-controls-1'end;
$$;
revoke all on function public.get_workflow_stage_controls_version()from public;grant execute on function public.get_workflow_stage_controls_version()to anon,authenticated;
do $$begin if public.get_workflow_stage_controls_version()is distinct from '20261105-workflow-stage-controls-1'then raise exception 'Workflow stage controls verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_workflow_stage_controls_version()as installed_workflow_stage_controls_version;
