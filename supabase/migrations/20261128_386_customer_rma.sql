-- Customer returns are a new custody/repair visit on the same physical phone.
begin;
set local lock_timeout='5s';

do $preflight$
begin
  if to_regprocedure('public.get_customer_rma_version()') is not null then
    if public.get_customer_rma_version() is distinct from '20261128-customer-rma-1' then
      raise exception 'The existing Customer RMA installation needs review.';
    end if;
  end if;
  if public.get_multiple_open_boxes_version() is distinct from '20261120-multiple-open-export-boxes-1'
    or public.get_box_recheck_imei_controls_version() is distinct from '20261125-box-recheck-imei-controls-1'
    or public.get_ready_stock_esim_version() is distinct from '20261125-ready-stock-esim-1' then
    raise exception 'The existing Box Entry, Box Recheck and Ready Stock readers are required.';
  end if;
end;
$preflight$;

create table if not exists greenloop_private.customer_rma_cases (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  device_id uuid not null,
  job_id uuid not null unique,
  original_item_id uuid unique,
  original_box_number text,
  original_export_at timestamptz,
  original_batch_id uuid,
  customer_id uuid,
  opening_stock boolean not null,
  reason text not null check (length(reason) between 2 and 1000),
  previous_reference text,
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null,
  reviewed_token text not null,
  check (opening_stock=(original_item_id is null))
);
alter table greenloop_private.customer_rma_cases enable row level security;
revoke all on greenloop_private.customer_rma_cases from public,anon,authenticated;
create index if not exists customer_rma_device_idx on greenloop_private.customer_rma_cases(device_id,recorded_at desc);
create index if not exists customer_rma_recorded_idx on greenloop_private.customer_rma_cases(recorded_at desc,id);

create or replace function greenloop_private.rma_require_intake(p_opening boolean,p_capability text)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $body$
begin
  perform greenloop_private.pf_cap('stock_received',p_capability);
  if p_opening is null or not coalesce(public.has_role(
    case when p_opening then array['owner','super_admin']::public.app_role_key[]
    else array['owner','super_admin','manager','receiving','rma']::public.app_role_key[] end),false) then
    raise exception 'This RMA action is not allowed for your account.' using errcode='42501';
  end if;
end;
$body$;

create or replace function greenloop_private.rma_intake_context(p_imei text,p_opening boolean)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
declare
  phone record;
  original record;
  source_batch uuid;
begin
  if p_imei is null or p_imei !~ '^[0-9]{15}$' then
    raise exception 'Enter a valid 15-digit IMEI.' using errcode='22023';
  end if;
  perform greenloop_private.reject_secondary_imei(p_imei);
  select d.id device_id,d.imei_1,d.model,d.storage_gb,d.current_status device_status,d.current_location_id device_location,
    j.id job_id,j.job_number,j.receiving_batch_id,j.supplier_id,j.supplier_grade,j.current_status,j.current_location_id,
    j.ownership_type,j.customer_id,b.batch_number,b.receiving_source,sp.company_name supplier
  into phone
  from public.devices d
  join lateral (
    select j.* from public.jobs j where j.device_id=d.id and j.deleted_at is null
    order by j.received_at desc nulls last,j.created_at desc,j.id limit 1
  ) j on true
  left join public.receiving_batches b on b.id=j.receiving_batch_id
  left join public.suppliers sp on sp.id=coalesce(j.supplier_id,b.supplier_id)
  where d.imei_1=p_imei and d.deleted_at is null;
  if not found then raise exception 'No active phone record matches this IMEI.' using errcode='22023'; end if;
  if not greenloop_private.company_job_available(phone.job_id) or exists (
    select 1 from public.supplier_returns r
    where r.archived_at is null and r.status in ('requested','approved','returned')
      and (r.job_id=phone.job_id or (r.job_id is null and r.device_id=phone.device_id))
  ) then
    raise exception 'This phone is in another custody or return workflow.' using errcode='22023';
  end if;

  if p_opening then
    if coalesce(lower(btrim(phone.supplier)),'') <> 'opening stock'
       and coalesce(lower(btrim(phone.receiving_source)),'') <> 'opening stock' then
      raise exception 'Use this option for a phone received under Opening Stock.' using errcode='22023';
    end if;
    if phone.current_status in ('shipped','returned_to_customer','returned_to_supplier','rma_completed','scrap')
      or exists(select 1 from public.export_box_items i where i.device_id=phone.device_id) then
      raise exception 'This phone is not an unexported Opening Stock phone.' using errcode='22023';
    end if;
    if exists(select 1 from greenloop_private.customer_rma_cases c where c.device_id=phone.device_id) then
      raise exception 'This phone already has an RMA record.' using errcode='22023';
    end if;
    return jsonb_build_object('device_id',phone.device_id,'job_id',phone.job_id,'job_number',phone.job_number,
      'imei',phone.imei_1,'model',phone.model,'storage_gb',phone.storage_gb,'current_stage',phone.current_status,
      'original_batch_id',phone.receiving_batch_id,'original_box_number',null,'original_export_at',null,
      'context_token',md5(jsonb_build_array(phone.device_id,phone.job_id,phone.current_status,phone.current_location_id,
           phone.receiving_batch_id,true)::text));
  end if;

  select i.id item_id,b.id box_id,b.box_number,w.revision,w.customer_id,w.customer_code,w.customer_name,
    coalesce(w.verified_at,b.closed_at,b.opened_at) exported_at
  into original
  from public.export_box_items i join public.export_boxes b on b.id=i.box_id
  join greenloop_private.box_workflow w on w.box_id=b.id
  where i.device_id=phone.device_id and i.job_id=phone.job_id and w.state in ('exported','legacy');
  if not found or phone.current_status<>'shipped' or phone.device_status<>'shipped' then
    raise exception 'This IMEI is not currently in an exported box.' using errcode='22023';
  end if;
  if exists(select 1 from greenloop_private.customer_rma_cases c where c.original_item_id=original.item_id) then
    raise exception 'This export already has a received RMA return.' using errcode='22023';
  end if;
  if exists (
    select 1 from public.jobs j where j.device_id=phone.device_id and j.id<>phone.job_id and j.deleted_at is null
      and j.current_status not in ('shipped','returned_to_customer','returned_to_supplier','rma_completed','scrap')
  ) then
    raise exception 'This phone has another open job. Review its history first.' using errcode='22023';
  end if;
  select c.original_batch_id into source_batch from greenloop_private.customer_rma_cases c where c.job_id=phone.job_id;
  return jsonb_build_object('device_id',phone.device_id,'job_id',phone.job_id,'job_number',phone.job_number,
    'imei',phone.imei_1,'model',phone.model,'storage_gb',phone.storage_gb,'current_stage',phone.current_status,
    'original_batch_id',coalesce(source_batch,phone.receiving_batch_id),'original_item_id',original.item_id,
    'original_box_number',original.box_number,'original_export_at',original.exported_at,
    'customer_id',coalesce(original.customer_id,phone.customer_id),'customer_code',original.customer_code,
    'customer_name',case when public.get_my_partner_name_access() then original.customer_name end,
    'context_token',md5(jsonb_build_array(phone.device_id,phone.job_id,original.item_id,original.revision,
      original.customer_id,original.exported_at,phone.receiving_batch_id,false)::text));
end;
$body$;

create or replace function public.get_rma_intake_v1(p_imei text,p_opening_stock boolean)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
begin
  perform greenloop_private.rma_require_intake(p_opening_stock,'view');
  return greenloop_private.rma_intake_context(btrim(p_imei),p_opening_stock)
    - 'device_id' - 'job_id' - 'original_item_id' - 'original_batch_id' - 'customer_id';
end;
$body$;

create or replace function public.receive_customer_rma_v1(p_imei text,p_opening_stock boolean,p_context_token text,
  p_reason text,p_previous_reference text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
declare
  phone jsonb;
  previous greenloop_private.customer_rma_cases%rowtype;
  prior_job public.jobs%rowtype;
  new_job uuid;
  target_device uuid;
  intake_location uuid;
  customer uuid;
  reason text:=btrim(coalesce(p_reason,''));
  reference text:=nullif(btrim(p_previous_reference),'');
  imei text:=btrim(p_imei);
  case_id uuid;
begin
  perform greenloop_private.rma_require_intake(p_opening_stock,'entry');
  if p_request_id is null or p_context_token is null or p_context_token !~ '^[a-f0-9]{32}$'
    or imei is null or imei !~ '^[0-9]{15}$'
    or length(reason) not between 2 and 1000 or length(reference)>120
    or (reference is not null and not p_opening_stock) then
    raise exception 'Review the IMEI and enter an RMA return reason.' using errcode='22023';
  end if;
  -- Serialize with packing, Accounts exports and exported box rechecks.
  perform pg_advisory_xact_lock(16320261010);
  select * into previous from greenloop_private.customer_rma_cases where request_id=p_request_id;
  if found then
    if previous.recorded_by is distinct from auth.uid() or previous.reviewed_token<>p_context_token
      or previous.reason<>reason or previous.previous_reference is distinct from reference
      or previous.opening_stock<>p_opening_stock
      or not exists(select 1 from public.devices d where d.id=previous.device_id and d.imei_1=imei) then
      raise exception 'This RMA request already belongs to another save.' using errcode='22023';
    end if;
    return jsonb_build_object('id',previous.id,'replayed',true);
  end if;

  phone:=greenloop_private.rma_intake_context(imei,p_opening_stock);
  target_device:=(phone->>'device_id')::uuid;
  select * into prior_job from public.jobs where id=(phone->>'job_id')::uuid for update;
  perform 1 from public.devices where id=target_device and deleted_at is null for update;
  if not found then raise exception 'This phone changed. Review the IMEI again.' using errcode='40001'; end if;
  phone:=greenloop_private.rma_intake_context(imei,p_opening_stock);
  if phone->>'context_token' is distinct from p_context_token then
    raise exception 'The phone changed since review. Check it again before saving.' using errcode='40001';
  end if;
  new_job:=prior_job.id;
  if not p_opening_stock then
    select id into intake_location from public.locations where location_code='INITIAL-QC' and is_active;
    if intake_location is null then raise exception 'Initial QC location is not configured.'; end if;
    customer:=(phone->>'customer_id')::uuid;
    -- The original intake batch remains linked through the RMA case. A repair
    -- visit does not consume a second unit from that purchase receipt.
    insert into public.jobs(device_id,job_type,ownership_type,customer_id,supplier_id,supplier_grade,
      receiving_source,purchase_cost,current_location_id,current_status,notes,received_by,created_by)
    values(target_device,'rma',case when customer is null then 'company_owned'::public.ownership_type
      else 'customer_owned'::public.ownership_type end,customer,prior_job.supplier_id,prior_job.supplier_grade,
      'RMA Received',0,intake_location,'initial_qc_pending',reason,auth.uid(),auth.uid())
    returning id into new_job;
  end if;

  insert into greenloop_private.customer_rma_cases(request_id,device_id,job_id,original_item_id,original_box_number,
    original_export_at,original_batch_id,customer_id,opening_stock,reason,previous_reference,recorded_by,reviewed_token)
  values(p_request_id,target_device,new_job,(phone->>'original_item_id')::uuid,
    phone->>'original_box_number',(phone->>'original_export_at')::timestamptz,
    (phone->>'original_batch_id')::uuid,customer,p_opening_stock,reason,reference,auth.uid(),p_context_token)
  returning id into case_id;

  if not p_opening_stock then
    update public.devices set current_status='initial_qc_pending',current_location_id=intake_location,
      current_owner_type=case when customer is null then 'company_owned'::public.ownership_type
        else 'customer_owned'::public.ownership_type end,
      current_owner_customer_id=customer where id=target_device;
    perform greenloop_private.begin_capability('receive_customer_rma_v1','{}');
    insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by)
      values(target_device,new_job,prior_job.current_location_id,intake_location,'RMA received for Initial QC',
        phone->>'original_box_number',auth.uid());
    perform greenloop_private.end_capability();
  end if;

  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
  values(target_device,new_job,case when p_opening_stock then 'opening_stock_marked_rma' else 'customer_rma_received' end,
    case when p_opening_stock then 'Opening Stock marked as RMA' else 'RMA received for Initial QC' end,
    jsonb_build_object('rma_id',case_id,'original_box_number',phone->>'original_box_number',
      'original_export_at',phone->>'original_export_at','original_job_id',prior_job.id,'reason',reason,
      'previous_reference',reference,'notes',concat_ws(' · ',reason,phone->>'original_box_number',reference)),auth.uid());
  return jsonb_build_object('id',case_id,'replayed',false);
end;
$body$;

create or replace function greenloop_private.rma_ready_after_qc(p_job uuid,p_opening boolean,p_recorded timestamptz)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $body$
  select p_opening or exists (
    select 1 from public.final_qc_inspections q
    where q.job_id=p_job and q.result='pass' and q.inspected_at>=p_recorded
  );
$body$;

-- Keep legacy devices one-box-only. Only a documented return with a new job
-- can have an additional item, and the per-job uniqueness remains enforced.
create or replace function greenloop_private.rma_blocking_box(p_device uuid,p_imei text)
returns text language sql stable security definer set search_path=pg_catalog,public as $body$
  select b.box_number from public.export_box_items i join public.export_boxes b on b.id=i.box_id
  left join greenloop_private.box_workflow w on w.box_id=b.id
  where (i.device_id=p_device or i.imei=p_imei) and not (
    coalesce(w.state in ('exported','legacy'),false)
    and i.device_id=p_device
    and exists (
      select 1 from greenloop_private.customer_rma_cases c join public.jobs j on j.id=c.job_id
      where c.device_id=p_device and c.original_item_id is not null
        and j.deleted_at is null and j.current_status in (
          'qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
        and greenloop_private.rma_ready_after_qc(c.job_id,c.opening_stock,c.recorded_at)
        and c.job_id is distinct from i.job_id
    )
  )
  order by i.scanned_at desc nulls last,i.id limit 1;
$body$;

create or replace function greenloop_private.rma_box_item_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $body$
declare rma greenloop_private.customer_rma_cases%rowtype; blocking_box text;
begin
  if tg_op in ('DELETE','UPDATE') then
    if tg_op='UPDATE' and (old.device_id,old.job_id,old.box_id,old.id)
      is not distinct from (new.device_id,new.job_id,new.box_id,new.id) then return new; end if;
    if exists(select 1 from greenloop_private.customer_rma_cases c where c.original_item_id=old.id) then
      raise exception 'This export line is linked to a received RMA. Its original box record is retained.' using errcode='22023';
    end if;
    if tg_op='DELETE' then return old; end if;
  end if;
  select * into rma from greenloop_private.customer_rma_cases c where c.job_id=new.job_id;
  if rma.id is not null and (rma.device_id<>new.device_id
    or not greenloop_private.rma_ready_after_qc(rma.job_id,rma.opening_stock,rma.recorded_at)) then
    raise exception 'This RMA phone must pass Final QC before packing.' using errcode='22023';
  end if;
  if tg_op='INSERT' then
    perform 1 from public.devices d where d.id=new.device_id for update;
    blocking_box:=greenloop_private.rma_blocking_box(new.device_id,new.imei);
    if blocking_box is not null then
      raise exception 'This IMEI is already in %.',blocking_box using errcode='22023';
    end if;
    if rma.id is null and exists(select 1 from public.export_box_items i where i.device_id=new.device_id) then
      raise exception 'A received RMA record is required before re-export.' using errcode='22023';
    end if;
  elsif exists(select 1 from public.export_box_items i where i.device_id=new.device_id and i.id<>old.id) then
    raise exception 'Move this phone through the RMA and Box Entry workflow.' using errcode='22023';
  end if;
  return new;
end;
$body$;

create or replace function greenloop_private.rma_box_export_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $body$
begin
  if old.state in ('exported','legacy') and new.state is distinct from old.state and exists (
    select 1 from public.export_box_items i join greenloop_private.customer_rma_cases c on c.original_item_id=i.id
    where i.box_id=old.box_id
  ) then
    raise exception 'This export is linked to a received RMA. Its original export must remain in history.' using errcode='22023';
  end if;
  if new.state='exported' and new.state is distinct from old.state then
    if exists (
      select 1 from public.export_box_items i join greenloop_private.customer_rma_cases c on c.job_id=i.job_id
      where i.box_id=new.box_id and c.customer_id is not null and c.customer_id is distinct from new.customer_id
    ) then
      raise exception 'Verify the RMA box for the original export customer.' using errcode='22023';
    end if;
    insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
    select i.device_id,i.job_id,'customer_rma_reexported','RMA re-export verified',
      jsonb_build_object('rma_id',c.id,'box_number',b.box_number,'original_box_number',c.original_box_number,
        'notes',concat_ws(' · ',c.original_box_number,b.box_number)),auth.uid()
    from public.export_box_items i join public.export_boxes b on b.id=i.box_id
    join greenloop_private.customer_rma_cases c on c.job_id=i.job_id where i.box_id=new.box_id;
  end if;
  return new;
end;
$body$;

-- Preserve the indexed device lookup before replacing the one-per-device key.
create index if not exists export_box_items_rma_device_idx on public.export_box_items(device_id);
drop trigger if exists customer_rma_box_item_guard on public.export_box_items;
create trigger customer_rma_box_item_guard before insert or delete or update of device_id,job_id,box_id,id
  on public.export_box_items for each row execute function greenloop_private.rma_box_item_guard();
alter table public.export_box_items drop constraint if exists export_box_items_device_id_key;
drop trigger if exists customer_rma_box_export_guard on greenloop_private.box_workflow;
create trigger customer_rma_box_export_guard before update of state on greenloop_private.box_workflow
  for each row execute function greenloop_private.rma_box_export_guard();

-- Modern RMA jobs require the normal Final QC outing. Older phones that are
-- already Ready Stock can be marked without undoing their approved work.
create or replace function greenloop_private.rma_direct_ready_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $body$
begin
  if exists(select 1 from greenloop_private.customer_rma_cases c where c.job_id=new.job_id) then
    raise exception 'Send this RMA phone through Final QC before it can enter RMA Stock.' using errcode='22023';
  end if;
  return new;
end;
$body$;
drop trigger if exists customer_rma_direct_ready_guard on greenloop_private.qc_direct_ready;
create trigger customer_rma_direct_ready_guard before insert on greenloop_private.qc_direct_ready
  for each row execute function greenloop_private.rma_direct_ready_guard();

create or replace function public.get_rma_ready_report_v1(p_from date,p_to date,p_offset integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
declare result jsonb; names boolean;
begin
  perform greenloop_private.pf_cap('ready_stock','view');
  if p_offset is null or p_offset<0 or p_offset%50<>0 or p_from>p_to then
    raise exception 'Choose a valid Ready Date range.' using errcode='22023';
  end if;
  names:=coalesce(public.get_my_partner_name_access(),false);
  with selected as materialized (
    select d.model,d.storage_gb,ready.final_grade,r.original_box_number,r.previous_reference,
      customer.customer_code,case when names then customer.company_name end customer_name,
      (ready.passed_at at time zone 'Asia/Dubai')::date ready_date
    from greenloop_private.rsbe_current(null,null) ready
    join greenloop_private.customer_rma_cases r on r.job_id=ready.job_id and r.device_id=ready.device_id
    join public.devices d on d.id=ready.device_id
    left join public.customers customer on customer.id=r.customer_id
    where greenloop_private.rma_ready_after_qc(r.job_id,r.opening_stock,r.recorded_at)
      and (p_from is null or (ready.passed_at at time zone 'Asia/Dubai')::date>=p_from)
      and (p_to is null or (ready.passed_at at time zone 'Asia/Dubai')::date<=p_to)
  ), groups as materialized (
    select model,storage_gb,final_grade,original_box_number,previous_reference,
      customer_code,customer_name,ready_date,count(*) quantity
    from selected group by model,storage_gb,final_grade,original_box_number,previous_reference,
      customer_code,customer_name,ready_date
  ), page as (
    select * from groups order by ready_date desc,customer_code,model,storage_gb,final_grade,original_box_number,
      previous_reference offset p_offset limit 50
  )
  select jsonb_build_object('phones',(select count(*) from selected),
    'total',(select count(*) from groups),'rows',coalesce((select jsonb_agg(to_jsonb(page)
      order by ready_date desc,customer_code,model,storage_gb,final_grade,original_box_number,previous_reference) from page),'[]'))
    into result;
  return result;
end;
$body$;

create or replace function public.get_rma_cases_v1(p_from date,p_to date,p_offset integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
declare result jsonb; names boolean;
begin
  perform greenloop_private.rma_require_intake(false,'view');
  if p_offset is null or p_offset<0 or p_offset%50<>0 or p_from>p_to then
    raise exception 'Choose a valid RMA Received Date range.' using errcode='22023';
  end if;
  names:=coalesce(public.get_my_partner_name_access(),false);
  with cases as materialized (
    select r.id,r.opening_stock,r.recorded_at,r.original_box_number,r.original_export_at,r.previous_reference,r.reason,
      d.imei_1 imei,d.model,d.storage_gb,j.current_status::text stage,
      coalesce(customer.customer_code,w.customer_code) customer_code,
      case when names then coalesce(customer.company_name,w.customer_name) end customer_name,
      actor.full_name received_by,
      case when w.state='exported' then b.box_number end reexport_box,
      case when w.state='exported' then w.verified_at end reexported_at,
      case when w.state='exported' then 'Re-exported'
        when j.deleted_at is not null or d.deleted_at is not null then 'Record unavailable'
        when ready.job_id is not null and greenloop_private.rma_ready_after_qc(r.job_id,r.opening_stock,r.recorded_at)
          then 'RMA Ready'
        when j.current_status in ('initial_qc_pending','received') then 'Received'
        else 'In Repair' end status
    from greenloop_private.customer_rma_cases r
    join public.jobs j on j.id=r.job_id join public.devices d on d.id=r.device_id
    left join public.customers customer on customer.id=r.customer_id
    left join public.user_profiles actor on actor.id=r.recorded_by
    left join public.export_box_items i on i.job_id=r.job_id
    left join greenloop_private.box_workflow w on w.box_id=i.box_id
    left join public.export_boxes b on b.id=i.box_id
    left join greenloop_private.rsbe_current(null,null) ready on ready.job_id=r.job_id
    where (p_from is null or (r.recorded_at at time zone 'Asia/Dubai')::date>=p_from)
      and (p_to is null or (r.recorded_at at time zone 'Asia/Dubai')::date<=p_to)
  ), page as (
    select * from cases order by recorded_at desc,id offset p_offset limit 50
  )
  select jsonb_build_object('total',count(*),'in_repair',count(*) filter(where status='In Repair'),
    'ready',count(*) filter(where status='RMA Ready'),'reexported',count(*) filter(where status='Re-exported'),
    'pending',count(*) filter(where status in ('Received','In Repair','RMA Ready')),
    'rows',coalesce((select jsonb_agg(to_jsonb(page) order by recorded_at desc,id) from page),'[]'))
  into result from cases;
  return result;
end;
$body$;

revoke all on function greenloop_private.rma_require_intake(boolean,text),greenloop_private.rma_intake_context(text,boolean),
  greenloop_private.rma_ready_after_qc(uuid,boolean,timestamptz),greenloop_private.rma_blocking_box(uuid,text),
  greenloop_private.rma_box_item_guard(),greenloop_private.rma_box_export_guard(),greenloop_private.rma_direct_ready_guard()
  from public,anon,authenticated;
revoke all on function public.get_rma_intake_v1(text,boolean),public.receive_customer_rma_v1(text,boolean,text,text,text,uuid),
  public.get_rma_ready_report_v1(date,date,integer),public.get_rma_cases_v1(date,date,integer) from public,anon,authenticated;
grant execute on function public.get_rma_intake_v1(text,boolean),public.receive_customer_rma_v1(text,boolean,text,text,text,uuid),
  public.get_rma_ready_report_v1(date,date,integer),public.get_rma_cases_v1(date,date,integer) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_rma_intake_v1','{"page":"stock_received","capability":"view","read":true}'),
  ('receive_customer_rma_v1','{"page":"stock_received","capability":"entry"}'),
  ('get_rma_cases_v1','{"page":"stock_received","capability":"view","read":true}'),
  ('get_rma_ready_report_v1','{"page":"ready_stock","capability":"view","read":true}')
on conflict (rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(
  select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r
) where identity='rules';
-- Retain existing scanner locks, revision checks, role checks and page response.
-- Replace only the duplicate check and add the new subset to the existing card read.
do $patch$
declare
  target record;
  receipt record;
  original text;
  rewritten text;
  previous_hash text;
  current_hash text;
begin
  for target in select * from (values
    ('greenloop_private.scan_export_box_draft(uuid,integer,text[])'::regprocedure,
      $old$select b.box_number into existing_box
      from public.devices d join public.export_box_items i on i.device_id=d.id
      join public.export_boxes b on b.id=i.box_id where d.imei_1=candidate;$old$,
      $new$select greenloop_private.rma_blocking_box(d.id,candidate) into existing_box
      from public.devices d where d.imei_1=candidate;$new$),
    ((select to_regprocedure(implementation) from greenloop_private.office_routines
      where to_regprocedure(identity)=to_regprocedure('public.add_box_recheck_imei_v1(uuid,integer,text)')),
      $old$select b.box_number into existing_box from public.export_box_items i
 join public.export_boxes b on b.id=i.box_id
 where i.device_id in (select id from public.devices where imei_1=p_imei and deleted_at is null)
    or i.imei=p_imei
 order by (i.imei=p_imei) desc,i.id limit 1;$old$,
      $new$select greenloop_private.rma_blocking_box(
   (select d.id from public.devices d where d.imei_1=p_imei and d.deleted_at is null),p_imei)
 into existing_box;$new$),
    ('greenloop_private.box_source_changed()'::regprocedure,
      $old$where (tg_table_name='devices' and i.device_id=new.id) or (tg_table_name='jobs' and i.job_id=new.id)
 or (tg_table_name='receiving_batches' and i.job_id in(select id from public.jobs where receiving_batch_id=new.id)) loop$old$,
      $new$where ((tg_table_name='devices' and i.device_id=new.id) or (tg_table_name='jobs' and i.job_id=new.id)
 or (tg_table_name='receiving_batches' and i.job_id in(select id from public.jobs where receiving_batch_id=new.id)))
 and not (w.state in ('exported','legacy') and exists(
   select 1 from public.export_box_items original
    join greenloop_private.customer_rma_cases c on c.original_item_id=original.id
    where original.box_id=b.id
 )) loop$new$),
    ('public.get_ready_stock_esim_v1(text,jsonb,integer,boolean)'::regprocedure,
      $old$'esim_count',(select count(*) from ready where esim),$old$,
      $new$'esim_count',(select count(*) from ready where esim),
    'rma_count',(select count(*) from ready r join greenloop_private.customer_rma_cases c
      on c.job_id=r.job_id and c.device_id=r.device_id
      where greenloop_private.rma_ready_after_qc(c.job_id,c.opening_stock,c.recorded_at)),$new$)
  ) as edits(fn,anchor,replacement) loop
    if target.fn is null then raise exception 'Install the existing Box Recheck and Ready Stock updates first.'; end if;
    target.anchor:=replace(target.anchor,chr(13),'');
    target.replacement:=replace(target.replacement,chr(13),'');
    original:=pg_get_functiondef(target.fn);
    previous_hash:=md5(original);
    original:=replace(original,chr(13),'');
    if strpos(original,target.replacement)>0 then continue; end if;
    if (length(original)-length(replace(original,target.anchor,'')))/length(target.anchor)<>1 then
      raise exception 'RMA could not identify the existing definition for %.',target.fn;
    end if;
    rewritten:=replace(original,target.anchor,target.replacement);
    execute rewritten;
    current_hash:=md5(pg_get_functiondef(target.fn));
    update greenloop_private.office_routines set original_hash=current_hash
      where to_regprocedure(implementation)=target.fn and original_hash=previous_hash;
    update greenloop_private.office_routines set wrapped_hash=current_hash
      where to_regprocedure(identity)=target.fn and wrapped_hash=previous_hash;
    update greenloop_private.capability_routines set original_hash=current_hash
      where to_regprocedure(implementation)=target.fn and original_hash=previous_hash;
    update greenloop_private.capability_routines set wrapped_hash=current_hash
      where to_regprocedure(identity)=target.fn and wrapped_hash=previous_hash;
    for receipt in select c.oid::regclass name from pg_class c
      where relnamespace='greenloop_private'::regnamespace and relkind='r' and relname like '%installation'
        and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='identity' and a.atttypid='text'::regtype)
        and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='hash' and a.atttypid='text'::regtype)
    loop
      execute format('update %s set hash=$1 where hash=$2 and to_regprocedure(identity)=$3',receipt.name)
        using current_hash,previous_hash,target.fn;
    end loop;
  end loop;
end;
$patch$;

create table if not exists greenloop_private.customer_rma_installation (
  identity text primary key,hash text not null
);
alter table greenloop_private.customer_rma_installation enable row level security;
revoke all on greenloop_private.customer_rma_installation from public,anon,authenticated;

create or replace function public.get_customer_rma_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $body$
  select case when (
      select count(*)=15 and bool_and(coalesce(i.hash=md5(pg_get_functiondef(to_regprocedure(i.identity))),false))
      from greenloop_private.customer_rma_installation i
    ) and not exists(
      select 1 from pg_constraint where conrelid='public.export_box_items'::regclass
        and conname='export_box_items_device_id_key'
    ) and exists (
      select 1 from pg_constraint where conrelid='public.export_box_items'::regclass and contype='u'
        and conkey=array[(select attnum from pg_attribute where attrelid='public.export_box_items'::regclass and attname='job_id')]
    ) and (
      select count(*)=3 from pg_trigger
      where tgenabled='O' and (
        (tgname='customer_rma_box_item_guard' and tgrelid='public.export_box_items'::regclass
          and tgfoid='greenloop_private.rma_box_item_guard()'::regprocedure)
        or (tgname='customer_rma_box_export_guard' and tgrelid='greenloop_private.box_workflow'::regclass
          and tgfoid='greenloop_private.rma_box_export_guard()'::regprocedure)
        or (tgname='customer_rma_direct_ready_guard' and tgrelid='greenloop_private.qc_direct_ready'::regclass
          and tgfoid='greenloop_private.rma_direct_ready_guard()'::regprocedure)
      )
    ) and (
      select relrowsecurity from pg_class where oid='greenloop_private.customer_rma_cases'::regclass
    ) and not has_table_privilege('anon','greenloop_private.customer_rma_cases','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and not has_table_privilege('authenticated','greenloop_private.customer_rma_cases','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and not exists(
      select 1 from greenloop_private.customer_rma_installation i
      where i.identity like 'greenloop_private.%' and (
        has_function_privilege('anon',to_regprocedure(i.identity),'execute')
        or has_function_privilege('authenticated',to_regprocedure(i.identity),'execute'))
    ) then '20261128-customer-rma-1' end;
$body$;
revoke all on function public.get_customer_rma_version() from public,anon,authenticated;
grant execute on function public.get_customer_rma_version() to anon,authenticated;

insert into greenloop_private.customer_rma_installation(identity,hash)
select identity,md5(pg_get_functiondef(to_regprocedure(identity)))
from unnest(array[
  'greenloop_private.rma_require_intake(boolean,text)','greenloop_private.rma_intake_context(text,boolean)',
  'greenloop_private.rma_ready_after_qc(uuid,boolean,timestamptz)','greenloop_private.rma_blocking_box(uuid,text)',
  'greenloop_private.rma_box_item_guard()','greenloop_private.rma_box_export_guard()','greenloop_private.rma_direct_ready_guard()',
  'public.get_rma_intake_v1(text,boolean)','public.receive_customer_rma_v1(text,boolean,text,text,text,uuid)',
  'public.get_rma_ready_report_v1(date,date,integer)','public.get_rma_cases_v1(date,date,integer)',
  'greenloop_private.box_source_changed()',
  'greenloop_private.scan_export_box_draft(uuid,integer,text[])','public.get_ready_stock_esim_v1(text,jsonb,integer,boolean)',
  (select implementation from greenloop_private.office_routines where
    to_regprocedure(identity)='public.add_box_recheck_imei_v1(uuid,integer,text)'::regprocedure)
]) r(identity)
on conflict(identity) do update set hash=excluded.hash;

do $check$
begin
  if public.get_customer_rma_version() is distinct from '20261128-customer-rma-1' then
    raise exception 'Customer RMA installation could not be verified.';
  end if;
end;
$check$;
notify pgrst,'reload schema';
commit;
select public.get_customer_rma_version() as installed_customer_rma_version;
