-- Stock Journey begins at saved IMEI Entry and stays visible throughout processing.
-- Additive read-only reporting; existing workflow functions and records are retained.
begin;
create schema if not exists greenloop_private;
do $prerequisite$ begin
 if public.get_greenloop_imei_history_version() is distinct from '20261002-imei-history-1' then
  raise exception 'Install the verified IMEI history update first.' using errcode='55000';
 end if;
end; $prerequisite$;
create or replace function public.get_stock_journey_v1(p_date_from date default null,p_date_to date default null,p_query text default '',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $list$
declare v_names boolean;v_result jsonb;v_query text:=lower(btrim(coalesce(p_query,'')));begin
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not coalesce(
 (select p.access_level in ('view','edit') from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key='ready_stock_journey'),
 public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then
 raise exception 'Stock Journey permission is required.' using errcode='42501'; end if;
 if (p_date_from is null)<>(p_date_to is null) or p_date_from>p_date_to then raise exception 'Select a valid From date and To date, or clear both dates.' using errcode='22023'; end if;
 if length(v_query)>120 or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid journey search or page.' using errcode='22023'; end if;
 v_names:=coalesce(public.get_my_partner_name_access(),false);
 with matching as materialized (
  select d.id device_id,j.id job_id,coalesce(first_entry.entered_at,d.created_at) entered_at
  from public.devices d
  left join lateral (select jj.id,jj.receiving_batch_id,jj.supplier_id from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by jj.received_at desc,jj.created_at desc,jj.id desc limit 1) j on true
  left join lateral (select min(jj.created_at) entered_at from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null) first_entry on true
  left join public.receiving_batches b on b.id=j.receiving_batch_id
  left join public.suppliers s on s.id=j.supplier_id
  where d.deleted_at is null and (p_date_from is null or (coalesce(first_entry.entered_at,d.created_at) at time zone 'Asia/Dubai')::date between p_date_from and p_date_to)
  and (v_query='' or position(v_query in lower(concat_ws(' ',d.imei_1,d.imei_2,d.device_number,d.serial_number,d.brand,d.model,d.storage_gb::text,d.color,b.invoice_number,b.batch_number,s.supplier_code,case when v_names then s.company_name end)))>0)
 ),selected as (select * from matching order by entered_at desc,device_id offset p_offset limit p_limit),
 journey(imei,device_details,date_received,date_completed,stock_channel,invoice_number,supplier_company,quantity_received,supplier_code,battery_health,supplier_grade,company_initial_grade,company_final_grade,parts_issued,parts_cost,service_done,technician_name,box_number,export_date,customer_name,device_id,device_number,date_entered,current_status,current_stage) as (
  select device.imei_1::text,
    concat_ws(' - ', nullif(btrim(device.model), ''), case when device.storage_gb is null then null else device.storage_gb::text || ' GB' end, nullif(btrim(device.color), ''), nullif(btrim(device.specification_region), '')),
    coalesce(batch.received_at,job.received_at), final_pass.latest_passed_at,
    coalesce(nullif(btrim(channel.channel_name), ''), nullif(btrim(job.receiving_source), ''), '-'),
    coalesce(nullif(btrim(batch.invoice_number), ''), '-'), coalesce(nullif(btrim((case when v_names then supplier.company_name end)), ''), '-'), batch.planned_quantity,
    coalesce(nullif(btrim(supplier.supplier_code), ''), '-'),
    concat_ws(' / ', case when device.battery_health is null then null else 'Initial ' || device.battery_health::text || '%' end, case when final_pass.final_battery_health is null then null else 'Final ' || final_pass.final_battery_health::text || '%' end),
    coalesce(nullif(btrim(job.supplier_grade), ''), '-'), coalesce(nullif(btrim(device.gc_grade), ''), '-'), coalesce(nullif(btrim(final_pass.final_grade), ''), '-'),
    coalesce(nullif(concat_ws(', ', nullif(btrim(automatic_parts.parts_used), ''), nullif(btrim(manual_parts.parts_issued), '')), ''), 'No parts issued'),
    coalesce(automatic_parts.parts_cost, 0)::numeric, coalesce(services.service_done, 'No service recorded'), coalesce(technicians.technician_name, 'Not recorded'),
    coalesce(export_info.box_number, '-'), export_info.export_date,
    coalesce(nullif(btrim((case when v_names then customer.company_name end)), ''), nullif(btrim((case when v_names then owner_customer.company_name end)), ''), '-'),
    device.id,device.device_number,selected.entered_at,coalesce(job.current_status::text,device.current_status::text),
    coalesce(case active_department.department when 'laboratory' then 'Lab & Glass — Laboratory' when 'glass' then 'Lab & Glass — Glass' when 'parts' then 'Parts' when 'frame' then 'Frame Department' when 'final_qc' then 'Final QC (QC 2)' end,case coalesce(job.current_status::text,device.current_status::text)
  when 'received' then 'IMEI Entry — saved'
  when 'initial_qc_pending' then 'Initial QC (QC 1)'
  when 'initial_qc_completed' then 'Initial QC (QC 1) — completed'
  when 'work_required' then 'Work required — department not recorded'
  when 'no_work_required' then 'Initial QC (QC 1) — no work required'
  when 'parts_pending' then 'Parts'
  when 'laboratory_pending' then 'Lab & Glass — Laboratory'
  when 'laboratory_in_progress' then 'Lab & Glass — Laboratory'
  when 'glass_pending' then 'Lab & Glass — Glass'
  when 'glass_in_progress' then 'Lab & Glass — Glass'
  when 'frame_pending' then 'Frame Department'
  when 'frame_in_progress' then 'Frame Department'
  when 'final_qc_pending' then 'Final QC (QC 2)'
  when 'qc_failed' then 'Final QC (QC 2) — failed'
  when 'rework' then 'Rework — department not recorded'
  when 'qc_passed' then 'Ready Stock'
  when 'production_pending' then 'Ready Stock'
  when 'production_completed' then 'Ready Stock'
  when 'ready_for_packing' then 'Ready Stock'
  when 'ready_for_shipment' then 'Ready Stock'
  when 'shipped' then 'Export / Shipped'
  when 'ready_for_customer_return' then 'Ready for customer return'
  when 'returned_to_customer' then 'Returned to customer'
  when 'shop_stock' then 'Shop stock'
  when 'rma_received' then 'RMA — received'
  when 'rma_qc_pending' then 'RMA — QC'
  when 'rma_work_pending' then 'RMA — work pending'
  when 'rma_rework' then 'RMA — rework'
  when 'rma_qc_passed' then 'RMA — QC passed'
  when 'rma_ready_return' then 'RMA — ready for return'
  when 'rma_ready_export' then 'RMA — ready for export'
  when 'rma_completed' then 'RMA — completed'
  when 'scrap' then 'Scrap'
  when 'supplier_return_requested' then 'Stock Return — requested'
  when 'return_pending' then 'Stock Return — pending'
  when 'returned_to_supplier' then 'Returned to supplier'
  else null
 end,initcap(replace(coalesce(job.current_status::text,device.current_status::text),'_',' ')))
  from selected
  join public.devices as device on device.id=selected.device_id
  left join public.jobs as job on job.id=selected.job_id
  left join public.suppliers as supplier on supplier.id = job.supplier_id
  left join public.receiving_batches as batch on batch.id = job.receiving_batch_id
  left join public.stock_channels as channel on channel.id = batch.stock_channel_id
  left join public.customers as customer on customer.id = job.customer_id
  left join public.customers as owner_customer on owner_customer.id = device.current_owner_customer_id
  left join lateral (select inspection.inspected_at as latest_passed_at, inspection.final_grade, inspection.final_battery_health from public.final_qc_inspections as inspection where inspection.job_id = job.id and inspection.result = 'pass' order by inspection.inspected_at desc limit 1) as final_pass on true
  left join lateral public.get_device_consumed_parts_cost(job.id) as automatic_parts on true
  left join lateral (select string_agg(item.part_name || ' x' || item.quantity::text || ' (Manual Lab)', ', ' order by lower(item.part_name), item.installed_at) as parts_issued from public.lab_manual_part_installations as item where item.job_id = job.id) as manual_parts on true
  left join lateral (select string_agg(distinct review.service_name, ', ' order by review.service_name) as service_done from public.lab_service_reviews as review where review.job_id = job.id and review.is_required) as services on true
  left join lateral (select string_agg(distinct worker.full_name, ', ' order by worker.full_name) as technician_name from (select nullif(btrim(step.assigned_technician_name), '') as full_name from public.job_work_order_steps as step join public.job_work_orders as work_order on work_order.id = step.work_order_id where work_order.job_id = job.id and step.department in ('laboratory', 'glass') union all select nullif(btrim(profile.full_name), '') from public.lab_manual_part_installations as item left join public.user_profiles as profile on profile.id = item.installed_by where item.job_id = job.id union all select nullif(btrim(profile.full_name), '') from public.lab_service_reviews as review left join public.user_profiles as profile on profile.id = review.reviewed_by where review.job_id = job.id and review.is_required) as worker where worker.full_name is not null) as technicians on true
  left join lateral (select box.box_number, item.scanned_at as export_date from public.export_box_items as item join public.export_boxes as box on box.id = item.box_id where item.job_id = job.id order by item.scanned_at desc limit 1) as export_info on true
  left join lateral (select case when count(distinct s.department)=1 then min(s.department::text) end department
   from public.job_work_order_steps s where s.work_order_id=(select w.id from public.job_work_orders w where w.job_id=job.id order by w.created_at desc,w.id desc limit 1)
   and s.step_status::text='in_progress' and job.current_status::text in ('work_required','rework','qc_failed','initial_qc_completed','no_work_required')) active_department on true
  order by selected.entered_at desc,device.id
 ) select jsonb_build_object('total',(select count(*) from matching),'rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.date_entered desc,r.device_id) from journey r),'[]'::jsonb)) into v_result;
 return v_result;
end; $list$;
revoke all on function public.get_stock_journey_v1(date,date,text,integer,integer) from public,anon;
grant execute on function public.get_stock_journey_v1(date,date,text,integer,integer) to authenticated;
create or replace function public.get_stock_journey_details_v1(p_device_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $journey$
declare v_device public.devices%rowtype; v_names boolean; v_rows jsonb; v_summary jsonb; v_result jsonb; v_matches integer;
begin
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not coalesce(
 (select p.access_level in ('view','edit') from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key='ready_stock_journey'),
 public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then
 raise exception 'Stock Journey permission is required.' using errcode='42501'; end if;
 select d.* into v_device from public.devices d where d.id=p_device_id and d.deleted_at is null;
 if v_device.id is null then return jsonb_build_object('found',false); end if;
 v_names:=coalesce(public.get_my_partner_name_access(),false);
 with device_jobs as (select * from public.jobs where device_id=v_device.id and deleted_at is null),
 structured as (
select b.received_at occurred_at, 10 sort_order, null::uuid job_id, jsonb_build_object('id', 'receipt:'||b.id, 'occurred_at', b.received_at, 'stage', 'stock_received', 'title', 'Stock received', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=b.created_by), 'job_number', null, 'status', 'received', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Receipt', b.batch_number, 'Invoice', b.invoice_number, 'Supplier code', s.supplier_code, 'Supplier name', case when v_names then s.company_name else null end, 'Quantity received', b.planned_quantity, 'Stock channel', c.channel_name)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'stock_received') data
from public.receiving_batches b join (select distinct receiving_batch_id from device_jobs where receiving_batch_id is not null) linked on linked.receiving_batch_id=b.id left join public.suppliers s on s.id=b.supplier_id left join public.stock_channels c on c.id=b.stock_channel_id
union all
select j.received_at occurred_at, 10 sort_order, j.id job_id, jsonb_build_object('id', 'individual-receipt:'||j.id, 'occurred_at', j.received_at, 'stage', 'stock_received', 'title', 'Device received (individual job)', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=j.received_by), 'job_number', j.job_number, 'status', 'received', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Supplier code', s.supplier_code, 'Supplier name', case when v_names then s.company_name else null end, 'Receipt type', 'Individual job; no stock batch linked', 'Stock channel', j.receiving_source)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'stock_received') data
from device_jobs j left join public.suppliers s on s.id=j.supplier_id where j.receiving_batch_id is null
union all
select j.created_at occurred_at, 20 sort_order, j.id job_id, jsonb_build_object('id', 'entry:'||j.id, 'occurred_at', j.created_at, 'stage', 'imei_entry', 'title', case when j.created_at=(select min(created_at) from device_jobs) then 'IMEI entered' else 'IMEI received for another job' end, 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=coalesce(j.created_by,j.received_by)), 'job_number', j.job_number, 'status', 'received', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Supplier code', (select s.supplier_code from public.suppliers s where s.id=j.supplier_id), 'Supplier name', case when v_names then (select s.company_name from public.suppliers s where s.id=j.supplier_id) else null end, 'Customer code', (select c.customer_code from public.customers c where c.id=j.customer_id), 'Customer name', case when v_names then (select c.company_name from public.customers c where c.id=j.customer_id) else null end, 'Job type', replace(j.job_type::text,'_',' '), 'Supplier grade', j.supplier_grade, 'Cost basis', 'Recorded purchase cost for this job')), 'parts', '[]'::jsonb, 'cost', j.purchase_cost, 'duration_seconds', null, 'duration_label', null, 'source', 'imei_entry') data
from device_jobs j
union all
select r.inspected_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'initial-qc:'||r.id, 'occurred_at', r.inspected_at, 'stage', 'initial_qc', 'title', 'Initial QC inspection', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.inspected_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Condition', r.overall_condition, 'Cosmetic condition', r.cosmetic_condition, 'Work required', case when r.work_required then 'Yes' else 'No' end, 'Findings', (select string_agg(concat_ws(' — ',f.check_item,f.action_required,replace(f.department::text,'_',' ')), '; ' order by f.created_at,f.id) from public.initial_qc_findings f where f.inspection_id=r.id and f.issue_found), 'Notes', case when v_names then r.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'initial_qc') data
from public.initial_qc_inspections r join device_jobs j on j.id=r.job_id
union all
select s.assigned_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'assignment:'||s.id, 'occurred_at', s.assigned_at, 'stage', 'assignment', 'title', initcap(s.department::text)||' assigned to technician', 'actor', coalesce(nullif(s.assigned_technician_name,''),(select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=s.assigned_technician_id)), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Department', replace(s.department::text,'_',' '), 'Assignment', 'Latest assignment saved on this work step', 'Rework cycle', s.rework_count)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'assignment') data
from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join device_jobs j on j.id=w.job_id where s.assigned_at is not null
union all
select r.started_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'laboratory-start:'||r.id, 'occurred_at', r.started_at, 'stage', 'laboratory', 'title', 'Laboratory work started', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.technician_id), 'job_number', j.job_number, 'status', 'in_progress', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Rework cycle', r.rework_cycle)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'laboratory') data
from public.laboratory_work_records r join device_jobs j on j.id=r.job_id where r.started_at is not null
union all
select r.completed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'laboratory-complete:'||r.id, 'occurred_at', r.completed_at, 'stage', 'laboratory', 'title', 'Laboratory work completed', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.technician_id), 'job_number', j.job_number, 'status', 'completed', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Work done', case when v_names then r.work_done else null end, 'Notes', case when v_names then r.notes else null end, 'Cost basis', 'Recorded material cost', 'Rework cycle', r.rework_cycle)), 'parts', '[]'::jsonb, 'cost', r.material_cost, 'duration_seconds', case when r.active_seconds is not null then r.active_seconds::numeric when r.completed_at>=r.started_at then greatest(0,extract(epoch from r.completed_at-r.started_at)-r.paused_seconds) end, 'duration_label', 'Active repair time', 'source', 'laboratory') data
from public.laboratory_work_records r join device_jobs j on j.id=r.job_id where r.completed_at is not null
union all
select r.started_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'glass-start:'||r.id, 'occurred_at', r.started_at, 'stage', 'glass', 'title', 'Glass work started', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.assigned_to), 'job_number', j.job_number, 'status', 'in_progress', 'details', greenloop_private.imei_journey_details(jsonb_build_object()), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'glass') data
from public.glass_work_records r join device_jobs j on j.id=r.job_id where r.started_at is not null
union all
select r.completed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'glass-complete:'||r.id, 'occurred_at', r.completed_at, 'stage', 'glass', 'title', 'Glass work completed', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.assigned_to), 'job_number', j.job_number, 'status', 'completed', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Work done', case when v_names then r.work_done else null end, 'Notes', case when v_names then r.notes else null end, 'Cost basis', 'Recorded material cost')), 'parts', '[]'::jsonb, 'cost', r.material_cost, 'duration_seconds', case when r.completed_at>=r.started_at then extract(epoch from r.completed_at-r.started_at) end, 'duration_label', 'Elapsed work time', 'source', 'glass') data
from public.glass_work_records r join device_jobs j on j.id=r.job_id where r.completed_at is not null
union all
select r.reviewed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'service:'||r.id, 'occurred_at', r.reviewed_at, 'stage', 'laboratory', 'title', 'Service requirement reviewed', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.reviewed_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Service', r.service_name, 'Required', case when r.is_required then 'Yes' else 'No' end, 'Record type', 'Requirement review; not proof of completion', 'Notes', case when v_names then r.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'laboratory') data
from public.lab_service_reviews r join device_jobs j on j.id=r.job_id
union all
select r.requested_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'part-request:'||r.id, 'occurred_at', r.requested_at, 'stage', 'parts', 'title', 'Part requested', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.requested_by), 'job_number', j.job_number, 'status', 'requested', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Request source', replace(r.request_source::text,'_',' '), 'Current request status', r.status, 'Notes', case when v_names then r.notes else null end)), 'parts', jsonb_build_array(jsonb_build_object('name', r.part_name, 'quantity', r.quantity_requested, 'unit_cost', null, 'total_cost', null)), 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'parts') data
from public.job_part_requests r join device_jobs j on j.id=r.job_id
union all
select r.issued_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'part-issue:'||r.id, 'occurred_at', r.issued_at, 'stage', 'parts', 'title', 'Part issued', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.issued_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Cost basis', 'Issued value only; counted in device cost when installed or recorded damaged/faulty', 'Notes', case when v_names then r.issue_notes else null end)), 'parts', jsonb_build_array(jsonb_build_object('name', request.part_name, 'quantity', r.quantity_issued, 'unit_cost', r.unit_cost, 'total_cost', r.quantity_issued*r.unit_cost)), 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'parts') data
from public.part_issue_transactions r join public.job_part_requests request on request.id=r.part_request_id join device_jobs j on j.id=request.job_id
union all
select r.installed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'part-installation:'||r.id, 'occurred_at', r.installed_at, 'stage', 'parts', 'title', 'Part installed', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.installed_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Notes', case when v_names then r.notes else null end)), 'parts', jsonb_build_array(jsonb_build_object('name', request.part_name, 'quantity', r.quantity_installed, 'unit_cost', r.unit_cost, 'total_cost', r.quantity_installed*r.unit_cost)), 'cost', r.quantity_installed*r.unit_cost, 'duration_seconds', null, 'duration_label', null, 'source', 'parts') data
from public.part_installations r join public.job_part_requests request on request.id=r.part_request_id join device_jobs j on j.id=r.job_id
union all
select r.installed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'manual-part:'||r.id, 'occurred_at', r.installed_at, 'stage', 'parts', 'title', 'Part installed (manual record)', 'actor', (select nullif(e.event_data->>'technician','') from public.device_events e where e.device_id=r.device_id and e.job_id=r.job_id and e.event_type='laboratory_manual_parts_saved' and e.created_at=r.installed_at order by e.id limit 1), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Recorded by', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.installed_by), 'Price', 'Not recorded — excluded from recorded total', 'Notes', case when v_names then r.notes else null end)), 'parts', jsonb_build_array(jsonb_build_object('name', r.part_name, 'quantity', r.quantity, 'unit_cost', null, 'total_cost', null)), 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'parts') data
from public.lab_manual_part_installations r join device_jobs j on j.id=r.job_id
union all
select r.returned_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'part-return:'||r.id, 'occurred_at', r.returned_at, 'stage', 'parts', 'title', case when r.return_condition='restocked' then 'Unused part returned to inventory' else 'Part returned — '||r.return_condition end, 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.returned_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Condition', r.return_condition, 'Reason', case when v_names then r.reason else null end, 'Cost basis', case when r.return_condition='restocked' then 'Restocked value; not added to device cost' else 'Consumed part cost recorded once' end)), 'parts', jsonb_build_array(jsonb_build_object('name', r.part_name, 'quantity', r.quantity, 'unit_cost', r.unit_cost, 'total_cost', r.quantity*r.unit_cost)), 'cost', case when r.return_condition in ('damaged','faulty') then r.quantity*r.unit_cost end, 'duration_seconds', null, 'duration_label', null, 'source', 'parts') data
from public.part_return_audit r join device_jobs j on j.id=r.job_id
union all
select r.inspected_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'final-qc:'||r.id, 'occurred_at', r.inspected_at, 'stage', 'final_qc', 'title', case when r.result='pass' then 'Final QC passed' else 'Final QC failed' end, 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.inspected_by), 'job_number', j.job_number, 'status', r.result::text, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Attempt', r.attempt_number, 'Final grade', r.final_grade, 'Final battery health', case when r.final_battery_health is not null then r.final_battery_health::text||'%' end, 'Next step', case when r.routed_to_frame then 'Frame Department' end, 'Failure department', r.failure_department::text, 'Failure reason', case when v_names then r.failure_reason else null end, 'Checks', (select string_agg(c.check_item||': '||case when c.passed then 'Pass' else 'Fail' end,'; ' order by c.created_at,c.id) from public.final_qc_check_results c where c.inspection_id=r.id), 'Notes', case when v_names then r.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'final_qc') data
from public.final_qc_inspections r join device_jobs j on j.id=r.job_id
union all
select r.reviewed_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'frame:'||r.id, 'occurred_at', r.reviewed_at, 'stage', 'frame', 'title', 'Frame Department '||case when r.result='pass' then 'passed' else 'failed' end, 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.reviewed_by), 'job_number', j.job_number, 'status', r.result, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Notes', case when v_names then r.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'frame') data
from public.frame_department_results r join device_jobs j on j.id=r.job_id
union all
select r.started_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'timer-start:'||r.id, 'occurred_at', r.started_at, 'stage', 'technician', 'title', 'Technician job timer started', 'actor', r.technician_name, 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Timing basis', 'Job elapsed time; includes waiting and is separate from active repair time')), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'technician') data
from public.technician_job_timers r join device_jobs j on j.id=r.job_id
union all
select r.stopped_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'timer-stop:'||r.id, 'occurred_at', r.stopped_at, 'stage', 'technician', 'title', 'Technician job timer stopped', 'actor', r.technician_name, 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Stopped by', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.stopped_by), 'Timing basis', 'Includes waiting; not added to active repair time')), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', coalesce(r.elapsed_seconds,extract(epoch from r.stopped_at-r.started_at)), 'duration_label', 'Technician job elapsed time', 'source', 'technician') data
from public.technician_job_timers r join device_jobs j on j.id=r.job_id where r.stopped_at is not null
union all
select r.scanned_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'export-box:'||r.id, 'occurred_at', r.scanned_at, 'stage', 'export', 'title', 'Scanned into export box', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.scanned_by), 'job_number', j.job_number, 'status', 'shipped', 'details', greenloop_private.imei_journey_details(jsonb_build_object('Box number', b.box_number, 'Box position', r.serial_no, 'Model in export record', r.model, 'Storage (GB)', r.storage_gb, 'Color in export record', r.color, 'Final grade', r.final_grade, 'Stage meaning', 'Greenloop marks the phone Shipped when scanned into an export box. This is not a courier dispatch timestamp.')), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'export') data
from public.export_box_items r join public.export_boxes b on b.id=r.box_id join device_jobs j on j.id=r.job_id
union all
select r.dispatched_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'dispatch:'||r.id, 'occurred_at', r.dispatched_at, 'stage', 'export', 'title', 'Stock dispatched', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=r.dispatched_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Dispatch number', r.stock_out_number, 'Dispatch type', r.stock_out_type::text, 'Destination', case when v_names then r.destination else null end, 'Shipment reference', case when v_names then r.shipment_reference else null end, 'Recipient', case when v_names then r.recipient_name else null end, 'Notes', case when v_names then r.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'export') data
from public.stock_out_records r join device_jobs j on j.id=r.job_id
union all
select e.occurred_at occurred_at, 50 sort_order, j.id job_id, jsonb_build_object('id', 'supplier-return:'||e.id, 'occurred_at', e.occurred_at, 'stage', 'stock_return', 'title', case e.action when 'handover' then 'Returned to supplier' when 'requested' then 'Supplier return requested' when 'approve' then 'Supplier return approved' when 'reject' then 'Supplier return rejected' when 'cancel' then 'Supplier return cancelled' when 'settlement' then 'Supplier return settlement recorded' else 'Supplier return — '||replace(e.action,'_',' ') end, 'actor', e.actor_name, 'job_number', j.job_number, 'status', e.to_status, 'details', greenloop_private.imei_journey_details(jsonb_build_object('Return number', r.return_number, 'Supplier code', coalesce(r.source_snapshot->>'supplier_code',s.supplier_code), 'Supplier name', case when v_names then coalesce(r.source_snapshot->>'supplier_name',s.company_name) else null end, 'Reason', r.reason, 'Handover reference', case when e.action='handover' then r.slip_reference end, 'Notes', case when v_names then e.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'stock_return') data
from public.supplier_return_events e join public.supplier_returns r on r.id=e.return_id join device_jobs j on j.id=r.job_id left join public.suppliers s on s.id=r.supplier_id where r.device_id=v_device.id and r.archived_at is null
 ), events as (select e.created_at occurred_at, 60 sort_order, e.job_id, jsonb_build_object('id', 'event:'||e.id, 'occurred_at', e.created_at, 'stage', case when e.event_type like '%rework%' then 'rework' when e.event_type='frame_passed_ready_stock' then 'ready_stock' when e.event_type like 'final_qc%' then 'final_qc' when e.event_type like 'frame%' then 'frame' when e.event_type like '%laboratory%' then 'laboratory' when e.event_type like '%glass%' then 'glass' when e.event_type like '%part%' then 'parts' when e.event_type like '%export%' or e.event_type like '%stock_out%' then 'export' else 'workflow' end, 'title', case when v_names then e.event_title when e.event_type='frame_passed_ready_stock' then 'Frame passed and sent to Ready Stock' when e.event_type='ready_stock_rework_started' then 'Ready Stock sent for rework' else initcap(replace(e.event_type,'_',' ')) end, 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=e.actor_id), 'job_number', j.job_number, 'status', coalesce(e.event_data->>'next_status',e.event_data->>'result',e.event_data->>'status'), 'details', greenloop_private.imei_journey_details(jsonb_build_object('Department', e.event_data->>'department', 'Next department', e.event_data->>'next_department', 'Technician', coalesce(e.event_data->>'technician',e.event_data->>'technician_name',e.event_data->>'assigned_technician_name'), 'Service', e.event_data->>'service', 'Required', e.event_data->>'required', 'Rework cycle', e.event_data->>'rework_cycle', 'Final grade', e.event_data->>'final_grade', 'Final battery health', e.event_data->>'final_battery_health', 'Box number', e.event_data->>'box_number', 'Part', coalesce(e.event_data->>'part_name',e.event_data->>'part'), 'Quantity', e.event_data->>'quantity', 'Reason', case when v_names then coalesce(e.event_data->>'customer_reason',e.event_data->>'reason',e.event_data->>'failure_reason') else null end, 'Notes', case when v_names then e.event_data->>'notes' else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', case when e.event_data->>'active_seconds' ~ '^[0-9]{1,10}$' then (e.event_data->>'active_seconds')::numeric else case when e.event_type='laboratory_completed' then (select extract(epoch from e.created_at-max(r.started_at)) from public.laboratory_work_records r where r.job_id=e.job_id and r.started_at<=e.created_at and (e.event_data->>'step_id' is null or r.work_order_step_id::text=e.event_data->>'step_id')) end end, 'duration_label', case when e.event_data->>'active_seconds' ~ '^[0-9]{1,10}$' then 'Recorded active time' when e.event_type='laboratory_completed' then 'Elapsed laboratory time' end, 'source', 'event') data
from public.device_events e left join device_jobs j on j.id=e.job_id
where e.device_id=v_device.id and (e.job_id is null or j.id is not null)
and not (e.event_type like 'supplier_return_%' and exists(select 1 from public.supplier_return_events se join public.supplier_returns sr on sr.id=se.return_id where sr.device_id=v_device.id and sr.archived_at is null and se.occurred_at=e.created_at))
and not exists(select 1 from structured s where s.job_id=e.job_id and s.occurred_at=e.created_at and split_part(s.data->>'id',':',1)=any(case e.event_type when 'stock_batch_imei_received' then array['entry']::text[]
when 'initial_qc_completed' then array['initial-qc']::text[]
when 'laboratory_work_started' then array['laboratory-start']::text[]
when 'laboratory_work_completed' then array['laboratory-complete']::text[]
when 'glass_work_started' then array['glass-start']::text[]
when 'glass_work_completed' then array['glass-complete']::text[]
when 'part_installed' then array['part-installation']::text[]
when 'laboratory_manual_parts_saved' then array['manual-part']::text[]
when 'laboratory_part_restocked' then array['part-return']::text[]
when 'laboratory_part_damaged' then array['part-return']::text[]
when 'parts_return_approved' then array['part-return']::text[]
when 'final_qc_passed' then array['final-qc']::text[]
when 'final_qc_failed' then array['final-qc']::text[]
when 'frame_failed' then array['frame']::text[]
when 'export_box_scanned' then array['export-box']::text[]
when 'stock_out_completed' then array['dispatch']::text[]
when 'laboratory_service_reviewed' then array['service']::text[] else array[]::text[] end))), all_records as (select * from structured union all select * from events),
 movements as (
 select m.moved_at occurred_at,70 sort_order,m.job_id,jsonb_build_object('id', 'movement:'||m.id, 'occurred_at', m.moved_at, 'stage', 'movement', 'title', 'Location changed', 'actor', (select nullif(btrim(p.full_name),'') from public.user_profiles p where p.id=m.moved_by), 'job_number', j.job_number, 'status', null, 'details', greenloop_private.imei_journey_details(jsonb_build_object('From', case when v_names then fl.location_name else fl.location_code end, 'To', case when v_names then tl.location_name else tl.location_code end, 'Reason', case when v_names then m.movement_reason else null end, 'Notes', case when v_names then m.notes else null end)), 'parts', '[]'::jsonb, 'cost', null, 'duration_seconds', null, 'duration_label', null, 'source', 'movement') data
 from public.device_location_history m left join device_jobs j on j.id=m.job_id left join public.locations fl on fl.id=m.from_location_id left join public.locations tl on tl.id=m.to_location_id
 where m.device_id=v_device.id and (m.job_id is null or j.id is not null)

 ), final_rows as (select * from all_records union all select * from movements)
 select coalesce(jsonb_agg(data order by occurred_at nulls last,sort_order,data->>'id'),'[]'::jsonb) into v_rows from final_rows;

 if not exists(select 1 from public.jobs where device_id=v_device.id and deleted_at is null) then
  v_rows:=jsonb_build_array(jsonb_build_object('id','device-entry:'||v_device.id,'occurred_at',v_device.created_at,'stage','imei_entry','title','IMEI entered','actor',null,'details','[]'::jsonb,'parts','[]'::jsonb))||v_rows;
 end if;
 with device_jobs as (select * from public.jobs where device_id=v_device.id and deleted_at is null), costs as (
 select coalesce((select sum(purchase_cost) from device_jobs),0) purchase,
 coalesce((select sum(p.quantity_installed*p.unit_cost) from public.part_installations p join device_jobs j on j.id=p.job_id),0) installed,
 coalesce((select sum(p.quantity*p.unit_cost) from public.part_return_audit p join device_jobs j on j.id=p.job_id where p.return_condition in ('damaged','faulty')),0) damaged,
 coalesce((select sum(p.material_cost) from public.laboratory_work_records p join device_jobs j on j.id=p.job_id),0) laboratory,
 coalesce((select sum(p.material_cost) from public.glass_work_records p join device_jobs j on j.id=p.job_id),0) glass,
 coalesce((select sum(p.quantity) from public.lab_manual_part_installations p join device_jobs j on j.id=p.job_id),0) manual,
 (select min(coalesce(b.received_at,j.received_at)) from device_jobs j left join public.receiving_batches b on j.receiving_batch_id=b.id) received,
 (select max(e.created_at) from public.device_events e join device_jobs j on j.id=e.job_id where e.device_id=v_device.id and (e.event_type='frame_passed_ready_stock' or (e.event_type='final_qc_passed' and e.event_data->>'next_status' in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment') and not exists(select 1 from public.final_qc_inspections f where f.job_id=e.job_id and f.inspected_at=e.created_at and f.routed_to_frame)))) ready
 ) select jsonb_build_object('purchase_cost',purchase,'installed_parts_cost',installed,'damaged_parts_cost',damaged,'laboratory_material_cost',laboratory,'glass_material_cost',glass,'recorded_total_cost',purchase+installed+damaged+laboratory+glass,'unpriced_manual_part_quantity',manual,'first_received_at',received,'last_ready_at',ready,'receipt_to_ready_seconds',case when ready>=received then extract(epoch from ready-received) end,'cost_note','Recorded purchase + installed parts + damaged/faulty parts + laboratory/glass materials. Issued/restocked values are not added again. Manual parts without a recorded price are excluded.') into v_summary from costs;

 select jsonb_build_object('found',true,'version','20261002-imei-history-1','device',jsonb_build_object(
 'device_number',v_device.device_number,'imei_1',v_device.imei_1,'imei_2',v_device.imei_2,'serial_number',v_device.serial_number,'brand',v_device.brand,'model',v_device.model,'storage_gb',v_device.storage_gb,'color',v_device.color,'region',v_device.specification_region,'current_status',v_device.current_status::text,'current_location',(select case when v_names then location_name else location_code end from public.locations where id=v_device.current_location_id),
 'supplier_code',s.supplier_code,'supplier_name',case when v_names then s.company_name end,'customer_code',c.customer_code,'customer_name',case when v_names then c.company_name end),
 'rows',v_rows,'summary',v_summary,'partner_names_visible',v_names) into v_result
 from (select 1) anchor left join lateral (select * from public.jobs where device_id=v_device.id and deleted_at is null order by created_at desc,id limit 1) j on true
 left join public.suppliers s on s.id=j.supplier_id left join public.customers c on c.id=coalesce(j.customer_id,v_device.current_owner_customer_id);
 return v_result;
end;
$journey$;

revoke all on function public.get_stock_journey_details_v1(uuid) from public,anon;
grant execute on function public.get_stock_journey_details_v1(uuid) to authenticated;
create table if not exists greenloop_private.stock_journey_installation(function_identity text primary key,definition_hash text not null);
revoke all on greenloop_private.stock_journey_installation from public,anon,authenticated;
insert into greenloop_private.stock_journey_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in (
 'public.get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure,'public.get_stock_journey_details_v1(uuid)'::regprocedure)
on conflict(function_identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_stock_journey_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when (select count(*)=2 and bool_and(to_regprocedure(i.function_identity) is not null and md5(pg_get_functiondef(to_regprocedure(i.function_identity)))=i.definition_hash
 and not has_function_privilege('anon',to_regprocedure(i.function_identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(i.function_identity),'EXECUTE')) from greenloop_private.stock_journey_installation i)
 and public.get_greenloop_imei_history_version()='20261002-imei-history-1'
 and not has_table_privilege('anon','greenloop_private.stock_journey_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.stock_journey_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then '20261006-stock-journey-1' end;
$version$;
revoke all on function public.get_stock_journey_version() from public;
grant execute on function public.get_stock_journey_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_stock_journey_version() as installed_stock_journey_version;
