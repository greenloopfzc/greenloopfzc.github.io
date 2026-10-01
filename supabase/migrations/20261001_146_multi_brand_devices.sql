-- Android and multi-brand device intake. Additive, transactional, replay-safe.
-- No existing records or original workflow routines are changed.
begin;
do $$ declare v_signature text; begin
  if to_regprocedure('public.get_greenloop_stock_return_reset_version()') is null then
    raise exception 'Install the current Stock Return reset update first.' using errcode='55000';
  end if;
  if public.get_greenloop_stock_return_reset_version() is distinct from '20260926-stock-return-reset-1' then
    raise exception 'Existing Stock Return safeguards could not be verified. No changes were installed.' using errcode='55000';
  end if;
  foreach v_signature in array array[
    'public.greenloop_require_entry(text[])',
    'public.complete_final_qc(uuid,public.final_qc_result,text,public.work_department,text,jsonb)',
    'public.complete_scanned_initial_qc_with_roster_and_grades(uuid,text,text,text,jsonb,jsonb,uuid,text,text)',
    'public.send_ready_stock_for_rework(text,text,text)',
    'public.assign_ready_stock_rework_technician(text,uuid)',
    'greenloop_private.supplier_return_batch(uuid)'
  ] loop
    if to_regprocedure(v_signature) is null then raise exception 'Required workflow routine % is missing. No changes were installed.',v_signature using errcode='55000'; end if;
  end loop;
end; $$;

alter table public.devices add column if not exists device_platform text;
alter table public.devices add column if not exists battery_health_unavailable boolean not null default false;
alter table public.final_qc_inspections add column if not exists final_battery_health_unavailable boolean not null default false;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.devices'::regclass and conname='devices_mobile_platform_check') then
    alter table public.devices add constraint devices_mobile_platform_check check(device_platform is null or device_platform in ('ios','android'));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.devices'::regclass and conname='devices_mobile_battery_availability_check') then
    alter table public.devices add constraint devices_mobile_battery_availability_check check(not battery_health_unavailable or (battery_health is null and device_platform is not distinct from 'android'));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.final_qc_inspections'::regclass and conname='final_qc_mobile_battery_availability_check') then
    alter table public.final_qc_inspections add constraint final_qc_mobile_battery_availability_check check(not final_battery_health_unavailable or final_battery_health is null);
  end if;
end; $$;

create or replace function greenloop_private.validate_mobile_identity(p_brand text,p_platform text)
returns void language plpgsql set search_path=pg_catalog,public as $$
begin
  if p_platform is null or p_platform not in ('ios','android') or nullif(btrim(p_brand),'') is null or length(btrim(p_brand))>80 then
    raise exception 'Select the phone platform and brand.' using errcode='22023';
  end if;
  if (p_platform='ios' and lower(btrim(p_brand))<>'apple') or (p_platform='android' and lower(btrim(p_brand))='apple') then
    raise exception 'The selected brand does not match the phone platform.' using errcode='22023';
  end if;
end; $$;

create or replace function greenloop_private.validate_mobile_battery(p_platform text,p_battery smallint,p_unavailable boolean,p_required boolean)
returns void language plpgsql set search_path=pg_catalog,public as $$
begin
  if coalesce(p_unavailable,false) then
    if p_platform is distinct from 'android' or p_battery is not null then
      raise exception 'Battery Health unavailable is only allowed for an Android phone without a percentage.' using errcode='22023';
    end if;
  elsif p_required and p_battery is null then
    raise exception 'Enter Battery Health, or explicitly select Not available for an Android phone.' using errcode='22023';
  end if;
  if p_battery is not null and p_battery not between 0 and 100 then
    raise exception 'Battery Health must be from 0 to 100.' using errcode='22023';
  end if;
end; $$;

-- Corrections that supply a real percentage also clear its explicit unavailable flag.
create or replace function greenloop_private.mobile_device_metadata_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.device_platform is not null then
    perform greenloop_private.validate_mobile_identity(new.brand,new.device_platform);
  end if;
  if new.battery_health is not null then new.battery_health_unavailable:=false; end if;
  return new;
end; $$;
drop trigger if exists mobile_device_metadata_guard on public.devices;
create trigger mobile_device_metadata_guard before insert or update of brand,device_platform,battery_health,battery_health_unavailable on public.devices
for each row execute function greenloop_private.mobile_device_metadata_guard();

create or replace function greenloop_private.receive_mobile_stock_imei(
  p_batch_id uuid,
  p_imei_1 text,
  p_model text,
  p_storage_gb integer,
  p_color text,
  p_battery_health smallint,
  p_brand text, p_platform text, p_battery_health_unavailable boolean
)
returns table (
  device_id uuid,
  device_number text,
  job_id uuid,
  job_number text,
  existing_device boolean,
  entered_quantity integer,
  planned_quantity integer,
  remaining_quantity integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_imei text := nullif(btrim(p_imei_1), '');
  v_model text := nullif(regexp_replace(btrim(p_model), '\s+', ' ', 'g'), '');
  v_color text := nullif(regexp_replace(btrim(p_color), '\s+', ' ', 'g'), '');
  v_batch record;
  v_entered integer;
  v_receiving_location_id uuid;
  v_device_id uuid;
  v_device_number text;
  v_job_id uuid;
  v_job_number text;
  v_previous_location_id uuid;
  v_existing boolean := false;
  v_job_type public.job_type;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['imei_entry']::text[]);
  if not coalesce(public.has_page_edit_access('imei_entry'),false) then raise exception 'IMEI Entry edit permission is required.' using errcode='42501'; end if;
  if not public.has_role(array['super_admin', 'owner', 'manager', 'receiving', 'rma']::public.app_role_key[]) then
    raise exception 'You do not have permission to receive stock.' using errcode = '42501';
  end if;
  if v_imei is null or v_imei !~ '^[0-9]{15}$' then
    raise exception 'Scan a valid 15-digit IMEI.' using errcode = '22023';
  end if;
  if v_model is null then
    raise exception 'Model is required.' using errcode = '22023';
  end if;
  if p_storage_gb is null or p_storage_gb <= 0 then
    raise exception 'Storage (GB) is required.' using errcode = '22023';
  end if;
  if v_color is null then
    raise exception 'Color is required.' using errcode = '22023';
  end if;
  perform greenloop_private.validate_mobile_identity(p_brand,p_platform);
  perform greenloop_private.validate_mobile_battery(p_platform,p_battery_health,p_battery_health_unavailable,true);

  select batch.id, batch.batch_number, batch.receiving_source, batch.notes,
         batch.planned_quantity, batch.supplier_id
  into v_batch
  from public.receiving_batches batch
  where batch.id = p_batch_id and batch.planned_quantity is not null
  for update;
  if v_batch.id is null then
    raise exception 'The selected stock batch was not found.' using errcode = '22023';
  end if;

  select count(*)::integer into v_entered
  from public.jobs job
  where job.receiving_batch_id = v_batch.id and job.deleted_at is null;
  if v_entered + (select count(*) from public.supplier_returns r where r.batch_id=p_batch_id and r.device_id is null and r.status in ('requested','approved','returned')) >= v_batch.planned_quantity then
    raise exception 'This stock batch is already complete.' using errcode = '22023';
  end if;

  select location.id into v_receiving_location_id
  from public.locations location
  where location.location_code = 'RECEIVING' and location.is_active;
  if v_receiving_location_id is null then
    raise exception 'Receiving location is not configured.' using errcode = '22023';
  end if;

  select device.id, device.device_number, device.current_location_id
  into v_device_id, v_device_number, v_previous_location_id
  from public.devices device
  where (device.imei_1 = v_imei or device.imei_2 = v_imei)
    and device.deleted_at is null
  limit 1
  for update;

  v_existing := v_device_id is not null;
  if v_existing then
    update public.devices
    set model = v_model,
        brand = btrim(p_brand), device_platform = p_platform, battery_health_unavailable = coalesce(p_battery_health_unavailable,false),
        storage_gb = p_storage_gb,
        color = v_color,
        battery_health = p_battery_health,
        current_owner_type = 'company_owned',
        current_owner_customer_id = null,
        current_location_id = v_receiving_location_id,
        current_status = 'initial_qc_pending',
        notes = coalesce(v_batch.notes, notes)
    where id = v_device_id;
  else
    insert into public.devices as device (
      device_number, imei_1, model, storage_gb, color, battery_health, brand, device_platform, battery_health_unavailable,
      current_owner_type, current_location_id, current_status, notes, created_by
    )
    values (
      null, v_imei, v_model, p_storage_gb, v_color, p_battery_health, btrim(p_brand), p_platform, coalesce(p_battery_health_unavailable,false),
      'company_owned', v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
    )
    returning device.id, device.device_number into v_device_id, v_device_number;
  end if;

  v_job_type := case when lower(v_batch.receiving_source) = 'rma' then 'rma'::public.job_type else 'company_refurbishment'::public.job_type end;
  insert into public.jobs as job (
    job_number, device_id, job_type, ownership_type, supplier_id,
    receiving_source, purchase_cost, received_by, receiving_batch_id,
    current_location_id, current_status, notes, created_by
  )
  values (
    null, v_device_id, v_job_type, 'company_owned', v_batch.supplier_id,
    v_batch.receiving_source, 0, auth.uid(), v_batch.id,
    v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
  )
  returning job.id, job.job_number into v_job_id, v_job_number;

  insert into public.device_location_history (
    device_id, job_id, from_location_id, to_location_id, movement_reason, notes, moved_by
  )
  values (
    v_device_id, v_job_id, v_previous_location_id, v_receiving_location_id,
    case when v_existing then 'Stock batch IMEI received as new job' else 'Stock batch IMEI received' end,
    v_batch.notes, auth.uid()
  );

  insert into public.device_events (device_id, job_id, event_type, event_title, event_data, actor_id)
  values (
    v_device_id, v_job_id, 'stock_batch_imei_received', 'IMEI received into stock batch',
    jsonb_build_object('batch_number', v_batch.batch_number, 'stock_channel', v_batch.receiving_source, 'brand', btrim(p_brand), 'device_platform', p_platform, 'battery_health', p_battery_health, 'battery_health_unavailable', coalesce(p_battery_health_unavailable,false)), auth.uid()
  );

  v_entered := v_entered + 1;
  return query select v_device_id, v_device_number, v_job_id, v_job_number, v_existing,
    v_entered, v_batch.planned_quantity, (greenloop_private.supplier_return_batch(p_batch_id)->>'remaining_quantity')::integer;
end;
$$;

create or replace function public.receive_stock_batch_imei_with_plan_v2(
  p_batch_id uuid, p_imei_1 text, p_model text, p_storage_gb integer, p_color text, p_battery_health smallint,
  p_brand text, p_platform text, p_battery_health_unavailable boolean default false
)
returns table (
  device_id uuid, device_number text, job_id uuid, job_number text, existing_device boolean,
  entered_quantity integer, planned_quantity integer, remaining_quantity integer
)
language plpgsql security definer set search_path = public
as $$
declare
  v_has_plan boolean;
  v_plan_id uuid;
  v_plan_model text;
  v_plan_quantity integer;
  v_plan_storage_gb integer;
  v_plan_color text;
  v_plan_entered integer;
  v_model text := nullif(regexp_replace(btrim(coalesce(p_model, '')), '\s+', ' ', 'g'), '');
  v_color text := nullif(regexp_replace(btrim(coalesce(p_color, '')), '\s+', ' ', 'g'), '');
  v_existing_device_number text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['imei_entry']::text[]);
  if not coalesce(public.has_page_edit_access('imei_entry'),false) then raise exception 'IMEI Entry edit permission is required.' using errcode='42501'; end if;
  perform 1 from public.receiving_batches where id=p_batch_id for update;
  if not public.has_role(array['super_admin', 'owner', 'manager', 'receiving', 'rma']::public.app_role_key[]) then
    raise exception 'You do not have permission to receive stock.' using errcode = '42501';
  end if;

  select device.device_number into v_existing_device_number
  from public.devices device
  where device.imei_1 = nullif(btrim(p_imei_1), '') or device.imei_2 = nullif(btrim(p_imei_1), '')
  limit 1;

  if v_existing_device_number is not null then
    raise exception 'Duplicate IMEI: this IMEI already belongs to device %. It cannot be received again.', v_existing_device_number using errcode = '23505';
  end if;

  select exists (select 1 from public.stock_batch_plan_lines plan where plan.receiving_batch_id = p_batch_id)
  into v_has_plan;

  if v_has_plan then
    select plan.id, plan.model, plan.planned_quantity, plan.storage_gb, plan.color
      into v_plan_id, v_plan_model, v_plan_quantity, v_plan_storage_gb, v_plan_color
    from public.stock_batch_plan_lines plan
    where plan.receiving_batch_id = p_batch_id
      and (plan.model is null or lower(regexp_replace(btrim(plan.model), '\s+', ' ', 'g')) = lower(v_model))
      and (plan.storage_gb is null or plan.storage_gb = p_storage_gb)
      and (plan.color is null or lower(regexp_replace(btrim(plan.color), '\s+', ' ', 'g')) = lower(v_color))
    order by (plan.model is null), (plan.storage_gb is null), (plan.color is null)
    limit 1;

    if v_plan_id is null then
      raise exception 'This Model, GB and Color combination is not in the selected supplier stock plan.' using errcode = '22023';
    end if;

    perform 1 from public.stock_batch_plan_lines plan where plan.id = v_plan_id for update;

    select count(job.id)::integer into v_plan_entered
    from public.jobs job
    join public.devices device on device.id = job.device_id
    where job.receiving_batch_id = p_batch_id and job.deleted_at is null
      and (v_plan_model is null or lower(regexp_replace(btrim(coalesce(device.model, '')), '\s+', ' ', 'g')) = lower(v_plan_model))
      and (v_plan_storage_gb is null or device.storage_gb = v_plan_storage_gb)
      and (v_plan_color is null or lower(regexp_replace(btrim(coalesce(device.color, '')), '\s+', ' ', 'g')) = lower(v_plan_color));

    if v_plan_entered + (select count(*) from public.supplier_returns r where r.plan_line_id=v_plan_id and r.device_id is null and r.status in ('requested','approved','returned')) >= v_plan_quantity then
      raise exception 'The Total Stock for this plan line is already complete.' using errcode = '22023';
    end if;
  end if;

  return query
  select * from greenloop_private.receive_mobile_stock_imei(p_batch_id, p_imei_1, p_model, p_storage_gb, p_color, p_battery_health, p_brand, p_platform, p_battery_health_unavailable);
end;
$$;

create or replace function public.complete_final_qc_with_final_grade_v2(
  p_job_id uuid,
  p_result public.final_qc_result,
  p_final_grade text,
  p_final_battery_health smallint,
  p_notes text,
  p_failure_department public.work_department,
  p_failure_reason text,
  p_checks jsonb default '[]'::jsonb,
  p_battery_health_unavailable boolean default false
)
returns table (
  inspection_id uuid,
  attempt_number integer,
  result public.final_qc_result,
  next_department public.work_department,
  next_status public.job_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requested_grade text := nullif(regexp_replace(btrim(coalesce(p_final_grade, '')), '\s+', ' ', 'g'), '');
  v_final_grade text;
  v_result record;
  v_platform text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['final_qc','frame_department']::text[]);
  if not public.has_role(array['super_admin', 'owner', 'manager', 'final_qc']::public.app_role_key[]) then
    raise exception 'You do not have permission to complete Final QC.' using errcode = '42501';
  end if;

  if p_result = 'pass' and v_requested_grade is null then
    raise exception 'Select the Final Grade before passing this device.' using errcode = '22023';
  end if;

  select d.device_platform into v_platform from public.jobs j join public.devices d on d.id=j.device_id
  where j.id=p_job_id and j.deleted_at is null and d.deleted_at is null for update of j,d;
  if not found then raise exception 'This phone is not available for Final QC.' using errcode='22023'; end if;
  perform greenloop_private.validate_mobile_battery(v_platform,p_final_battery_health,p_battery_health_unavailable,p_result='pass');

  if p_final_battery_health is not null
     and p_final_battery_health not between 0 and 100 then
    raise exception 'Final Battery Health must be from 0 to 100.' using errcode = '22023';
  end if;

  if p_result = 'pass' then
    select entry.option_value
      into v_final_grade
    from public.entry_options as entry
    where entry.option_group = 'grade'
      and entry.is_active = true
      and lower(regexp_replace(btrim(entry.option_value), '\s+', ' ', 'g')) = lower(v_requested_grade)
    order by entry.created_at desc
    limit 1;

    if v_final_grade is null then
      raise exception 'Select an active Final Grade from the dropdown menu.' using errcode = '22023';
    end if;
  end if;

  select * into v_result
  from public.complete_final_qc(
    p_job_id,
    p_result,
    p_notes,
    p_failure_department,
    p_failure_reason,
    p_checks
  );

  update public.final_qc_inspections as inspection
  set
    final_grade = case when p_result = 'pass' then v_final_grade else null end,
    final_battery_health = p_final_battery_health,
    final_battery_health_unavailable = coalesce(p_battery_health_unavailable,false)
  where inspection.id = v_result.inspection_id;

  return query select
    v_result.inspection_id,
    v_result.attempt_number,
    v_result.result,
    v_result.next_department,
    v_result.next_status;
end;
$$;

create or replace function public.route_final_qc_pass_to_frame_v3(
  p_job_id uuid,
  p_final_grade text,
  p_final_battery_health smallint,
  p_notes text default null,
  p_battery_health_unavailable boolean default false
)
returns table(
  inspection_id uuid,
  attempt_number integer,
  frame_step_id uuid,
  next_status public.job_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_final_step uuid;
  v_work_order uuid;
  v_device uuid;
  v_from_location uuid;
  v_frame_location uuid;
  v_frame_step uuid;
  v_frame_status public.work_order_step_status;
  v_inspection uuid;
  v_attempt integer;
  v_platform text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['final_qc','initial_qc']::text[]);
  if not public.is_active_staff() then
    raise exception 'Active staff access is required.' using errcode = '42501';
  end if;
  select d.device_platform into v_platform from public.jobs j join public.devices d on d.id=j.device_id
  where j.id=p_job_id and j.deleted_at is null and d.deleted_at is null for update of j,d;
  if not found then raise exception 'This phone is not available for Frame routing.' using errcode='22023'; end if;
  perform greenloop_private.validate_mobile_battery(v_platform,p_final_battery_health,p_battery_health_unavailable,true);

  select step.id, step.work_order_id, work_order.device_id, job.current_location_id
    into v_final_step, v_work_order, v_device, v_from_location
  from public.job_work_order_steps as step
  join public.job_work_orders as work_order on work_order.id = step.work_order_id
  join public.jobs as job on job.id = work_order.job_id
  where job.id = p_job_id and job.deleted_at is null
    and step.department = 'final_qc' and step.step_status = 'in_progress'
  for update of step, job;
  if v_final_step is null then
    raise exception 'This phone is not waiting in Final QC.' using errcode = '22023';
  end if;

  select frame_step.id, frame_step.step_status into v_frame_step, v_frame_status
  from public.job_work_order_steps as frame_step
  where frame_step.work_order_id = v_work_order and frame_step.department = 'frame'
  for update;
  if v_frame_step is null then
    insert into public.job_work_order_steps(work_order_id, step_order, department, step_status)
    values (v_work_order, (select coalesce(max(existing_step.step_order), 0) + 10 from public.job_work_order_steps as existing_step where existing_step.work_order_id = v_work_order), 'frame', 'in_progress')
    returning id into v_frame_step;
  else
    update public.job_work_order_steps
    set step_status = 'in_progress', rework_count = rework_count + case when v_frame_status = 'completed' then 1 else 0 end,
        assigned_technician_roster_id = null, assigned_technician_name = null, assigned_at = null, returned_at = null
    where id = v_frame_step;
  end if;

  update public.job_work_order_steps set step_status = 'pending' where id = v_final_step;
  select coalesce(max(inspection.attempt_number), 0) + 1 into v_attempt from public.final_qc_inspections as inspection where inspection.job_id = p_job_id;
  insert into public.final_qc_inspections(job_id, device_id, work_order_step_id, attempt_number, result, notes, inspected_by, final_grade, final_battery_health, routed_to_frame, final_battery_health_unavailable)
  values (p_job_id, v_device, v_final_step, v_attempt, 'pass', concat_ws(' | ', 'Final QC routed to Frame for required work', nullif(btrim(p_notes), '')), v_actor, null, p_final_battery_health, true, coalesce(p_battery_health_unavailable,false))
  returning id into v_inspection;

  select location.id into v_frame_location from public.locations as location where location.location_code = 'FRAME' and location.is_active limit 1;
  if v_frame_location is null then raise exception 'Frame location is not configured.' using errcode = '22023'; end if;
  update public.jobs set current_status = 'frame_pending', current_location_id = v_frame_location where id = p_job_id;
  update public.devices set current_status = 'frame_pending', current_location_id = v_frame_location where id = v_device;
  insert into public.device_location_history(device_id, job_id, from_location_id, to_location_id, movement_reason, moved_by)
  values (v_device, p_job_id, v_from_location, v_frame_location, 'Final QC routed to Frame for required work', v_actor);
  insert into public.device_events(device_id, job_id, event_type, event_title, event_data, actor_id)
  values (v_device, p_job_id, 'final_qc_routed_to_frame', 'Final QC sent to Frame', jsonb_build_object('frame_step_id', v_frame_step, 'attempt_number', v_attempt, 'final_grade_pending', true), v_actor);
  return query select v_inspection, v_attempt, v_frame_step, 'frame_pending'::public.job_status;
end;
$$;

create or replace function public.complete_initial_qc_direct_to_frame_v2(
  p_job_id uuid,
  p_overall_condition text,
  p_cosmetic_condition text,
  p_notes text,
  p_findings jsonb default '[]'::jsonb,
  p_part_requests jsonb default '[]'::jsonb,
  p_assigned_technician_roster_id uuid default null,
  p_supplier_grade text default null,
  p_gc_grade text default null
)
returns table (
  inspection_id uuid,
  work_order_number text,
  parts_requested integer,
  next_department public.work_department,
  next_status public.job_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_battery_health smallint;
  v_platform text; v_unavailable boolean;
  v_result record;
  v_frame_result record;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['initial_qc']::text[]);
  if not public.has_role(array['super_admin', 'owner', 'manager', 'initial_qc']::public.app_role_key[]) then
    raise exception 'Your account does not have Initial QC permission.' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_findings, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_part_requests, '[]'::jsonb)) <> 'array' then
    raise exception 'QC findings and identified parts must be lists.' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_findings, '[]'::jsonb)) > 0
     or jsonb_array_length(coalesce(p_part_requests, '[]'::jsonb)) > 0
     or p_assigned_technician_roster_id is not null then
    raise exception 'Direct Frame routing is only for phones with no Parts, Service, or Technician selection.' using errcode = '22023';
  end if;

  select device.battery_health, device.device_platform, device.battery_health_unavailable
    into v_battery_health, v_platform, v_unavailable
  from public.jobs as job
  join public.devices as device on device.id = job.device_id
  where job.id = p_job_id
    and job.current_status = 'initial_qc_pending'
    and job.deleted_at is null
    and device.deleted_at is null for update of job,device;
  if not found then raise exception 'This phone is not waiting in Initial QC.' using errcode='22023'; end if;
  perform greenloop_private.validate_mobile_battery(v_platform,v_battery_health,v_unavailable,true);

  -- Create the normal no-work Initial QC record first, then immediately move its
  -- ready Final-QC step into Frame. This keeps the complete workflow history intact.
  select * into v_result
  from public.complete_scanned_initial_qc_with_roster_and_grades(
    p_job_id, p_overall_condition, p_cosmetic_condition,
    concat_ws(' | ', 'Initial QC direct to Frame', nullif(btrim(coalesce(p_notes, '')), '')),
    '[]'::jsonb, '[]'::jsonb, null,
    p_supplier_grade, p_gc_grade
  );

  select * into v_frame_result
  from public.route_final_qc_pass_to_frame_v3(
    p_job_id, null, v_battery_health, 'Initial QC direct route to Frame', v_unavailable
  );

  insert into public.device_events(device_id, job_id, event_type, event_title, event_data, actor_id)
  select job.device_id, job.id, 'initial_qc_direct_to_frame', 'Initial QC sent phone directly to Frame',
         jsonb_build_object('frame_step_id', v_frame_result.frame_step_id, 'final_grade_pending', true), auth.uid()
  from public.jobs as job where job.id = p_job_id;

  return query select v_result.inspection_id, v_result.work_order_number, v_result.parts_requested,
    'frame'::public.work_department, 'frame_pending'::public.job_status;
end;
$$;

create or replace function public.complete_frame_to_ready_stock_with_grade_v2(
  p_work_order_step_id uuid,
  p_final_grade text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid(); v_work_order uuid; v_job uuid; v_device uuid; v_from_location uuid;
  v_platform text; v_unavailable boolean;
  v_final_step uuid; v_frame_inspection uuid; v_final_battery smallint; v_ready_location uuid; v_grade text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['frame_department']::text[]);
  if not public.is_active_staff() then raise exception 'Active staff access is required.' using errcode = '42501'; end if;
  select step.work_order_id, work_order.job_id, work_order.device_id, job.current_location_id
    into v_work_order, v_job, v_device, v_from_location
  from public.job_work_order_steps as step
  join public.job_work_orders as work_order on work_order.id = step.work_order_id
  join public.jobs as job on job.id = work_order.job_id
  where step.id = p_work_order_step_id and step.department = 'frame' and step.step_status = 'in_progress' and job.deleted_at is null
  for update of step, job;
  if v_job is null then raise exception 'This phone is no longer waiting in Frame.' using errcode = '22023'; end if;
  select entry.option_value into v_grade from public.entry_options as entry
  where entry.option_group = 'grade' and entry.is_active
    and lower(regexp_replace(btrim(entry.option_value), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(coalesce(p_final_grade, '')), '\s+', ' ', 'g'))
  order by entry.created_at desc limit 1;
  if v_grade is null then raise exception 'Select an active Final Grade.' using errcode = '22023'; end if;
  select step.id into v_final_step from public.job_work_order_steps as step
  where step.work_order_id = v_work_order and step.department = 'final_qc' and step.step_status = 'pending'
  order by step.step_order limit 1 for update;
  if v_final_step is null then raise exception 'The pending Final QC step for this Frame phone was not found.' using errcode = '22023'; end if;
  select inspection.id, inspection.final_battery_health, inspection.final_battery_health_unavailable into v_frame_inspection, v_final_battery, v_unavailable
  from public.final_qc_inspections as inspection
  where inspection.job_id = v_job and inspection.routed_to_frame = true
  order by inspection.inspected_at desc limit 1 for update;
  if v_frame_inspection is null then raise exception 'Final QC record is missing.' using errcode='22023'; end if;
  select device_platform into v_platform from public.devices where id=v_device and deleted_at is null for update;
  if not found then raise exception 'This device is unavailable.' using errcode='22023'; end if;
  perform greenloop_private.validate_mobile_battery(v_platform,v_final_battery,v_unavailable,true);
  select location.id into v_ready_location from public.locations as location where location.location_code = 'PRODUCTION' and location.is_active limit 1;
  if v_ready_location is null then raise exception 'Ready Stock location is not configured.' using errcode = '22023'; end if;
  update public.job_work_order_steps set step_status = 'completed', returned_at = now() where id = p_work_order_step_id;
  update public.job_work_order_steps set step_status = 'completed' where id = v_final_step;
  update public.job_work_orders set status = 'completed' where id = v_work_order;
  update public.final_qc_inspections set final_grade = v_grade where id = v_frame_inspection;
  update public.jobs set current_status = 'qc_passed', current_location_id = v_ready_location where id = v_job;
  update public.devices set current_status = 'qc_passed', current_location_id = v_ready_location where id = v_device;
  insert into public.device_location_history(device_id, job_id, from_location_id, to_location_id, movement_reason, moved_by)
  values (v_device, v_job, v_from_location, v_ready_location, concat_ws(' | ', 'Frame passed to Ready Stock with Final Grade ' || v_grade, nullif(btrim(p_notes), '')), v_actor);
  insert into public.device_events(device_id, job_id, event_type, event_title, event_data, actor_id)
  values (v_device, v_job, 'frame_passed_ready_stock', 'Frame passed and sent to Ready Stock', jsonb_build_object('frame_step_id', p_work_order_step_id, 'final_grade', v_grade, 'final_battery_health', v_final_battery), v_actor);
  return jsonb_build_object('completed', true, 'next_status', 'qc_passed', 'final_grade', v_grade);
end;
$$;

create or replace function public.record_frame_department_result_v3(
  p_work_order_step_id uuid, p_result text, p_final_grade text default null, p_notes text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid := auth.uid(); v_result text := lower(btrim(coalesce(p_result, ''))); v_job uuid; v_device uuid; v_output jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['frame_department']::text[]);
  if not public.is_active_staff() then raise exception 'Active staff access is required.' using errcode = '42501'; end if;
  if v_result not in ('pass', 'fail') then raise exception 'Select Pass or Fail.' using errcode = '22023'; end if;
  select work_order.job_id, work_order.device_id into v_job, v_device
  from public.job_work_order_steps as step join public.job_work_orders as work_order on work_order.id = step.work_order_id join public.jobs as job on job.id = work_order.job_id
  where step.id = p_work_order_step_id and step.department = 'frame' and step.step_status = 'in_progress' and job.deleted_at is null for update of step;
  if v_job is null then raise exception 'This phone is no longer waiting in Frame.' using errcode = '22023'; end if;
  insert into public.frame_department_results(work_order_step_id, job_id, device_id, result, notes, reviewed_by)
  values (p_work_order_step_id, v_job, v_device, v_result, nullif(btrim(coalesce(p_notes, '')), ''), v_actor);
  if v_result = 'pass' then
    v_output := public.complete_frame_to_ready_stock_with_grade_v2(p_work_order_step_id, p_final_grade, concat_ws(' | ', 'Frame Department Pass', nullif(btrim(coalesce(p_notes, '')), '')));
    return coalesce(v_output, '{}'::jsonb) || jsonb_build_object('result', 'pass');
  end if;
  update public.job_work_order_steps set rework_count = rework_count + 1 where id = p_work_order_step_id;
  insert into public.device_events(device_id, job_id, event_type, event_title, event_data, actor_id)
  values (v_device, v_job, 'frame_failed', 'Frame Department marked phone Fail', jsonb_build_object('frame_step_id', p_work_order_step_id, 'notes', nullif(btrim(coalesce(p_notes, '')), '')), v_actor);
  return jsonb_build_object('completed', false, 'result', 'fail', 'next_status', 'frame_pending');
end;
$$;

create or replace function public.ensure_ready_stock_frame_rework_cycle_v2(p_imei text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_job uuid; v_device uuid; v_work_order uuid; v_final_step uuid; v_battery smallint; v_attempt integer; v_platform text; v_unavailable boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['ready_stock']::text[]);
  if auth.uid() is not null and not public.has_role(array['super_admin','owner','manager','production','final_qc']::public.app_role_key[]) then raise exception 'You do not have permission to prepare Frame rework.' using errcode='42501'; end if;
  select job.id,job.device_id into v_job,v_device from public.jobs job join public.devices d on d.id=job.device_id where d.imei_1=regexp_replace(coalesce(p_imei,''),'\D','','g') and job.current_status='frame_pending' and job.deleted_at is null for update of job;
  if v_job is null then raise exception 'This phone is not waiting in Frame.' using errcode='22023'; end if;
  select id into v_work_order from public.job_work_orders where job_id=v_job for update;
  if v_work_order is null then raise exception 'The work-order history for this phone is missing.' using errcode='22023'; end if;
  select battery_health,device_platform,battery_health_unavailable into v_battery,v_platform,v_unavailable from public.devices where id=v_device for update;
  perform greenloop_private.validate_mobile_battery(v_platform,v_battery,v_unavailable,true);
  select id into v_final_step from public.job_work_order_steps where work_order_id=v_work_order and department='final_qc' for update;
  if v_final_step is null then insert into public.job_work_order_steps(work_order_id,step_order,department,step_status) values(v_work_order,(select coalesce(max(step_order),0)+10 from public.job_work_order_steps where work_order_id=v_work_order),'final_qc','pending') returning id into v_final_step;
  else update public.job_work_order_steps set step_status='pending' where id=v_final_step; end if;
  if not exists(select 1 from public.final_qc_inspections where job_id=v_job and routed_to_frame=true and final_grade is null) then
    select coalesce(max(attempt_number),0)+1 into v_attempt from public.final_qc_inspections where job_id=v_job;
    insert into public.final_qc_inspections(job_id,device_id,work_order_step_id,attempt_number,result,notes,inspected_by,final_grade,final_battery_health,routed_to_frame,final_battery_health_unavailable)
    values(v_job,v_device,v_final_step,v_attempt,'pass','Ready Stock rework routed directly to Frame',auth.uid(),null,v_battery,true,v_unavailable);
  end if;
end; $$;

create or replace function public.send_ready_stock_for_rework_atomic_v2(
  p_imei text,
  p_department text,
  p_customer_reason text default null,
  p_technician_id uuid default null
)
returns table (job_id uuid, destination text, rework_cycle integer)
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_department text := lower(btrim(coalesce(p_department, '')));
  v_result record;
begin
  if auth.uid() is null or not coalesce(public.has_page_edit_access('ready_stock'), false) then
    raise exception 'You do not have entry permission for Ready Stock.' using errcode = '42501';
  end if;
  if v_department not in ('laboratory', 'frame') then
    raise exception 'Select Laboratory or Frame Department.' using errcode = '22023';
  end if;
  if v_department = 'laboratory' and p_technician_id is null then
    raise exception 'Select an active Laboratory technician.' using errcode = '22023';
  end if;

  select routed.job_id, routed.destination, routed.rework_cycle into strict v_result
  from public.send_ready_stock_for_rework(p_imei, p_department, p_customer_reason) as routed;

  -- Do not catch helper failures: PostgreSQL rolls back the entire RPC statement,
  -- including routing, location changes, work-order changes, and history writes.
  if v_department = 'laboratory' then
    perform public.assign_ready_stock_rework_technician(p_imei, p_technician_id);
  else
    perform public.ensure_ready_stock_frame_rework_cycle_v2(p_imei);
  end if;

  return query select v_result.job_id, v_result.destination, v_result.rework_cycle;
end;
$function$;


do $$ declare routine record; begin
  for routine in select p.oid::regprocedure signature from pg_proc p where (p.pronamespace='public'::regnamespace and p.proname in ('receive_stock_batch_imei_with_plan_v2','complete_final_qc_with_final_grade_v2','route_final_qc_pass_to_frame_v3','complete_initial_qc_direct_to_frame_v2','complete_frame_to_ready_stock_with_grade_v2','record_frame_department_result_v3','ensure_ready_stock_frame_rework_cycle_v2','send_ready_stock_for_rework_atomic_v2')) or (p.pronamespace='greenloop_private'::regnamespace and p.proname in ('validate_mobile_identity','validate_mobile_battery','receive_mobile_stock_imei','mobile_device_metadata_guard')) loop
    execute format('revoke all on function %s from public,anon,authenticated',routine.signature);
    if routine.signature::text like 'greenloop_private.%' then continue; end if;
    execute format('grant execute on function %s to authenticated',routine.signature);
  end loop;
end; $$;

create table if not exists greenloop_private.mobile_device_installation(object_identity text primary key,object_kind text not null,definition_hash text not null);
revoke all on greenloop_private.mobile_device_installation from public,anon,authenticated;
create or replace function public.get_greenloop_mobile_device_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare m record; v_actual text;
begin
  if public.get_greenloop_stock_return_reset_version() is distinct from '20260926-stock-return-reset-1' then return null; end if;
  if (select count(*) from greenloop_private.mobile_device_installation)<>17 then return null; end if;
  for m in select * from greenloop_private.mobile_device_installation loop
    if m.object_kind='function' then
      if to_regprocedure(m.object_identity) is null then return null; end if;
      v_actual:=md5(pg_get_functiondef(to_regprocedure(m.object_identity)));
      if m.object_identity like 'greenloop_private.%' then
        if has_function_privilege('anon',m.object_identity,'execute') or has_function_privilege('authenticated',m.object_identity,'execute') then return null; end if;
      elsif m.object_identity not like 'public.get_greenloop_mobile_device_version%' then
        if has_function_privilege('anon',m.object_identity,'execute') or not has_function_privilege('authenticated',m.object_identity,'execute') then return null; end if;
      end if;
    elsif m.object_kind='trigger' then
      select md5(pg_get_triggerdef(t.oid)||t.tgenabled::text) into v_actual from pg_trigger t
      where t.tgrelid='public.devices'::regclass and t.tgname='mobile_device_metadata_guard';
    else
      select md5(pg_get_constraintdef(c.oid)||c.convalidated::text) into v_actual from pg_constraint c
      where c.conrelid=split_part(m.object_identity,':',1)::regclass and c.conname=split_part(m.object_identity,':',2);
    end if;
    if v_actual is distinct from m.definition_hash then return null; end if;
  end loop;
  if (select count(*) from information_schema.columns where table_schema='public' and
    ((table_name='devices' and column_name='device_platform' and data_type='text') or
     (table_name='devices' and column_name='battery_health_unavailable' and data_type='boolean' and is_nullable='NO') or
     (table_name='final_qc_inspections' and column_name='final_battery_health_unavailable' and data_type='boolean' and is_nullable='NO')))<>3 then return null; end if;
  if has_table_privilege('anon','greenloop_private.mobile_device_installation','select,insert,update,delete')
    or has_table_privilege('authenticated','greenloop_private.mobile_device_installation','select,insert,update,delete') then return null; end if;
  return '20261001-multi-brand-devices-1';
end; $$;
revoke all on function public.get_greenloop_mobile_device_version() from public,anon,authenticated;
grant execute on function public.get_greenloop_mobile_device_version() to anon,authenticated;
delete from greenloop_private.mobile_device_installation;
insert into greenloop_private.mobile_device_installation(object_identity,object_kind,definition_hash)
select n.nspname||'.'||p.proname||'('||oidvectortypes(p.proargtypes)||')','function',md5(pg_get_functiondef(p.oid))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace where
(n.nspname='public' and p.proname in ('receive_stock_batch_imei_with_plan_v2','complete_final_qc_with_final_grade_v2','route_final_qc_pass_to_frame_v3','complete_initial_qc_direct_to_frame_v2','complete_frame_to_ready_stock_with_grade_v2','record_frame_department_result_v3','ensure_ready_stock_frame_rework_cycle_v2','send_ready_stock_for_rework_atomic_v2','get_greenloop_mobile_device_version')) or
(n.nspname='greenloop_private' and p.proname in ('validate_mobile_identity','validate_mobile_battery','receive_mobile_stock_imei','mobile_device_metadata_guard'));
insert into greenloop_private.mobile_device_installation(object_identity,object_kind,definition_hash)
select n.nspname||'.'||t.relname||':'||c.conname,'constraint',md5(pg_get_constraintdef(c.oid)||c.convalidated::text)
from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
where n.nspname='public' and c.conname in ('devices_mobile_platform_check','devices_mobile_battery_availability_check','final_qc_mobile_battery_availability_check');
insert into greenloop_private.mobile_device_installation(object_identity,object_kind,definition_hash)
select 'public.devices:mobile_device_metadata_guard','trigger',md5(pg_get_triggerdef(t.oid)||t.tgenabled::text)
from pg_trigger t where t.tgrelid='public.devices'::regclass and t.tgname='mobile_device_metadata_guard';
do $$ begin
  if public.get_greenloop_mobile_device_version() is distinct from '20261001-multi-brand-devices-1' then
    raise exception 'Multi-brand database verification failed. No changes were installed.' using errcode='55000';
  end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_greenloop_mobile_device_version() as installed_mobile_device_version;
