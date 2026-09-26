-- Simple Stock Return: one authorized, atomic final return with permanent audit.
-- Existing migration 142 and 143 functions and integrity manifests are unchanged.
begin;
do $$ begin
  if public.get_greenloop_stock_return_page_version() is distinct from '20260926-stock-return-page-1' then
    raise exception 'Install and verify the Stock Return page database update first.' using errcode='55000';
  end if;
end; $$;

create table if not exists greenloop_private.simple_stock_return_groups (
  id uuid primary key,
  actor_id uuid not null,
  idempotency_key uuid not null,
  command jsonb not null,
  receipt_snapshot jsonb not null,
  response jsonb not null,
  returned_at timestamptz not null default now(),
  unique(actor_id,idempotency_key)
);
revoke all on greenloop_private.simple_stock_return_groups from public,anon,authenticated;
create or replace function greenloop_private.simple_stock_return_immutable()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin raise exception 'Stock Return summaries and audit history are permanent.' using errcode='55000'; end; $$;
drop trigger if exists simple_stock_return_immutable on greenloop_private.simple_stock_return_groups;
create trigger simple_stock_return_immutable before update or delete on greenloop_private.simple_stock_return_groups
for each row execute function greenloop_private.simple_stock_return_immutable();

create or replace function greenloop_private.simple_stock_return_view_access()
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
select auth.uid() is not null and coalesce(public.is_active_staff(),false) and (
  public.has_page_access('reports') or greenloop_private.supplier_return_access('supplier_returns')
  or greenloop_private.supplier_return_access('supplier_return_approval')
  or greenloop_private.supplier_return_access('supplier_return_handover'));
$$;

create or replace function greenloop_private.simple_stock_receipt(p_batch_id uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
select jsonb_build_object(
  'batch_id',b.id,'batch_number',b.batch_number,'supplier_id',s.id,'supplier_code',s.supplier_code,
  'supplier_name',case when public.get_my_partner_name_access() then s.company_name else null end,
  'received_at',b.received_at,'invoice_number',b.invoice_number,'received_quantity',b.planned_quantity,
  'returned_quantity',coalesce((x.data->>'returned_quantity')::integer,0),
  'remaining_unentered',coalesce((x.data->>'remaining_quantity')::integer,0),
  'unallocated_return_quantity',(select count(*)::integer from public.supplier_returns r
    where r.batch_id=b.id and r.device_id is null and r.plan_line_id is null and r.archived_at is null and r.status in ('requested','approved','returned')),
  'model_options',coalesce((select jsonb_agg(to_jsonb(m) order by m.model,m.storage_gb) from (
    select distinct p.model,p.storage_gb from public.stock_batch_plan_lines p where p.receiving_batch_id=b.id and p.model is not null
    union select distinct d.model,d.storage_gb from public.jobs j join public.devices d on d.id=j.device_id
      where j.receiving_batch_id=b.id and j.deleted_at is null and d.deleted_at is null and d.model is not null
  ) m),'[]'::jsonb)
)
from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id
cross join lateral(select greenloop_private.supplier_return_batch(b.id) data) x
where b.id=p_batch_id and b.planned_quantity is not null;
$$;

create or replace function public.get_simple_stock_return_context()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not greenloop_private.simple_stock_return_view_access() then raise exception 'Stock Return view permission is required.' using errcode='42501'; end if;
  return jsonb_build_object('permissions',jsonb_build_object('can_return',greenloop_private.supplier_return_access('supplier_returns',true)),
    'receipts',coalesce((select jsonb_agg(greenloop_private.simple_stock_receipt(b.id) order by b.received_at desc,b.id)
      from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id
      where b.planned_quantity is not null and s.deleted_at is null),'[]'::jsonb));
end; $$;

create or replace function public.get_simple_stock_return_receipt_totals(p_batch_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not (greenloop_private.simple_stock_return_view_access() or
    (auth.uid() is not null and coalesce(public.is_active_staff(),false) and public.has_page_access('imei_entry'))) then
    raise exception 'IMEI Entry or Stock Return report permission is required.' using errcode='42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'supplier_id',b.supplier_id,
    'received_at',b.received_at,'received_quantity',b.planned_quantity,'returned_quantity',x.data->'returned_quantity',
    'remaining_unentered',x.data->'remaining_unentered','unallocated_return_quantity',x.data->'unallocated_return_quantity') order by b.received_at desc,b.id)
    from public.receiving_batches b cross join lateral(select greenloop_private.simple_stock_receipt(b.id) data) x
    where b.planned_quantity is not null and (p_batch_ids is null or b.id=any(p_batch_ids))),'[]'::jsonb);
end; $$;

-- Unknown scanned IMEIs may be returned before IMEI Entry. Preserve their
-- physical identity, and prevent a later intake from silently reusing it.
create unique index if not exists simple_stock_return_active_imei on public.supplier_returns(imei_1)
where archived_at is null and imei_1 is not null and status in ('requested','approved','returned');
create or replace function greenloop_private.simple_stock_return_imei_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_imei text;
begin
  for v_imei in select distinct x from unnest(array[new.imei_1::text,new.imei_2::text]) x where x is not null order by x loop
    perform pg_advisory_xact_lock(hashtextextended('greenloop-return-imei:'||v_imei,0));
    if exists(select 1 from public.supplier_returns r where r.imei_1=v_imei and r.device_id is null
      and r.archived_at is null and r.status in ('requested','approved','returned')) then
      raise exception 'This IMEI was returned to the supplier before IMEI Entry and cannot be received again against the old stock.' using errcode='55000';
    end if;
  end loop;
  return new;
end; $$;
drop trigger if exists simple_stock_return_imei_guard on public.devices;
create trigger simple_stock_return_imei_guard before insert or update of imei_1,imei_2 on public.devices
for each row execute function greenloop_private.simple_stock_return_imei_guard();

-- A known model returned without choosing a color must still reduce the
-- model's intake pool. Keep the existing per-color checks, and add aggregate
-- model/GB checks without assigning the return to an invented color line.
create or replace function greenloop_private.simple_stock_return_model_intake_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.devices%rowtype; v_model text; v_capacity integer; v_entered integer; v_returned integer;
begin
  if new.receiving_batch_id is null or new.deleted_at is not null then return new; end if;
  if tg_op='UPDATE' and old.receiving_batch_id is not distinct from new.receiving_batch_id and old.deleted_at is null then return new; end if;
  perform 1 from public.receiving_batches where id=new.receiving_batch_id for update;
  select * into d from public.devices where id=new.device_id;
  v_model:=lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g'));
  -- GB may be supplied independently of model. A GB-only returned unit
  -- consumes that receipt's GB pool without inventing its model.
  if d.storage_gb is not null and exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=new.receiving_batch_id)
    and not exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=new.receiving_batch_id and storage_gb is null) then
    select coalesce(sum(planned_quantity),0)::integer into v_capacity from public.stock_batch_plan_lines
      where receiving_batch_id=new.receiving_batch_id and storage_gb=d.storage_gb;
    select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
      where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and j.id<>new.id and x.storage_gb=d.storage_gb;
    select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
      where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
        and coalesce(nullif(r.source_snapshot->>'storage_gb','')::integer,p.storage_gb)=d.storage_gb;
    if v_entered+v_returned>=v_capacity then raise exception 'This GB has no unentered units remaining after Stock Returns.' using errcode='22023'; end if;
  end if;
  select sum(p.planned_quantity)::integer into v_capacity from public.stock_batch_plan_lines p
    where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model;
  if v_capacity is null then return new; end if;
  select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
    where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and j.id<>new.id
      and lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g'))=v_model;
  select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
    where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
      and lower(regexp_replace(btrim(coalesce(r.model,p.model,'')),'\s+',' ','g'))=v_model;
  if v_entered+v_returned>=v_capacity then
    raise exception 'This model has no unentered units remaining after Stock Returns.' using errcode='22023';
  end if;
  if d.storage_gb is not null and not exists(select 1 from public.stock_batch_plan_lines p
    where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model and p.storage_gb is null) then
    select coalesce(sum(p.planned_quantity),0)::integer into v_capacity from public.stock_batch_plan_lines p
      where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model and p.storage_gb=d.storage_gb;
    select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
      where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and j.id<>new.id
        and lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g'))=v_model and x.storage_gb=d.storage_gb;
    select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
      where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
        and lower(regexp_replace(btrim(coalesce(r.model,p.model,'')),'\s+',' ','g'))=v_model
        and coalesce(nullif(r.source_snapshot->>'storage_gb','')::integer,p.storage_gb)=d.storage_gb;
    if v_entered+v_returned>=v_capacity then
      raise exception 'This model/GB has no unentered units remaining after Stock Returns.' using errcode='22023';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists simple_stock_return_model_intake_guard on public.jobs;
create trigger simple_stock_return_model_intake_guard before insert or update of receiving_batch_id,deleted_at on public.jobs
for each row execute function greenloop_private.simple_stock_return_model_intake_guard();

create or replace function public.record_simple_stock_return(p_payload jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_saved greenloop_private.simple_stock_return_groups%rowtype;
  b public.receiving_batches%rowtype; j public.jobs%rowtype; d public.devices%rowtype;
  v_batch uuid; v_quantity integer; v_reason text; v_notes text; v_model text; v_storage integer;
  v_imeis jsonb; v_units jsonb:='[]'::jsonb; v_unit jsonb; v_imei text; v_canonical text;
  v_seen text[]:='{}'; v_unentered integer:=0; v_plan uuid; v_plans uuid[]; v_remaining integer; v_model_remaining integer;
  v_group uuid:=gen_random_uuid(); v_id uuid; v_number text; v_reference text; v_actor text;
  v_ids uuid[]:='{}'; v_numbers text[]:='{}'; v_known_imeis text[]:='{}'; v_result jsonb; v_snapshot jsonb;
  v_state jsonb; v_unit_reason text; v_unit_notes text; v_report_model text; v_report_storage integer; v_storage_label text; i integer;
begin
  perform greenloop_private.require_supplier_return_access('request');
  if p_idempotency_key is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'A return payload and retry key are required.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('simple-return:'||auth.uid()::text||p_idempotency_key::text,0));
  select * into v_saved from greenloop_private.simple_stock_return_groups where actor_id=auth.uid() and idempotency_key=p_idempotency_key;
  if found then
    if v_saved.command<>p_payload then raise exception 'This retry key belongs to different return details.' using errcode='22023'; end if;
    return v_saved.response;
  end if;
  v_batch:=nullif(p_payload->>'batch_id','')::uuid;
  v_quantity:=(p_payload->>'quantity')::integer;
  v_reason:=nullif(btrim(p_payload->>'reason'),''); v_notes:=nullif(btrim(p_payload->>'notes'),'');
  v_model:=nullif(regexp_replace(btrim(coalesce(p_payload->>'model','')),'\s+',' ','g'),'');
  v_storage:=nullif(p_payload->>'storage_gb','')::integer;
  v_imeis:=coalesce(p_payload->'imeis','[]'::jsonb);
  if v_batch is null or v_quantity is null or v_quantity not between 1 and 1000 or v_reason is null or length(v_reason)>500
    or length(coalesce(v_notes,''))>2000 or length(coalesce(v_model,''))>150 or (v_storage is not null and v_storage<=0)
    or (lower(v_reason)='other' and v_notes is null) then
    raise exception 'Select a receipt, quantity (1–1000) and reason. Other requires explanatory notes.' using errcode='22023';
  end if;
  if jsonb_typeof(v_imeis)<>'array' or jsonb_array_length(v_imeis)>v_quantity then
    raise exception 'Provide at most one optional IMEI per returned phone.' using errcode='22023';
  end if;
  -- Lock the original receipt: unidentified returns and normal IMEI intake
  -- share this same lock, so both cannot consume the same remaining unit.
  select * into b from public.receiving_batches where id=v_batch for update;
  if b.id is null or b.supplier_id is null or b.planned_quantity is null
    or not exists(select 1 from public.suppliers s where s.id=b.supplier_id and s.deleted_at is null) then
    raise exception 'Select an available supplier receipt.' using errcode='22023';
  end if;
  for v_imei in select btrim(value#>>'{}') from jsonb_array_elements(v_imeis) where jsonb_typeof(value)='string' order by 1 loop
    if v_imei !~ '^[0-9]{15}$' then raise exception 'Every optional IMEI must contain exactly 15 digits.' using errcode='22023'; end if;
    perform pg_advisory_xact_lock(hashtextextended('greenloop-return-imei:'||v_imei,0));
  end loop;
  if exists(select 1 from jsonb_array_elements(v_imeis) where jsonb_typeof(value)<>'string') then
    raise exception 'IMEIs must be provided as 15-digit text values.' using errcode='22023';
  end if;
  for i in 0..v_quantity-1 loop
    v_imei:=nullif(btrim(v_imeis->>i),''); d:=null; j:=null; v_canonical:=v_imei;
    if i<jsonb_array_length(v_imeis) and v_imei is null then raise exception 'Remove empty IMEI lines before returning stock.' using errcode='22023'; end if;
    if v_imei is not null then
      select * into d from public.devices where imei_1=v_imei or imei_2=v_imei;
      if d.id is not null then
        if d.deleted_at is not null then raise exception 'This IMEI belongs to a deleted phone. Resolve its saved record first.' using errcode='22023'; end if;
        select * into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1 for update;
        select * into d from public.devices where id=d.id for update;
        if d.id is null or d.deleted_at is not null or not (v_imei=d.imei_1 or v_imei=coalesce(d.imei_2,'')) then
          raise exception 'This phone changed while the return was being prepared. Refresh and scan its current IMEI again.' using errcode='55000';
        end if;
        if j.id is null or j.receiving_batch_id is distinct from b.id or j.supplier_id is distinct from b.supplier_id then
          raise exception 'IMEI % does not belong to the selected supplier receipt.',v_imei using errcode='22023';
        end if;
        if j.ownership_type<>'company_owned' or j.closed_at is not null or j.current_status::text in
          ('shipped','returned_to_customer','rma_completed','scrap','supplier_return_requested','return_pending','returned_to_supplier')
          or exists(select 1 from public.supplier_returns r where r.device_id=d.id and r.archived_at is null and r.status in ('requested','approved','returned')) then
          raise exception 'IMEI % is already returned, on hold, closed or unavailable for a new return.',v_imei using errcode='22023';
        end if;
        if exists(select 1 from public.jobs x where x.device_id=d.id and x.id<>j.id and x.deleted_at is null and x.closed_at is null
          and x.current_status::text not in ('shipped','returned_to_customer','rma_completed','scrap')) then
          raise exception 'This phone has another open job. Resolve duplicate jobs first.' using errcode='55000';
        end if;
        if exists(select 1 from public.export_box_items x where x.device_id=d.id) then
          raise exception 'Remove IMEI % from its export box before returning it.',v_imei using errcode='55000';
        end if;
        if (v_model is not null and lower(v_model)<>lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g')))
          or (v_storage is not null and v_storage is distinct from d.storage_gb) then
          raise exception 'The optional model or GB does not match IMEI %.',v_imei using errcode='22023';
        end if;
        perform greenloop_private.require_supplier_return_parts_clear(j.id);
        v_canonical:=d.imei_1;
      end if;
      if v_canonical=any(v_seen) then raise exception 'The same phone was scanned more than once.' using errcode='22023'; end if;
      v_seen:=array_append(v_seen,v_canonical); v_known_imeis:=array_append(v_known_imeis,v_canonical);
      if exists(select 1 from public.supplier_returns r where r.imei_1=v_canonical and r.archived_at is null and r.status in ('requested','approved','returned')) then
        raise exception 'IMEI % already has an active supplier return.',v_imei using errcode='22023';
      end if;
    end if;
    if d.id is null then v_unentered:=v_unentered+1; end if;
    v_units:=v_units||jsonb_build_array(jsonb_build_object('device_id',d.id,'job_id',j.id,'imei',v_canonical,
      'model',case when d.id is null then v_model else d.model end,
      'storage_gb',case when d.id is null then v_storage else d.storage_gb end,'serial_number',d.serial_number));
  end loop;
  v_remaining:=(greenloop_private.supplier_return_batch(b.id)->>'remaining_quantity')::integer;
  if v_unentered>v_remaining then
    raise exception 'Only % unentered phones remain on this receipt. Scan IMEIs for phones already entered; entered phones cannot be chosen automatically.',v_remaining using errcode='22023';
  end if;
  if v_unentered>0 and v_storage is not null and exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=b.id) then
    select coalesce(sum((x->>'remaining_quantity')::integer),0)::integer into v_model_remaining
      from jsonb_array_elements(greenloop_private.supplier_return_batch(b.id)->'plan_lines') x
      where x->>'storage_gb' is null or (x->>'storage_gb')::integer=v_storage;
    v_model_remaining:=greatest(v_model_remaining-(select count(*)::integer from public.supplier_returns r
      where r.batch_id=b.id and r.device_id is null and r.plan_line_id is null and r.archived_at is null
        and r.status in ('requested','approved','returned') and nullif(r.source_snapshot->>'storage_gb','')::integer=v_storage),0);
    if v_unentered>v_model_remaining then
      raise exception 'The optional GB has only % unentered units available across the receipt plan.',v_model_remaining using errcode='22023';
    end if;
  end if;
  -- Attach a plan only when it is unambiguous. Unknown model/color stays
  -- unallocated, never assigned to an arbitrary physical model or phone.
  select array_agg(p.id order by p.id) into v_plans from public.stock_batch_plan_lines p where p.receiving_batch_id=b.id
    and ((v_model is not null and (p.model is null or lower(p.model)=lower(v_model)) and (v_storage is null or p.storage_gb is null or p.storage_gb=v_storage))
      or (v_model is null and v_storage is null and p.model is null and p.storage_gb is null and p.color is null));
  if v_unentered>0 and v_model is not null and exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=b.id) then
    select coalesce(sum((x->>'remaining_quantity')::integer),0)::integer into v_model_remaining
      from jsonb_array_elements(greenloop_private.supplier_return_batch(b.id)->'plan_lines') x
      where (x->>'plan_line_id')::uuid=any(coalesce(v_plans,'{}'::uuid[]));
    -- Earlier model-described returns without a selected color still consume
    -- this model pool. Unknown GB consumes the pool conservatively, not a
    -- made-up individual color/GB line.
    v_model_remaining:=greatest(v_model_remaining-(select count(*)::integer from public.supplier_returns r
      where r.batch_id=b.id and r.device_id is null and r.plan_line_id is null and r.archived_at is null
        and r.status in ('requested','approved','returned') and lower(r.model)=lower(v_model)
        and (v_storage is null or r.source_snapshot->>'storage_gb' is null or (r.source_snapshot->>'storage_gb')::integer=v_storage)),0);
    if v_unentered>v_model_remaining then
      raise exception 'The optional model/GB has only % unentered units available across the receipt plan.',v_model_remaining using errcode='22023';
    end if;
  end if;
  if cardinality(v_plans)=1 then
    v_plan:=v_plans[1];
    select (x->>'remaining_quantity')::integer into v_remaining from jsonb_array_elements(greenloop_private.supplier_return_batch(b.id)->'plan_lines') x
      where (x->>'plan_line_id')::uuid=v_plan;
    if v_unentered>v_remaining then raise exception 'The optional model has only % unentered units available.',v_remaining using errcode='22023'; end if;
  end if;
  select coalesce(nullif(full_name,''),login_username,'Staff') into v_actor from public.user_profiles where id=auth.uid();
  v_reference:='SRT-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(v_group::text,'-',''),1,10));
  select greenloop_private.simple_stock_receipt(b.id)||jsonb_build_object('supplier_name',s.company_name,'returned_by_name',coalesce(v_actor,'Staff'))
    into v_snapshot from public.suppliers s where s.id=b.supplier_id;
  v_unit_reason:=case when lower(v_reason) in ('dead','icloud_locked') then lower(v_reason) else 'other' end;
  v_unit_notes:=case when v_unit_reason='other' and lower(v_reason)<>'other' then concat_ws(E'\n',v_reason,v_notes) else v_notes end;
  for v_unit in select value from jsonb_array_elements(v_units) loop
    v_id:=gen_random_uuid(); v_state:='{}'::jsonb;
    if v_unit->>'job_id' is not null then
      select jsonb_build_object('job_status',current_job.current_status,'device_status',current_device.current_status,
        'orders',coalesce((select jsonb_agg(jsonb_build_object('id',id,'status',status)) from public.job_work_orders where job_id=current_job.id),'[]'::jsonb),
        'steps',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.step_status)) from public.job_work_order_steps s join public.job_work_orders o on o.id=s.work_order_id where o.job_id=current_job.id and s.step_status in ('pending','in_progress')),'[]'::jsonb),
        'parts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'status',status)) from public.job_part_requests where job_id=current_job.id and status in ('requested','partially_issued','issued','partially_installed')),'[]'::jsonb),
        'timer',coalesce((select to_jsonb(t) from public.technician_job_timers t where job_id=current_job.id),'null'::jsonb))
        into v_state from public.jobs current_job join public.devices current_device on current_device.id=current_job.device_id where current_job.id=(v_unit->>'job_id')::uuid;
    end if;
    insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),v_id);
    insert into public.supplier_returns(id,device_id,job_id,batch_id,plan_line_id,supplier_id,imei_1,serial_number,model,reason,notes,status,
      requested_by,handed_over_by,handed_over_at,slip_reference,source_snapshot,prior_state)
    values(v_id,(v_unit->>'device_id')::uuid,(v_unit->>'job_id')::uuid,b.id,case when v_unit->>'device_id' is null then v_plan else null end,
      b.supplier_id,v_unit->>'imei',v_unit->>'serial_number',v_unit->>'model',v_unit_reason,v_unit_notes,'returned',
      auth.uid(),auth.uid(),now(),v_reference,v_snapshot||jsonb_build_object('simple_return_group_id',v_group,'storage_gb',v_unit->'storage_gb'),v_state)
    returning return_number into v_number;
    if v_unit->>'job_id' is not null then
      update public.jobs set current_status='returned_to_supplier',closed_at=now() where id=(v_unit->>'job_id')::uuid;
      update public.devices set current_status='returned_to_supplier' where id=(v_unit->>'device_id')::uuid;
      update public.job_work_order_steps set step_status='supplier_return_hold' where id in (select (x->>'id')::uuid from jsonb_array_elements(v_state->'steps') x);
      update public.job_work_orders set status='cancelled' where job_id=(v_unit->>'job_id')::uuid and status='open';
      update public.job_part_requests set status='cancelled' where id in (select (x->>'id')::uuid from jsonb_array_elements(v_state->'parts') x);
      update public.technician_job_timers set stopped_at=now(),elapsed_seconds=greatest(0,floor(extract(epoch from now()-started_at)))::integer,stopped_by=auth.uid()
        where job_id=(v_unit->>'job_id')::uuid and stopped_at is null;
    end if;
    perform greenloop_private.supplier_return_event(v_id,'stock_return',null,'returned',v_unit_notes,
      jsonb_build_object('group_id',v_group,'return_reference',v_reference,'reason',v_reason,'single_action',true));
    delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid() and return_id=v_id;
    v_ids:=array_append(v_ids,v_id); v_numbers:=array_append(v_numbers,v_number);
  end loop;
  -- Known scanned phones supply their recorded model/GB even if the optional
  -- form fields are blank. Never infer metadata for unidentified units.
  select case when count(*) filter(where nullif(x->>'model','') is null)>0 then null
    when count(distinct lower(x->>'model'))=1 then min(x->>'model') else 'Mixed' end,
    case when count(*) filter(where x->>'storage_gb' is null)=0 and count(distinct x->>'storage_gb')=1 then min((x->>'storage_gb')::integer) else null end,
    case when count(*) filter(where x->>'storage_gb' is null)>0 then null
      when count(distinct x->>'storage_gb')=1 then min(x->>'storage_gb')||' GB' else 'Mixed' end
    into v_report_model,v_report_storage,v_storage_label from jsonb_array_elements(v_units) x;
  v_result:=jsonb_build_object('group_id',v_group,'return_reference',v_reference,'quantity',v_quantity,'returned_at',now(),
    'return_ids',to_jsonb(v_ids),'return_numbers',to_jsonb(v_numbers),'imeis',to_jsonb(v_known_imeis),
    'model',v_report_model,'storage_gb',v_report_storage,'storage_label',v_storage_label);
  insert into greenloop_private.simple_stock_return_groups(id,actor_id,idempotency_key,command,receipt_snapshot,response)
    values(v_group,auth.uid(),p_idempotency_key,p_payload,v_snapshot,v_result);
  return v_result;
end; $$;

create or replace function public.list_simple_stock_returns(p_from date default null,p_to date default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not greenloop_private.simple_stock_return_view_access() then raise exception 'Stock Return report permission is required.' using errcode='42501'; end if;
  if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Select a valid From and To date.' using errcode='22023'; end if;
  return coalesce((select jsonb_agg(x.data order by x.returned_at desc,x.group_id) from (
    select g.id as group_id,g.returned_at,jsonb_build_object(
      'group_id',g.id,'return_reference',g.response->>'return_reference','batch_id',g.receipt_snapshot->'batch_id',
      'batch_number',g.receipt_snapshot->>'batch_number','supplier_id',g.receipt_snapshot->'supplier_id',
      'supplier_code',g.receipt_snapshot->>'supplier_code','supplier_name',case when public.get_my_partner_name_access() then g.receipt_snapshot->>'supplier_name' else null end,
      'received_at',g.receipt_snapshot->'received_at','invoice_number',g.receipt_snapshot->>'invoice_number',
      'received_quantity',g.receipt_snapshot->'received_quantity','returned_quantity',g.response->'quantity','returned_at',g.returned_at,
      'reason',g.command->>'reason','notes',g.command->>'notes','model',g.response->'model','storage_gb',g.response->'storage_gb','storage_label',g.response->>'storage_label',
      'imeis',g.response->'imeis','returned_by',g.actor_id,'returned_by_name',g.receipt_snapshot->>'returned_by_name',
      'return_ids',g.response->'return_ids','return_numbers',g.response->'return_numbers',
      'archived',exists(select 1 from public.supplier_returns r where r.id in (select value::uuid from jsonb_array_elements_text(g.response->'return_ids')) and r.archived_at is not null)
    ) data from greenloop_private.simple_stock_return_groups g
    union all
    select r.id,r.handed_over_at,jsonb_build_object(
      'group_id',r.id,'return_reference',coalesce(r.slip_reference,r.return_number),'batch_id',coalesce(to_jsonb(r.batch_id),r.source_snapshot->'batch_id'),
      'batch_number',coalesce(r.source_snapshot->>'batch_number',b.batch_number),'supplier_id',r.supplier_id,
      'supplier_code',coalesce(r.source_snapshot->>'supplier_code',s.supplier_code),
      'supplier_name',case when public.get_my_partner_name_access() then coalesce(r.source_snapshot->>'supplier_name',s.company_name) else null end,
      'received_at',coalesce(r.source_snapshot->'received_at',to_jsonb(b.received_at)),
      'invoice_number',coalesce(r.source_snapshot->>'invoice_number',b.invoice_number),
      'received_quantity',coalesce(r.source_snapshot->'received_quantity',to_jsonb(b.planned_quantity)),
      'returned_quantity',1,'returned_at',r.handed_over_at,'reason',r.reason,'notes',r.notes,'model',r.model,'storage_gb',null,
      'imeis',case when r.imei_1 is null then '[]'::jsonb else jsonb_build_array(r.imei_1) end,
      'returned_by',r.handed_over_by,'returned_by_name',coalesce(p.full_name,p.login_username,'Staff'),
      'return_ids',jsonb_build_array(r.id),'return_numbers',jsonb_build_array(r.return_number),'archived',r.archived_at is not null
    ) from public.supplier_returns r join public.suppliers s on s.id=r.supplier_id
    left join public.receiving_batches b on b.id=r.batch_id left join public.user_profiles p on p.id=r.handed_over_by
    where r.status='returned' and not exists(select 1 from greenloop_private.simple_stock_return_groups g where g.response->'return_ids' ? r.id::text)
  ) x where (p_from is null or timezone('Asia/Dubai',x.returned_at)::date>=p_from)
    and (p_to is null or timezone('Asia/Dubai',x.returned_at)::date<=p_to)),'[]'::jsonb);
end; $$;

do $$ declare p record; begin
  for p in select oid::regprocedure signature from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'simple_stock_%' loop
    execute format('revoke all on function %s from public,anon,authenticated',p.signature);
  end loop;
  for p in select oid::regprocedure signature from pg_proc where pronamespace='public'::regnamespace and proname in
    ('get_simple_stock_return_context','get_simple_stock_return_receipt_totals','record_simple_stock_return','list_simple_stock_returns') loop
    execute format('revoke all on function %s from public,anon,authenticated',p.signature);
    execute format('grant execute on function %s to authenticated',p.signature);
  end loop;
end; $$;
create table if not exists greenloop_private.simple_stock_return_installation(object_identity text primary key,object_kind text not null,definition_hash text not null);
revoke all on greenloop_private.simple_stock_return_installation from public,anon,authenticated;
create or replace function public.get_greenloop_simple_stock_return_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare m record; actual text;
begin
  if public.get_greenloop_stock_return_page_version() is distinct from '20260926-stock-return-page-1' then return null; end if;
  if (select count(*) from greenloop_private.simple_stock_return_installation)<>14 then return null; end if;
  for m in select * from greenloop_private.simple_stock_return_installation loop
    if m.object_kind='function' then
      if to_regprocedure(m.object_identity) is null then return null; end if;
      actual:=md5(pg_get_functiondef(to_regprocedure(m.object_identity)));
    elsif m.object_kind='trigger' then
      select md5(pg_get_triggerdef(t.oid)||t.tgenabled::text) into actual from pg_trigger t
        where t.tgrelid=split_part(m.object_identity,':',1)::regclass and t.tgname=split_part(m.object_identity,':',2);
    else
      select md5(pg_get_indexdef(i.indexrelid)||i.indisvalid::text) into actual from pg_index i where i.indexrelid=to_regclass(m.object_identity);
    end if;
    if actual is distinct from m.definition_hash then return null; end if;
  end loop;
  if has_function_privilege('anon','public.record_simple_stock_return(jsonb,uuid)','execute')
    or has_function_privilege('anon','public.list_simple_stock_returns(date,date)','execute')
    or has_function_privilege('anon','public.get_simple_stock_return_context()','execute')
    or has_function_privilege('anon','public.get_simple_stock_return_receipt_totals(uuid[])','execute')
    or not has_function_privilege('authenticated','public.record_simple_stock_return(jsonb,uuid)','execute')
    or not has_function_privilege('authenticated','public.list_simple_stock_returns(date,date)','execute')
    or not has_function_privilege('authenticated','public.get_simple_stock_return_context()','execute')
    or not has_function_privilege('authenticated','public.get_simple_stock_return_receipt_totals(uuid[])','execute')
    or has_table_privilege('authenticated','greenloop_private.simple_stock_return_groups','select,insert,update,delete')
    or has_table_privilege('anon','greenloop_private.simple_stock_return_groups','select,insert,update,delete') then return null; end if;
  return '20260926-simple-stock-return-1';
end; $$;
revoke all on function public.get_greenloop_simple_stock_return_version() from public,anon,authenticated;
grant execute on function public.get_greenloop_simple_stock_return_version() to anon,authenticated;
delete from greenloop_private.simple_stock_return_installation;
insert into greenloop_private.simple_stock_return_installation
select n.nspname||'.'||p.proname||'('||oidvectortypes(p.proargtypes)||')','function',md5(pg_get_functiondef(p.oid))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where (n.nspname='greenloop_private' and p.proname like 'simple_stock_%')
or (n.nspname='public' and p.proname in ('get_simple_stock_return_context','get_simple_stock_return_receipt_totals','record_simple_stock_return','list_simple_stock_returns','get_greenloop_simple_stock_return_version'));
insert into greenloop_private.simple_stock_return_installation
select n.nspname||'.'||c.relname||':'||t.tgname,'trigger',md5(pg_get_triggerdef(t.oid)||t.tgenabled::text)
from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where t.tgname in ('simple_stock_return_immutable','simple_stock_return_imei_guard','simple_stock_return_model_intake_guard');
insert into greenloop_private.simple_stock_return_installation
select 'public.simple_stock_return_active_imei','index',md5(pg_get_indexdef(i.indexrelid)||i.indisvalid::text)
from pg_index i where i.indexrelid='public.simple_stock_return_active_imei'::regclass;
do $$ begin
  if public.get_greenloop_simple_stock_return_version() is distinct from '20260926-simple-stock-return-1' then
    raise exception 'Simple Stock Return installation verification failed; no changes installed.' using errcode='55000';
  end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_greenloop_simple_stock_return_version() as installed_simple_stock_return_version;
