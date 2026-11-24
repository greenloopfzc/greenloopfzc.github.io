-- Read the recorded operations across departments without adding write-side work.
begin;
set local search_path=pg_catalog,public;
set local lock_timeout='5s';

do $permissions$
begin
  if not exists (
    select 1 from greenloop_private.page_capability_catalog
    where page_key='reports' and capabilities @> '[{"key":"report_activity_log"}]'
  ) then
    insert into greenloop_private.user_page_capabilities(user_id,capabilities)
    select id,greenloop_private.user_capabilities(id) from public.user_profiles
    on conflict(user_id) do nothing;
    update greenloop_private.page_capability_catalog
    set capabilities=capabilities||'[{"key":"report_activity_log","label":"View Activity Log","write":false}]'::jsonb
    where page_key='reports';
    update greenloop_private.user_page_capabilities a
    set capabilities=jsonb_set(a.capabilities,'{reports}',(a.capabilities->'reports')||'["report_activity_log"]'::jsonb)
    where a.capabilities->'reports'?'view' and exists (
      select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
      where ur.user_id=a.user_id and r.role_key::text in ('owner','super_admin')
    );
  end if;
end;
$permissions$;

insert into greenloop_private.report_access_sections(report_key,config)
values ('activity_log','{"label":"Activity Log","view":"report_activity_log","actions":[]}')
on conflict(report_key) do nothing;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
 ('get_activity_log_v1','{"page":"reports","capability":"report_activity_log","read":true}'),
 ('get_activity_log_version','{"read":true}')
on conflict(rpc_name) do nothing;

update greenloop_private.page_capability_installation set hash=case identity
 when 'catalog' then (select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
 when 'rules' then (select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
 end where identity in ('catalog','rules');
update greenloop_private.report_access_config_seal set
 sections_hash=(select md5(jsonb_agg(to_jsonb(s) order by report_key)::text) from greenloop_private.report_access_sections s),
 dependencies_hash=(select md5(jsonb_agg(to_jsonb(d) order by capability)::text) from greenloop_private.report_access_dependencies d)
where singleton;

create index if not exists activity_log_device_event_time_idx on public.device_events(created_at,id);

create or replace function greenloop_private.activity_log_rows(
 p_from timestamptz,p_to timestamptz,p_names boolean
) returns table(
 record_key text,occurred_at timestamptz,actor_id uuid,actor_name text,department text,action text,
 device_id uuid,job_id uuid,batch_id uuid,record_imei text,reference text,details jsonb
)
language sql stable security definer set search_path=pg_catalog,public as $rows$
 with records(record_key,occurred_at,actor_id,actor_name,department,action,device_id,job_id,batch_id,record_imei,reference,details) as (
  select 'receipt:'||b.id,b.created_at,b.created_by,null::text,'Stock Received','Stock receipt recorded',
    null::uuid,null::uuid,b.id,null::text,null::text,
    jsonb_build_object('Invoice',b.invoice_number,'Quantity',b.planned_quantity)
  from public.receiving_batches b where b.created_at>=p_from and b.created_at<p_to
  union all
  select 'entry:'||j.id,j.created_at,coalesce(j.created_by,j.received_by),null,'IMEI Entry','IMEI entered',
    j.device_id,j.id,j.receiving_batch_id,null,null,jsonb_build_object('Job type',replace(j.job_type::text,'_',' '))
  from public.jobs j where j.created_at>=p_from and j.created_at<p_to
  union all
  select 'initial:'||q.id,q.inspected_at,q.inspected_by,null,'Initial QC','Initial QC saved',q.device_id,q.job_id,null,null,null,
    jsonb_build_object('Work required',q.work_required,'Condition',q.overall_condition,'Cosmetic condition',q.cosmetic_condition,
      'Notes',case when p_names then left(q.notes,500) end)
  from public.initial_qc_inspections q where q.inspected_at>=p_from and q.inspected_at<p_to
  union all
  select 'issuance:'||s.job_id,s.issued_at,s.issued_by,null,'Issuance','Phone issued',
    s.device_id,s.job_id,null,null,null,jsonb_build_object('Destination',replace(s.destination,'_',' '),'Technician',t.full_name)
  from greenloop_private.qc_saved_issuance s left join public.technician_roster t on t.id=s.technician_id
  where s.issued_at>=p_from and s.issued_at<p_to
  union all
  select 'lab-start:'||w.id,w.started_at,null,null,'Lab & Glass','Lab work started',w.device_id,w.job_id,null,null,null,
    jsonb_build_object('Technician',(select p.full_name from public.user_profiles p where p.id=w.technician_id),'Rework cycle',w.rework_cycle)
  from public.laboratory_work_records w where w.started_at>=p_from and w.started_at<p_to
    and not exists(select 1 from public.device_events e where e.job_id=w.job_id and e.device_id=w.device_id and e.created_at=w.started_at and e.event_type='laboratory_work_started')
  union all
  select 'lab-complete:'||w.id,w.completed_at,null,null,'Lab & Glass','Lab work completed',w.device_id,w.job_id,null,null,null,
    jsonb_build_object('Technician',(select p.full_name from public.user_profiles p where p.id=w.technician_id),'Rework cycle',w.rework_cycle)
  from public.laboratory_work_records w where w.completed_at>=p_from and w.completed_at<p_to
    and not exists(select 1 from public.device_events e where e.job_id=w.job_id and e.device_id=w.device_id and e.created_at=w.completed_at
      and e.event_type in ('laboratory_completed','laboratory_work_completed'))
  union all
  select 'glass-start:'||w.id,w.started_at,null,null,'Lab & Glass','Glass work started',w.device_id,w.job_id,null,null,null,
    jsonb_build_object('Technician',(select p.full_name from public.user_profiles p where p.id=w.assigned_to))
  from public.glass_work_records w where w.started_at>=p_from and w.started_at<p_to
    and not exists(select 1 from public.device_events e where e.job_id=w.job_id and e.device_id=w.device_id and e.created_at=w.started_at and e.event_type='glass_work_started')
  union all
  select 'glass-complete:'||w.id,w.completed_at,null,null,'Lab & Glass','Glass work completed',w.device_id,w.job_id,null,null,null,
    jsonb_build_object('Technician',(select p.full_name from public.user_profiles p where p.id=w.assigned_to))
  from public.glass_work_records w where w.completed_at>=p_from and w.completed_at<p_to
    and not exists(select 1 from public.device_events e where e.job_id=w.job_id and e.device_id=w.device_id and e.created_at=w.completed_at and e.event_type='glass_work_completed')
  union all
  select 'part-request:'||q.id,q.requested_at,q.requested_by,null,'Parts','Part requested',
    q.device_id,q.job_id,null,null,null,jsonb_build_object('Part',q.part_name,'Quantity',q.quantity_requested,'Technician',q.requested_for_technician)
  from public.job_part_requests q where q.requested_at>=p_from and q.requested_at<p_to
  union all
  select 'part-issue:'||i.id,i.issued_at,i.issued_by,null,'Parts','Part issued',
    q.device_id,q.job_id,null,null,null,jsonb_build_object('Part',q.part_name,'Quantity',i.quantity_issued)
  from public.part_issue_transactions i join public.job_part_requests q on q.id=i.part_request_id
  where i.issued_at>=p_from and i.issued_at<p_to
  union all
  select 'part-installed:'||i.id,i.installed_at,i.installed_by,null,'Parts','Part installed',
    i.device_id,i.job_id,null,null,null,jsonb_build_object('Part',q.part_name,'Quantity',i.quantity_installed)
  from public.part_installations i left join public.job_part_requests q on q.id=i.part_request_id
  where i.installed_at>=p_from and i.installed_at<p_to
  union all
  select 'parts-manual:'||i.id,i.installed_at,i.installed_by,null,'Lab & Glass','Manual part installation recorded',
    i.device_id,i.job_id,null,null,null,jsonb_build_object('Part',i.part_name,'Quantity',i.quantity)
  from public.lab_manual_part_installations i where i.installed_at>=p_from and i.installed_at<p_to
  union all
  select 'parts-audit:'||a.id,a.created_at,a.actor,null,'Parts',initcap(replace(a.action,'_',' ')),
    o.device_id,o.job_id,null,null,null,jsonb_build_object('Service',a.details->>'service','Status',a.details->>'status',
      'Part',coalesce(a.details->>'part_name',a.details->>'part'),'Quantity',a.details->>'quantity',
      'Approved',a.details->'approved','Classification',a.details->>'classification')
  from greenloop_private.parts_flow_audit a left join greenloop_private.parts_flow_orders o on o.id=a.order_id
  where a.created_at>=p_from and a.created_at<p_to and a.action<>'existing_issued_list_preserved'
    and not (a.action='part_issued' and exists (
      select 1 from public.part_issue_transactions i
      where i.id=case when (a.details->>'issue_id')~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
        then (a.details->>'issue_id')::uuid end
        and i.issued_at=a.created_at and i.issued_by is not distinct from a.actor
    ))
  union all
  select 'final:'||q.id,q.inspected_at,q.inspected_by,null,'Final QC',
    case when q.routed_to_frame then 'Final QC sent phone to B-DEPT' when q.result='pass' then 'Final QC passed' else 'Final QC failed' end,
    q.device_id,q.job_id,null,null,null,jsonb_build_object('Attempt',q.attempt_number,
      'Final grade',case when not coalesce(q.routed_to_frame,false) then q.final_grade end,'Final BH',q.final_battery_health,
      'Failure department',q.failure_department,'Reason',case when p_names then left(q.failure_reason,500) end)
  from public.final_qc_inspections q where q.inspected_at>=p_from and q.inspected_at<p_to
    and not(coalesce(q.routed_to_frame,false) and coalesce(q.notes,'') like 'Initial QC direct route to Frame%')
  union all
  select 'frame:'||q.id,q.reviewed_at,q.reviewed_by,null,'B-DEPT',
    case when q.result='pass' then case when e.event_type='frame_passed_ready_stock' then 'B-DEPT passed to Ready Stock'
      when e.event_type='b_dept_passed_final_qc' then 'B-DEPT passed to Final QC' else 'B-DEPT passed' end else 'B-DEPT failed' end,
    q.device_id,q.job_id,null,null,null,jsonb_build_object('Result',q.result,'Final BH',q.final_battery_health,
      'Final grade',e.event_data->>'final_grade','Notes',case when p_names then left(q.notes,500) end)
  from public.frame_department_results q
  left join lateral (
    select e.event_type,e.event_data from public.device_events e
    where e.job_id=q.job_id and e.device_id=q.device_id and e.created_at=q.reviewed_at
      and e.event_type in ('frame_passed_ready_stock','b_dept_passed_final_qc') order by e.id limit 1
  ) e on q.result='pass'
  where q.reviewed_at>=p_from and q.reviewed_at<p_to
  union all
  select 'stock-movement:'||h.id,h.moved_at,h.moved_by,null,
    case when dst.location_code in ('PRODUCTION','READY','READY-STOCK') then 'Ready Stock'
      when dst.location_code='FRAME' then 'B-DEPT' when dst.location_code='FINAL-QC' then 'Final QC'
      when dst.location_code in ('LAB','GLASS') then 'Lab & Glass' when dst.location_code='PARTS' then 'Parts'
      when dst.location_code='INITIAL-QC' then 'Initial QC' else 'Transfers' end,
    case when dst.location_code in ('PRODUCTION','READY','READY-STOCK') then 'Moved to Ready Stock' else 'Location changed' end,
    h.device_id,h.job_id,null,null,null,jsonb_build_object('From',src.location_code,'To',dst.location_code,
      'Reason',case when p_names then left(h.movement_reason,500) end)
  from public.device_location_history h left join public.locations src on src.id=h.from_location_id
  join public.locations dst on dst.id=h.to_location_id
  where h.moved_at>=p_from and h.moved_at<p_to and h.from_location_id is distinct from h.to_location_id
    and not(src.location_code is not distinct from 'FRAME' and dst.location_code in ('PRODUCTION','READY','READY-STOCK') and exists(
      select 1 from public.frame_department_results r where r.device_id=h.device_id and r.job_id=h.job_id
        and r.reviewed_at=h.moved_at and r.result='pass' and r.reviewed_by is not distinct from h.moved_by
    ))
  union all
  select 'box-item:'||i.id,i.scanned_at,i.scanned_by,null,'Box Entry','Phone scanned into box',
    i.device_id,i.job_id,null,i.imei,b.box_number,jsonb_build_object('Box position',i.serial_no,'Final grade',i.final_grade)
  from public.export_box_items i join public.export_boxes b on b.id=i.box_id where i.scanned_at>=p_from and i.scanned_at<p_to
  union all
  select 'box-audit:'||a.id,a.occurred_at,a.actor,null,
    case when a.action in ('verified_exported','recheck_requested') then 'Accounts' else 'Box Entry' end,
    case a.action when 'verified_exported' then 'Box verified and exported'
      when 'saved_to_accounts' then 'Box sent to Accounts'
      when 'recheck_requested' then 'Box returned for recheck' else 'Box '||replace(a.action,'_',' ') end,
    null,null,null,a.details->>'imei',a.box_number,jsonb_build_object('Reason',case when p_names then left(a.details->>'reason',500) end)
  from greenloop_private.box_workflow_audit a where a.occurred_at>=p_from and a.occurred_at<p_to
  union all
  select 'dispatch:'||r.id,r.dispatched_at,r.dispatched_by,null,'Export','Stock dispatched',
    r.device_id,r.job_id,null,null,r.stock_out_number,jsonb_build_object('Dispatch type',replace(r.stock_out_type::text,'_',' '),
      'Destination',case when p_names then r.destination end,'Shipment reference',r.shipment_reference)
  from public.stock_out_records r where r.dispatched_at>=p_from and r.dispatched_at<p_to
  union all
  select 'return:'||e.id,e.occurred_at,e.actor_id,e.actor_name,'Return / Replacement',
    case e.action when 'requested' then 'Supplier return requested' when 'approve' then 'Supplier return approved'
      when 'handover' then 'Handed over to supplier' when 'settlement' then 'Supplier return settlement recorded'
      else 'Supplier return '||replace(e.action,'_',' ') end,
    r.device_id,r.job_id,r.batch_id,r.imei_1,r.return_number,jsonb_build_object('Status',replace(e.to_status,'_',' '),
      'Reason',case when p_names then left(r.reason,500) end,'Notes',case when p_names then left(e.notes,500) end)
  from public.supplier_return_events e join public.supplier_returns r on r.id=e.return_id
  where e.occurred_at>=p_from and e.occurred_at<p_to
  union all
  select 'chaman:'||e.id,e.occurred_at,e.actor,null,'Chaman Shop',initcap(replace(e.action,'_',' ')),
    e.device_id,e.job_id,null,l.imei,d.reference,jsonb_build_object('Reason',case when p_names then left(e.reason,500) end)
  from greenloop_private.chaman_events e join greenloop_private.chaman_lines l on l.id=e.line_id
  left join greenloop_private.chaman_documents d on d.id=e.document_id where e.occurred_at>=p_from and e.occurred_at<p_to
  union all
  select 'change:'||h.id,h.changed_at,h.changed_by,null,'Corrections','IMEI details corrected',
    h.device_id,h.job_id,null,coalesce(h.imei_after,h.imei_before),null,
    jsonb_build_object('IMEI before',nullif(h.imei_before,h.imei_after),'IMEI after',nullif(h.imei_after,h.imei_before),
      'Changed fields',(select string_agg(replace(k,'_',' '),', ' order by k)
        from jsonb_object_keys(case when jsonb_typeof(h.changed_fields)='object' then h.changed_fields else '{}'::jsonb end) k),
      'Reason',case when p_names then left(h.change_reason,500) end)
  from public.data_change_history h where h.changed_at>=p_from and h.changed_at<p_to
    and not(h.changed_fields?'full_workflow' and exists(select 1 from greenloop_private.workflow_correction_audit w
      where w.device_id=h.device_id and position(w.id::text in(h.changed_fields->'full_workflow'->>'new'))>0))
  union all
  select 'workflow-correction:'||a.id,a.changed_at,a.actor,null,'Corrections','Workflow details corrected',
    a.device_id,null,null,null,null,jsonb_build_object('Reason',case when p_names then left(a.reason,500) end)
  from greenloop_private.workflow_correction_audit a where a.changed_at>=p_from and a.changed_at<p_to
  union all
  select 'stage-change:'||a.request_id,a.at,a.actor,null,'Corrections','Workflow stage changed',
    a.device_id,a.job_id,null,null,null,jsonb_build_object('From',replace(a.from_stage,'_',' '),'To',replace(a.to_stage,'_',' '),
      'Reason',case when p_names then left(a.reason,500) end)
  from greenloop_private.stage_change_audit a where a.at>=p_from and a.at<p_to
  union all
  select 'receipt-qty:'||a.request_id,a.created_at,a.actor,null,'Corrections','Receipt quantity corrected',
    null,null,a.batch_id,null,null,jsonb_build_object('Previous quantity',a.old_quantity,'New quantity',a.new_quantity,
      'Reason',case when p_names then left(a.reason,500) end)
  from greenloop_private.receipt_quantity_audit a where a.created_at>=p_from and a.created_at<p_to
  union all
  select 'receipt-supplier:'||a.request_id,a.created_at,a.actor,null,'Corrections','Receipt supplier corrected',
    null,null,a.root_batch_id,null,null,jsonb_build_object('Reason',case when p_names then left(a.reason,500) end)
  from greenloop_private.receipt_supplier_audit a where a.created_at>=p_from and a.created_at<p_to
  union all
  select 'deletion:'||a.id,a.deleted_at,a.deleted_by,null,'Corrections','Record deleted',
    null,null,null,null,null,jsonb_build_object('Record type',replace(a.record_type,'_',' '),
      'Reason',case when p_names then left(a.deletion_reason,500) end)
  from public.deletion_history a where a.deleted_at>=p_from and a.deleted_at<p_to
  union all
  select 'damage-created:'||a.id,a.created_at,a.reported_by_user_id,a.reported_by,'Damage Reports','Damage reported',
    null,null,null,case when a.identifier~'^[0-9]{15}$' then a.identifier end,null,
    jsonb_build_object('Model',a.model,'Part',a.part_name,'Damage',a.damage,
      'Reason',case when p_names then left(a.reason,500) end)
  from public.manual_damage_reports a where a.created_at>=p_from and a.created_at<p_to
  union all
  select 'damage-change:'||a.id,a.created_at,a.actor_user_id,a.actor_name,'Damage Reports','Damage report '||replace(a.action,'_',' '),
    null,null,null,null,null,jsonb_build_object('Records affected',a.affected_count,
      'Reason',case when p_names then left(a.reason,500) end)
  from greenloop_private.manual_damage_operations a where a.created_at>=p_from and a.created_at<p_to
 ), structured as materialized (
   select * from records
 ), events as (
   select 'event:'||e.id record_key,e.created_at occurred_at,e.actor_id,null::text actor_name,
    case
      when e.event_type in ('frame_passed_ready_stock','frame_failed') or left(e.event_type,7)='b_dept_' then 'B-DEPT'
      when left(e.event_type,9)='final_qc_' then 'Final QC'
      when e.event_type in ('initial_qc_issued','initial_qc_issuance_edited') then 'Issuance'
      when left(e.event_type,11)='initial_qc_' then 'Initial QC'
      when left(e.event_type,16)='supplier_return_' or left(e.event_type,12)='replacement_' then 'Return / Replacement'
      when left(e.event_type,9)='parts_flow' or left(e.event_type,5)='part_' or left(e.event_type,6)='parts_' then 'Parts'
      when left(e.event_type,4)='lab_' or left(e.event_type,11)='laboratory_' or left(e.event_type,6)='glass_' then 'Lab & Glass'
      when left(e.event_type,12)='ready_stock_' then 'Ready Stock'
      when left(e.event_type,13)='box_accounts_' then 'Accounts'
      when left(e.event_type,4)='box_' or left(e.event_type,11)='export_box_' then 'Box Entry'
      when left(e.event_type,10)='stock_out_' then 'Export'
      when left(e.event_type,7)='chaman_' then 'Chaman Shop'
      when e.event_type like '%corrected%' or e.event_type like '%deleted%' then 'Corrections'
      when e.event_type like '%imei%received%' then 'IMEI Entry'
      else 'Workflow'
    end department,
    coalesce(case when p_names then nullif(btrim(e.event_title),'') end,initcap(replace(e.event_type,'_',' '))) action,
    e.device_id,e.job_id,null::uuid batch_id,null::text record_imei,e.event_data->>'box_number' reference,
    jsonb_build_object('Technician',coalesce(e.event_data->>'technician_name',e.event_data->>'assigned_technician_name',e.event_data->>'technician'),
      'Destination',coalesce(e.event_data->>'next_department',e.event_data->>'destination',e.event_data->>'next_status'),
      'Final grade',e.event_data->>'final_grade','Part',e.event_data->>'part_name','Quantity',e.event_data->>'quantity',
      'Service',e.event_data->>'service','Reason',case when p_names then left(e.event_data->>'reason',500) end) details
   from public.device_events e
   where e.created_at>=p_from and e.created_at<p_to
     and not exists (
       select 1 from structured a
       where a.device_id=e.device_id and a.job_id is not distinct from e.job_id and a.occurred_at=e.created_at
       and split_part(a.record_key,':',1)=any(case e.event_type
         when 'stock_batch_imei_received' then array['entry']
         when 'initial_qc_saved' then array['initial']
         when 'initial_qc_completed' then array['initial']
         when 'initial_qc_issued' then array['issuance']
         when 'parts_flow_issued' then array['part-issue']
         when 'part_installed' then array['part-installed']
         when 'laboratory_manual_parts_saved' then array['parts-manual']
         when 'final_qc_passed' then array['final']
         when 'final_qc_failed' then array['final']
         when 'frame_passed_ready_stock' then array['frame']
         when 'frame_failed' then array['frame']
         when 'b_dept_passed_final_qc' then array['frame']
         when 'export_box_scanned' then array['box-item']
         when 'stock_out_completed' then array['dispatch']
         else case when left(e.event_type,16)='supplier_return_' then array['return']
           when left(e.event_type,7)='chaman_' then array['chaman'] else array[]::text[] end
       end)
     )
 )
 select * from structured union all select * from events;
$rows$;
revoke all on function greenloop_private.activity_log_rows(timestamptz,timestamptz,boolean) from public,anon,authenticated;

create or replace function public.get_activity_log_v1(
 p_from timestamp,p_to timestamp,p_user text default '',p_department text default '',
 p_action text default '',p_imei text default '',p_offset integer default 0,
 p_as_of timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $read$
declare
 lo timestamptz;
 hi timestamptz;
 as_of timestamptz:=coalesce(p_as_of,statement_timestamp());
 show_names boolean;
 payload jsonb;
begin
 perform greenloop_private.pf_cap('reports','view');
 perform greenloop_private.pf_cap('reports','report_activity_log');
 if p_from is null or p_to is null or p_from>p_to or not isfinite(p_from) or not isfinite(p_to)
    or p_from<timestamp '1900-01-01' or p_to>timestamp '9999-12-31'
    or date_trunc('minute',p_from)<>p_from or date_trunc('minute',p_to)<>p_to
    or not isfinite(as_of) or as_of>statement_timestamp() then
  raise exception 'Choose a valid From and To date and time (UAE).' using errcode='22023';
 end if;
 if p_offset is null or p_offset<0 or p_offset%50<>0 or length(coalesce(p_user,''))>100
    or length(coalesce(p_action,''))>100 or length(coalesce(p_department,''))>40
    or coalesce(p_imei,'') !~ '^(|[0-9]{15})$' then
  raise exception 'Choose valid activity filters and a 50-row page.' using errcode='22023';
 end if;
 lo:=p_from at time zone 'Asia/Dubai';
 hi:=least((p_to+interval '1 minute') at time zone 'Asia/Dubai',as_of);
 show_names:=coalesce(public.get_my_partner_name_access(),false);
 with source as materialized (
   select a.record_key,a.occurred_at,a.department,a.action,a.details,
     coalesce(nullif(a.actor_name,''),nullif(u.full_name,''),nullif(u.login_username,''),'Not recorded') actor,
     nullif(u.login_username,'') login_id,
     coalesce(nullif(a.record_imei,''),d.imei_1) imei,
     d.imei_2,d.imei_1 current_imei,d.model,
     j.job_number,coalesce(nullif(a.reference,''),b.batch_number) reference,b.planned_quantity,
     a.details->>'IMEI before' imei_before
   from greenloop_private.activity_log_rows(lo,hi,show_names) a
   left join public.user_profiles u on u.id=a.actor_id left join public.devices d on d.id=a.device_id
   left join public.jobs j on j.id=a.job_id
   left join public.receiving_batches b on b.id=coalesce(a.batch_id,j.receiving_batch_id)
 ), matching as materialized (
   select s.* from source s
   where (coalesce(p_department,'')='' or s.department=p_department)
     and (coalesce(btrim(p_user),'')='' or strpos(lower(s.actor),lower(btrim(p_user)))>0
       or strpos(lower(coalesce(s.login_id,'')),lower(btrim(p_user)))>0)
     and (coalesce(btrim(p_action),'')='' or strpos(lower(s.action),lower(btrim(p_action)))>0)
     and (coalesce(p_imei,'')='' or p_imei in(s.imei,s.current_imei,s.imei_2,s.imei_before))
 ), page as (
   select * from matching order by occurred_at desc,record_key desc offset p_offset limit 50
 )
 select jsonb_build_object('version','20261124-activity-log-1','timezone','Asia/Dubai','as_of',as_of,
   'offset',p_offset,'limit',50,'total',(select count(*) from matching),
   'rows',coalesce((select jsonb_agg(
      (to_jsonb(p)-'imei_before'-'imei_2')||jsonb_build_object('details',jsonb_strip_nulls(p.details))
      order by p.occurred_at desc,p.record_key desc) from page p),'[]'))
 into payload;
 return payload;
end;
$read$;
revoke all on function public.get_activity_log_v1(timestamp,timestamp,text,text,text,text,integer,timestamptz)
 from public,anon,authenticated;
grant execute on function public.get_activity_log_v1(timestamp,timestamp,text,text,text,text,integer,timestamptz) to authenticated;

create table if not exists greenloop_private.activity_log_installation(identity text primary key,hash text not null);
alter table greenloop_private.activity_log_installation enable row level security;
revoke all on greenloop_private.activity_log_installation from public,anon,authenticated;

create or replace function public.get_activity_log_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when
   (select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.activity_log_installation)
   and not has_function_privilege('anon','public.get_activity_log_v1(timestamp,timestamp,text,text,text,text,integer,timestamptz)','execute')
   and has_function_privilege('authenticated','public.get_activity_log_v1(timestamp,timestamp,text,text,text,text,integer,timestamptz)','execute')
   and not has_function_privilege('authenticated','greenloop_private.activity_log_rows(timestamptz,timestamptz,boolean)','execute')
   and exists(select 1 from greenloop_private.report_access_sections where report_key='activity_log' and config->>'view'='report_activity_log')
   and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_activity_log_v1'
     and rule='{"page":"reports","capability":"report_activity_log","read":true}')
   and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'
     and capabilities @> '[{"key":"report_activity_log","write":false}]')
 then '20261124-activity-log-1' end;
$version$;
revoke all on function public.get_activity_log_version() from public;
grant execute on function public.get_activity_log_version() to anon,authenticated;
insert into greenloop_private.activity_log_installation
select s,md5(pg_get_functiondef(to_regprocedure(s))) from unnest(array[
 'greenloop_private.activity_log_rows(timestamptz,timestamptz,boolean)',
 'public.get_activity_log_v1(timestamp,timestamp,text,text,text,text,integer,timestamptz)'
]) s on conflict(identity) do update set hash=excluded.hash;

do $verify$
begin
 if public.get_activity_log_version() is distinct from '20261124-activity-log-1'
 then raise exception 'Activity Log could not be verified.'; end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_activity_log_version() as installed_activity_log_version;
