-- Supplier Returns v1. Run as one script in the SQL editor, outside a transaction.
-- Enum additions must commit before the transactional installation below.
begin;
alter type public.job_status add value if not exists 'supplier_return_requested';
alter type public.job_status add value if not exists 'return_pending';
alter type public.job_status add value if not exists 'returned_to_supplier';
alter type public.work_order_step_status add value if not exists 'supplier_return_hold';
commit;

begin;
create schema if not exists greenloop_private;
revoke all on schema greenloop_private from public, anon, authenticated;

create sequence if not exists public.supplier_return_number_sequence;
create table if not exists public.supplier_returns (
  id uuid primary key default gen_random_uuid(),
  return_number text not null unique default ('SR-'||to_char(current_date,'YYYY')||'-'||lpad(nextval('public.supplier_return_number_sequence')::text,7,'0')),
  device_id uuid references public.devices(id) on delete restrict,
  job_id uuid references public.jobs(id) on delete restrict,
  batch_id uuid references public.receiving_batches(id) on delete restrict,
  plan_line_id uuid references public.stock_batch_plan_lines(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  imei_1 text, serial_number text, model text,
  reason text not null check (reason in ('dead','icloud_locked','other')),
  notes text,
  status text not null default 'requested' check (status in ('requested','approved','returned','rejected','cancelled')),
  requested_by uuid not null, requested_at timestamptz not null default now(),
  approved_by uuid, approved_at timestamptz,
  handed_over_by uuid, handed_over_at timestamptz, slip_reference text,
  closed_by uuid, closed_at timestamptz, closure_notes text,
  settlement_type text check (settlement_type in ('replacement','credit','refund')),
  settlement_reference text, settlement_amount numeric(14,2) check (settlement_amount >= 0),
  settlement_notes text, settled_by uuid, settled_at timestamptz,
  archived_at timestamptz, archived_by uuid, deletion_audit_id uuid,
  source_snapshot jsonb not null default '{}'::jsonb,
  prior_state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint supplier_returns_unit_link_check check (archived_at is not null or (device_id is null and job_id is null and batch_id is not null) or (device_id is not null and job_id is not null)),
  check (status <> 'returned' or (handed_over_at is not null and nullif(btrim(slip_reference),'') is not null))
);
create unique index if not exists supplier_returns_active_device on public.supplier_returns(device_id) where archived_at is null and status in ('requested','approved','returned');
create unique index if not exists supplier_returns_active_serial on public.supplier_returns(lower(btrim(serial_number))) where archived_at is null and device_id is null and serial_number is not null and status in ('requested','approved','returned');
create index if not exists supplier_returns_batch on public.supplier_returns(batch_id,status);
create table if not exists public.supplier_return_events (
  id uuid primary key default gen_random_uuid(), return_id uuid not null references public.supplier_returns(id) on delete restrict,
  action text not null, from_status text, to_status text not null,
  actor_id uuid not null, actor_name text not null, occurred_at timestamptz not null default now(),
  notes text, event_data jsonb not null default '{}'::jsonb
);
create index if not exists supplier_return_events_return on public.supplier_return_events(return_id,occurred_at,id);
create table if not exists greenloop_private.supplier_return_commands (
  actor_id uuid not null, idempotency_key uuid not null, command jsonb not null, response jsonb not null,
  created_at timestamptz not null default now(), primary key(actor_id,idempotency_key)
);
create table if not exists greenloop_private.supplier_return_capabilities (
  transaction_id bigint not null, backend_pid integer not null, return_id uuid not null,
  primary key(transaction_id,backend_pid,return_id)
);
alter table public.supplier_returns enable row level security;
alter table public.supplier_return_events enable row level security;
revoke all on public.supplier_returns,public.supplier_return_events,public.supplier_return_number_sequence from public,anon,authenticated;
revoke all on greenloop_private.supplier_return_commands,greenloop_private.supplier_return_capabilities from public,anon,authenticated;

create or replace function greenloop_private.supplier_return_access(p_key text,p_edit boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(public.is_active_staff(),false) and auth.uid() is not null and
   coalesce((select case when p_edit then p.access_level='edit' else p.access_level in ('view','edit') end
     from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key=p_key),
     public.has_role(array['owner','super_admin']::public.app_role_key[]),false);
$$;
create or replace function greenloop_private.require_supplier_return_access(p_action text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not (case p_action
   when 'view' then greenloop_private.supplier_return_access('supplier_returns') or greenloop_private.supplier_return_access('supplier_return_approval') or greenloop_private.supplier_return_access('supplier_return_handover')
   when 'request' then greenloop_private.supplier_return_access('supplier_returns',true)
   when 'approve' then greenloop_private.supplier_return_access('supplier_return_approval',true)
   when 'handover' then greenloop_private.supplier_return_access('supplier_return_handover',true)
   else false end) then raise exception 'Supplier Return % permission is required.',p_action using errcode='42501'; end if;
end; $$;

create or replace function greenloop_private.supplier_return_record(p_id uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select (to_jsonb(r)-array['prior_state','source_snapshot']) || jsonb_build_object(
   'supplier_code',coalesce(r.source_snapshot->>'supplier_code',s.supplier_code),'supplier_name',case when public.get_my_partner_name_access() then coalesce(r.source_snapshot->>'supplier_name',s.company_name) else null end,
   'batch_number',coalesce(b.batch_number,r.source_snapshot->>'batch_number'),'job_number',coalesce(j.job_number,r.source_snapshot->>'job_number'),
   'requested_by_name',(select coalesce(nullif(p.full_name,''),p.login_username,'Staff') from public.user_profiles p where p.id=r.requested_by),
   'approved_by_name',(select coalesce(nullif(p.full_name,''),p.login_username,'Staff') from public.user_profiles p where p.id=r.approved_by),
   'handed_over_by_name',(select coalesce(nullif(p.full_name,''),p.login_username,'Staff') from public.user_profiles p where p.id=r.handed_over_by))
 from public.supplier_returns r join public.suppliers s on s.id=r.supplier_id
 left join public.receiving_batches b on b.id=r.batch_id left join public.jobs j on j.id=r.job_id where r.id=p_id;
$$;

create or replace function greenloop_private.supplier_return_event(p_id uuid,p_action text,p_from text,p_to text,p_notes text,p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_return public.supplier_returns%rowtype; v_name text;
begin
 select * into strict v_return from public.supplier_returns where id=p_id;
 select coalesce(nullif(full_name,''),login_username,'Staff') into v_name from public.user_profiles where id=auth.uid();
 insert into public.supplier_return_events(return_id,action,from_status,to_status,actor_id,actor_name,notes,event_data)
 values(p_id,p_action,p_from,p_to,auth.uid(),coalesce(v_name,'Staff'),p_notes,p_data);
 if v_return.device_id is not null then
   insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
   values(v_return.device_id,v_return.job_id,'supplier_return_'||p_action,'Supplier Return '||v_return.return_number||': '||p_action,
     jsonb_build_object('return_id',p_id,'return_number',v_return.return_number,'reason',v_return.reason,'status',p_to,'notes',p_notes)||p_data,auth.uid());
 end if;
end; $$;

create or replace function greenloop_private.supplier_return_parts(p_job uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(to_jsonb(x) order by x.part_name),'[]'::jsonb) from (
   select r.id part_request_id,r.part_name,
     coalesce((select sum(greatest(i.quantity_issued-i.quantity_returned-coalesce((select sum(n.quantity_installed) from public.part_installations n where n.part_issue_id=i.id),0),0)) from public.part_issue_transactions i where i.part_request_id=r.id),0)::integer unused_quantity,
     coalesce((select sum(q.quantity) from public.lab_part_return_requests q where q.part_request_id=r.id and q.status='pending'),0)::integer pending_return_quantity,
     r.quantity_installed, r.quantity_returned
   from public.job_part_requests r where r.job_id=p_job
 ) x;
$$;
create or replace function greenloop_private.require_supplier_return_parts_clear(p_job uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if p_job is null then return; end if;
 if exists(select 1 from jsonb_array_elements(greenloop_private.supplier_return_parts(p_job)) x where (x->>'unused_quantity')::integer>0 or (x->>'pending_return_quantity')::integer>0)
 or exists(select 1 from public.part_stock_movements m where m.job_id=p_job group by m.lot_id having sum(case when m.to_status='issued_to_technician' then m.quantity else 0 end - case when m.from_status='issued_to_technician' then m.quantity else 0 end)>0)
 then raise exception 'Reconcile all unused issued parts and pending part returns with the Parts Department before approval or handover. Installed parts and costs remain on the phone.' using errcode='55000'; end if;
end; $$;

-- Every quantity is a physical unit. IMEI returns are already included in the
-- entered count, so only unidentified units reduce intake capacity.
create or replace function greenloop_private.supplier_return_batch(p_batch uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'supplier_id',s.id,'supplier_code',s.supplier_code,
  'supplier_name',case when public.get_my_partner_name_access() then s.company_name else null end,
  'received_quantity',b.planned_quantity,'entered_quantity',e.n,'unentered_reserved',r.reserved,'returned_without_imei',r.returned_unentered,
  'returned_quantity',r.returned_all,'held_imei_quantity',r.held_imei,'active_quantity',greatest(e.n-r.held_imei,0),
  'required_quantity',greatest(b.planned_quantity-r.returned_all,0),
  'remaining_quantity',greatest(b.planned_quantity-e.n-r.reserved-r.returned_unentered,0),
  'plan_lines',coalesce((select jsonb_agg(jsonb_build_object('plan_line_id',p.id,'model',p.model,'storage_gb',p.storage_gb,'color',p.color,
    'received_quantity',p.planned_quantity,'entered_quantity',pe.n,'reserved_quantity',pr.reserved,'returned_quantity',pr.returned,
    'remaining_quantity',greatest(p.planned_quantity-pe.n-pr.reserved-pr.returned,0)) order by p.created_at,p.id)
    from public.stock_batch_plan_lines p
    cross join lateral(select count(*)::integer n from public.jobs j join public.devices d on d.id=j.device_id where j.receiving_batch_id=b.id and j.deleted_at is null
      and (p.model is null or lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g'))=lower(p.model))
      and (p.storage_gb is null or p.storage_gb=d.storage_gb) and (p.color is null or lower(regexp_replace(btrim(coalesce(d.color,'')),'\s+',' ','g'))=lower(p.color))) pe
    cross join lateral(select count(*) filter(where t.status in ('requested','approved'))::integer reserved,count(*) filter(where t.status='returned')::integer returned from public.supplier_returns t where t.plan_line_id=p.id and t.device_id is null) pr
    where p.receiving_batch_id=b.id),'[]'::jsonb))
 from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id
 cross join lateral(select count(*)::integer n from public.jobs j where j.receiving_batch_id=b.id and j.deleted_at is null) e
 cross join lateral(select count(*) filter(where t.device_id is null and t.status in ('requested','approved'))::integer reserved,
  count(*) filter(where t.device_id is null and t.status='returned')::integer returned_unentered,
  count(*) filter(where t.status='returned')::integer returned_all,
  count(*) filter(where t.device_id is not null and t.status in ('requested','approved','returned'))::integer held_imei
  from public.supplier_returns t where t.batch_id=b.id) r
 where b.id=p_batch and b.planned_quantity is not null;
$$;

create or replace function public.get_supplier_return_context()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 perform greenloop_private.require_supplier_return_access('view');
 return jsonb_build_object('permissions',jsonb_build_object('view',true,'request',greenloop_private.supplier_return_access('supplier_returns',true),
  'approve',greenloop_private.supplier_return_access('supplier_return_approval',true),'handover',greenloop_private.supplier_return_access('supplier_return_handover',true)),
  'batches',coalesce((select jsonb_agg(greenloop_private.supplier_return_batch(b.id) order by b.received_at desc,b.id)
   from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id where b.planned_quantity is not null and s.deleted_at is null),'[]'::jsonb));
end; $$;
create or replace function public.lookup_supplier_return_device(p_imei text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype; v_device public.devices%rowtype; v_result jsonb;
begin
 perform greenloop_private.require_supplier_return_access('view');
 if btrim(coalesce(p_imei,'')) !~ '^[0-9]{15}$' then raise exception 'Enter the complete 15-digit IMEI.' using errcode='22023'; end if;
 select * into v_device from public.devices where (imei_1=btrim(p_imei) or imei_2=btrim(p_imei)) and deleted_at is null;
 if v_device.id is null then raise exception 'No phone matches that IMEI.' using errcode='22023'; end if;
 select * into v_job from public.jobs where device_id=v_device.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1;
 select jsonb_build_object('device_id',v_device.id,'job_id',v_job.id,'imei_1',v_device.imei_1,'serial_number',v_device.serial_number,'model',v_device.model,
  'supplier_code',s.supplier_code,'supplier_name',case when public.get_my_partner_name_access() then s.company_name else null end,'current_status',v_job.current_status,
  'batch_id',v_job.receiving_batch_id,'eligible',v_job.id is not null and v_job.supplier_id is not null and v_job.ownership_type='company_owned' and v_job.closed_at is null
   and v_job.current_status::text not in ('shipped','returned_to_customer','rma_completed','scrap','supplier_return_requested','return_pending','returned_to_supplier')
   and not exists(select 1 from public.export_box_items i where i.device_id=v_device.id),
  'unreconciled_parts_quantity',coalesce((select sum((x->>'unused_quantity')::integer) from jsonb_array_elements(greenloop_private.supplier_return_parts(v_job.id)) x),0),
  'active_return',(select greenloop_private.supplier_return_record(r.id) from public.supplier_returns r where r.device_id=v_device.id and r.status in ('requested','approved','returned')))
 into v_result from (select 1) dummy left join public.suppliers s on s.id=v_job.supplier_id;
 return v_result;
end; $$;
create or replace function public.list_supplier_returns(p_status text default null,p_search text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 perform greenloop_private.require_supplier_return_access('view');
 return coalesce((select jsonb_agg(greenloop_private.supplier_return_record(r.id) order by r.requested_at desc,r.id)
  from public.supplier_returns r join public.suppliers s on s.id=r.supplier_id where
  (nullif(p_status,'') is null or r.status=p_status) and (nullif(btrim(p_search),'') is null or
   concat_ws(' ',r.return_number,r.imei_1,r.serial_number,r.model,s.supplier_code) ilike '%'||btrim(p_search)||'%')),'[]'::jsonb);
end; $$;
create or replace function public.get_supplier_return_detail(p_return_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_return public.supplier_returns%rowtype;
begin
 perform greenloop_private.require_supplier_return_access('view');
 select * into v_return from public.supplier_returns where id=p_return_id;
 if v_return.id is null then raise exception 'Supplier Return was not found.' using errcode='22023'; end if;
 return jsonb_build_object('return',greenloop_private.supplier_return_record(p_return_id),
  'events',coalesce((select jsonb_agg(to_jsonb(e) order by occurred_at,id) from public.supplier_return_events e where return_id=p_return_id),'[]'::jsonb),
  'parts',greenloop_private.supplier_return_parts(v_return.job_id));
end; $$;

create or replace function greenloop_private.supplier_return_immutable()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if tg_op='DELETE' or tg_table_name='supplier_return_events' and tg_op='UPDATE' then
  raise exception 'Supplier Return records and audit events are permanent.' using errcode='55000';
 end if;
 if not exists(select 1 from greenloop_private.supplier_return_capabilities c where c.transaction_id=txid_current() and c.backend_pid=pg_backend_pid() and c.return_id=case when tg_table_name='supplier_returns' then (to_jsonb(new)->>'id')::uuid else (to_jsonb(new)->>'return_id')::uuid end)
 then raise exception 'Use the authorized Supplier Return workflow.' using errcode='42501'; end if;
 return new;
end; $$;
drop trigger if exists supplier_returns_immutable on public.supplier_returns;
create trigger supplier_returns_immutable before insert or update or delete on public.supplier_returns for each row execute function greenloop_private.supplier_return_immutable();
drop trigger if exists supplier_return_events_immutable on public.supplier_return_events;
create trigger supplier_return_events_immutable before insert or update or delete on public.supplier_return_events for each row execute function greenloop_private.supplier_return_immutable();

-- Resolve linked work through actual foreign keys, including tables with only
-- an inspection, issue, request, or work-step identifier. Lock the job before
-- checking the hold, so an in-flight workshop write cannot race a request.
create or replace function greenloop_private.supplier_return_work_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row jsonb; v_old jsonb; v_job uuid; v_device uuid; v_order uuid; v_request uuid; v_inspection uuid; v_return uuid;
begin
 v_row:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 if tg_op='UPDATE' then v_old:=to_jsonb(old); end if;
 v_job:=nullif(v_row->>'job_id','')::uuid; v_device:=nullif(v_row->>'device_id','')::uuid;
 if tg_table_name='jobs' then v_job:=(v_row->>'id')::uuid; end if;
 if tg_table_name='devices' then v_device:=(v_row->>'id')::uuid; end if;
 if v_job is null then
  v_order:=nullif(v_row->>'work_order_id','')::uuid;
  if v_order is null and v_row->>'work_order_step_id' is not null then select work_order_id into v_order from public.job_work_order_steps where id=(v_row->>'work_order_step_id')::uuid; end if;
  if v_order is not null then select job_id,device_id into v_job,v_device from public.job_work_orders where id=v_order; end if;
 end if;
 if v_job is null then
  v_request:=nullif(v_row->>'part_request_id','')::uuid;
  if v_request is null and v_row->>'part_issue_id' is not null then select part_request_id into v_request from public.part_issue_transactions where id=(v_row->>'part_issue_id')::uuid; end if;
  if v_request is not null then select job_id,device_id into v_job,v_device from public.job_part_requests where id=v_request; end if;
 end if;
 if v_job is null then
  v_inspection:=coalesce(nullif(v_row->>'inspection_id',''),nullif(v_row->>'initial_qc_inspection_id',''),nullif(v_row->>'final_qc_inspection_id',''))::uuid;
  if v_inspection is not null then
   select job_id,device_id into v_job,v_device from public.initial_qc_inspections where id=v_inspection;
   if v_job is null then select job_id,device_id into v_job,v_device from public.final_qc_inspections where id=v_inspection; end if;
  end if;
 end if;
 if v_job is not null then perform 1 from public.jobs where id=v_job for update; end if;
 if v_device is null and v_job is not null then select device_id into v_device from public.jobs where id=v_job; end if;
 select r.id into v_return from public.supplier_returns r where (r.job_id=v_job or r.device_id=v_device)
  and (r.status in ('requested','approved','returned') or tg_op='DELETE') order by r.requested_at desc limit 1;
 if v_return is null then
  if tg_op<>'DELETE' and tg_table_name in ('jobs','devices') and v_row->>'current_status' in ('supplier_return_requested','return_pending','returned_to_supplier') then
   raise exception 'Supplier Return status requires an authorized return record.' using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
 end if;
 if tg_op='DELETE' then raise exception 'This phone has permanent Supplier Return history and cannot be deleted.' using errcode='55000'; end if;
 if exists(select 1 from greenloop_private.supplier_return_capabilities c where c.transaction_id=txid_current() and c.backend_pid=pg_backend_pid() and c.return_id=v_return) then return new; end if;
 -- Explicit reconciliation through existing Parts RPCs may return unused
 -- quantities. It cannot issue/install more, change identifiers, or erase cost.
 if tg_op='UPDATE' and tg_table_name='part_issue_transactions'
  and (v_row-array['quantity_returned','returned_by','returned_at','return_notes','status'])=(v_old-array['quantity_returned','returned_by','returned_at','return_notes','status'])
  and (v_row->>'quantity_returned')::integer>(v_old->>'quantity_returned')::integer
  and (v_row->>'quantity_returned')::integer <= (v_row->>'quantity_issued')::integer-coalesce((select sum(quantity_installed) from public.part_installations where part_issue_id=(v_row->>'id')::uuid),0)
 then return new; end if;
 if tg_op='UPDATE' and tg_table_name='job_part_requests'
  and (v_row-array['quantity_returned','status','updated_at'])=(v_old-array['quantity_returned','status','updated_at'])
  and (v_row->>'quantity_returned')::integer>(v_old->>'quantity_returned')::integer
  and (v_row->>'quantity_returned')::integer <= (v_row->>'quantity_issued')::integer-(v_row->>'quantity_installed')::integer
 then return new; end if;
 if tg_op='INSERT' and tg_table_name='part_stock_movements' and v_row->>'from_status'='issued_to_technician'
  and v_row->>'movement_type' in ('returned_to_stock','supplier_return') then return new; end if;
 raise exception 'This phone is held for Supplier Return or has been returned to the supplier. New work, stock-out, and editing are blocked.' using errcode='55000';
end; $$;
do $$
declare t text;
begin
 foreach t in array array['jobs','devices','job_work_orders','job_work_order_steps','initial_qc_inspections','initial_qc_findings','initial_qc_part_requirements',
  'job_part_requests','part_issue_transactions','part_installations','lab_manual_part_installations','laboratory_work_records','glass_work_records',
  'lab_service_reviews','technician_job_timers','frame_department_results','final_qc_inspections','final_qc_check_results','production_records',
  'packing_records','stock_out_records','export_box_items','part_stock_movements','device_location_history'] loop
  if to_regclass('public.'||t) is null then raise exception 'Required operational table % is missing. Install the current GreenLoop schema first.',t; end if;
  execute format('drop trigger if exists supplier_return_work_guard on public.%I',t);
  execute format('create trigger supplier_return_work_guard before insert or update or delete on public.%I for each row execute function greenloop_private.supplier_return_work_guard()',t);
 end loop;
end; $$;

-- Independent of which intake RPC is called: the receipt lock serializes both
-- new IMEIs and unidentified return reservations, including direct writes.
create or replace function greenloop_private.supplier_return_intake_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype; p public.stock_batch_plan_lines%rowtype; d public.devices%rowtype; n integer; held integer;
begin
 if new.receiving_batch_id is null or new.deleted_at is not null then return new; end if;
 if tg_op='UPDATE' and old.receiving_batch_id is not distinct from new.receiving_batch_id and old.deleted_at is null then return new; end if;
 select * into b from public.receiving_batches where id=new.receiving_batch_id for update;
 if b.planned_quantity is null then return new; end if;
 select count(*) into n from public.jobs where receiving_batch_id=b.id and deleted_at is null and id<>new.id;
 select count(*) into held from public.supplier_returns where batch_id=b.id and device_id is null and status in ('requested','approved','returned');
 if n+held>=b.planned_quantity then raise exception 'This receipt has no unentered units available; Supplier Returns reserve part of its original quantity.' using errcode='22023'; end if;
 select * into d from public.devices where id=new.device_id;
 for p in select * from public.stock_batch_plan_lines where receiving_batch_id=b.id
  and (model is null or lower(model)=lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g')))
  and (storage_gb is null or storage_gb=d.storage_gb) and (color is null or lower(color)=lower(regexp_replace(btrim(coalesce(d.color,'')),'\s+',' ','g')))
  order by id for update loop
  select count(*) into n from public.jobs j join public.devices x on x.id=j.device_id where j.receiving_batch_id=b.id and j.deleted_at is null and j.id<>new.id
   and (p.model is null or lower(p.model)=lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g')))
   and (p.storage_gb is null or p.storage_gb=x.storage_gb) and (p.color is null or lower(p.color)=lower(regexp_replace(btrim(coalesce(x.color,'')),'\s+',' ','g')));
  select count(*) into held from public.supplier_returns where plan_line_id=p.id and device_id is null and status in ('requested','approved','returned');
  if n+held>=p.planned_quantity then raise exception 'This plan line has no unentered units available after Supplier Returns.' using errcode='22023'; end if;
 end loop;
 return new;
end; $$;
drop trigger if exists supplier_return_intake_guard on public.jobs;
create trigger supplier_return_intake_guard before insert or update of receiving_batch_id,deleted_at on public.jobs for each row execute function greenloop_private.supplier_return_intake_guard();

create or replace function public.create_supplier_return(p_payload jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype; v_device public.devices%rowtype; v_batch public.receiving_batches%rowtype;
 v_id uuid; v_job_id uuid; v_batch_id uuid; v_plan_id uuid; v_quantity integer; v_reason text; v_notes text;
 v_state jsonb; v_context jsonb; v_line jsonb; v_command jsonb; v_saved record; v_result jsonb:='[]'; v_serial text; i integer;
begin
 perform greenloop_private.require_supplier_return_access('request');
 if p_idempotency_key is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'A request object and idempotency key are required.' using errcode='22023'; end if;
 v_command:=jsonb_build_object('action','create','payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_idempotency_key::text,0));
 select * into v_saved from greenloop_private.supplier_return_commands where actor_id=auth.uid() and idempotency_key=p_idempotency_key;
 if found then
  if v_saved.command<>v_command then raise exception 'This idempotency key was used for a different request.' using errcode='22023'; end if;
  return v_saved.response;
 end if;
 v_job_id:=nullif(p_payload->>'job_id','')::uuid; v_batch_id:=nullif(p_payload->>'batch_id','')::uuid; v_plan_id:=nullif(p_payload->>'plan_line_id','')::uuid;
 v_quantity:=coalesce((p_payload->>'quantity')::integer,1); v_reason:=p_payload->>'reason'; v_notes:=nullif(btrim(p_payload->>'notes'),'');
 if v_quantity not between 1 and 1000 or v_quantity is null or v_reason is null or v_reason not in ('dead','icloud_locked','other')
  or (v_reason='other' and v_notes is null) then raise exception 'Choose a valid quantity and reason; Other requires explanatory notes.' using errcode='22023'; end if;
 if jsonb_typeof(coalesce(p_payload->'serial_numbers','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_payload->'serial_numbers','[]'::jsonb))>v_quantity then raise exception 'Provide at most one serial number per returned unit.' using errcode='22023'; end if;
 if v_job_id is not null then
  if v_quantity<>1 or v_batch_id is not null or v_plan_id is not null then raise exception 'An IMEI return must identify one job only.' using errcode='22023'; end if;
  select * into v_job from public.jobs where id=v_job_id for update;
  if v_job.id is null then raise exception 'The receiving job was not found.' using errcode='22023'; end if;
  select * into v_device from public.devices where id=v_job.device_id for update;
  if v_job.deleted_at is not null or v_device.deleted_at is not null or v_job.supplier_id is null or v_job.ownership_type<>'company_owned' or v_job.closed_at is not null
   or v_job.current_status::text in ('shipped','returned_to_customer','rma_completed','scrap','supplier_return_requested','return_pending','returned_to_supplier')
   or exists(select 1 from public.supplier_returns where device_id=v_device.id and status in ('requested','approved','returned'))
   then raise exception 'Only an active company-owned phone with a supplier can be returned once.' using errcode='22023'; end if;
  if exists(select 1 from public.jobs j where j.device_id=v_device.id and j.id<>v_job.id and j.deleted_at is null and j.closed_at is null and j.current_status::text not in ('shipped','returned_to_customer','rma_completed','scrap')) then
   raise exception 'This phone has another open job. Resolve the duplicate active jobs first.' using errcode='55000'; end if;
  if exists(select 1 from public.export_box_items where device_id=v_device.id) then raise exception 'Remove the phone from its export box before requesting a Supplier Return.' using errcode='55000'; end if;
  v_batch_id:=v_job.receiving_batch_id;
  v_state:=jsonb_build_object('job_status',v_job.current_status,'device_status',v_device.current_status,
   'orders',coalesce((select jsonb_agg(jsonb_build_object('id',id,'status',status)) from public.job_work_orders where job_id=v_job.id),'[]'::jsonb),
   'steps',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.step_status)) from public.job_work_order_steps s join public.job_work_orders o on o.id=s.work_order_id where o.job_id=v_job.id and s.step_status in ('pending','in_progress')),'[]'::jsonb),
   'parts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'status',status)) from public.job_part_requests where job_id=v_job.id and status in ('requested','partially_issued','issued','partially_installed')),'[]'::jsonb),
   'timer',coalesce((select to_jsonb(t) from public.technician_job_timers t where job_id=v_job.id),'null'::jsonb));
 else
  if v_batch_id is null then raise exception 'Choose a receipt for units without IMEI.' using errcode='22023'; end if;
  select * into v_batch from public.receiving_batches where id=v_batch_id for update;
  if v_batch.id is null or v_batch.supplier_id is null or v_batch.planned_quantity is null then raise exception 'Choose a valid supplier receipt.' using errcode='22023'; end if;
  if exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=v_batch_id) and v_plan_id is null then
   if (select count(*) from public.stock_batch_plan_lines where receiving_batch_id=v_batch_id)=1 then select id into v_plan_id from public.stock_batch_plan_lines where receiving_batch_id=v_batch_id;
   else raise exception 'Choose the receipt plan line for these unentered units.' using errcode='22023'; end if;
  end if;
  if v_plan_id is not null then
   perform 1 from public.stock_batch_plan_lines where id=v_plan_id and receiving_batch_id=v_batch_id for update;
   if not found then raise exception 'The plan line does not belong to this receipt.' using errcode='22023'; end if;
  end if;
  v_context:=greenloop_private.supplier_return_batch(v_batch_id);
  if v_quantity>(v_context->>'remaining_quantity')::integer then raise exception 'Return quantity exceeds the unentered units available on this receipt.' using errcode='22023'; end if;
  if v_plan_id is not null then
   select x into v_line from jsonb_array_elements(v_context->'plan_lines') x where (x->>'plan_line_id')::uuid=v_plan_id;
   if v_quantity>(v_line->>'remaining_quantity')::integer then raise exception 'Return quantity exceeds the unentered units available on this plan line.' using errcode='22023'; end if;
  end if;
  v_state:='{}';
 end if;
 for i in 1..v_quantity loop
  v_id:=gen_random_uuid(); v_serial:=coalesce(v_device.serial_number,nullif(btrim(p_payload->'serial_numbers'->>(i-1)),''));
  if v_job_id is null and v_serial is not null and exists(select 1 from public.devices where lower(btrim(serial_number))=lower(v_serial)) then raise exception 'This serial number already belongs to an entered phone; use its IMEI.' using errcode='22023'; end if;
  insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),v_id);
  insert into public.supplier_returns(id,device_id,job_id,batch_id,plan_line_id,supplier_id,imei_1,serial_number,model,reason,notes,requested_by,prior_state)
  values(v_id,v_device.id,v_job_id,v_batch_id,v_plan_id,coalesce(v_job.supplier_id,v_batch.supplier_id),v_device.imei_1,v_serial,coalesce(v_device.model,v_line->>'model',v_batch.planned_model),v_reason,v_notes,auth.uid(),v_state);
  if v_job_id is not null then
   update public.jobs set current_status='supplier_return_requested' where id=v_job_id;
   update public.devices set current_status='supplier_return_requested' where id=v_device.id;
   update public.job_work_order_steps set step_status='supplier_return_hold' where id in (select (x->>'id')::uuid from jsonb_array_elements(v_state->'steps') x);
   update public.job_work_orders set status='cancelled' where job_id=v_job_id and status='open';
   update public.job_part_requests set status='cancelled' where id in (select (x->>'id')::uuid from jsonb_array_elements(v_state->'parts') x);
   update public.technician_job_timers set stopped_at=now(),elapsed_seconds=greatest(0,floor(extract(epoch from now()-started_at)))::integer,stopped_by=auth.uid() where job_id=v_job_id and stopped_at is null;
  end if;
  perform greenloop_private.supplier_return_event(v_id,'requested',null,'requested',v_notes,jsonb_build_object('reason',v_reason,'serial_number',v_serial));
  v_result:=v_result||jsonb_build_array(greenloop_private.supplier_return_record(v_id));
  delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid() and return_id=v_id;
 end loop;
 v_result:=jsonb_build_object('returns',v_result);
 insert into greenloop_private.supplier_return_commands(actor_id,idempotency_key,command,response) values(auth.uid(),p_idempotency_key,v_command,v_result);
 return v_result;
end; $$;

create or replace function public.transition_supplier_return(p_return_id uuid,p_action text,p_payload jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.supplier_returns%rowtype; v_command jsonb; v_saved record; v_notes text; v_result jsonb; v_next text;
 v_request public.job_part_requests%rowtype; v_issue record; v_step uuid; v_available integer; v_condition text; v_data jsonb:='{}'; v_job uuid;
begin
 if p_action in ('approve','reject') then perform greenloop_private.require_supplier_return_access('approve');
 elsif p_action in ('handover','settlement') then perform greenloop_private.require_supplier_return_access('handover');
 elsif p_action in ('cancel','request_part_return') then perform greenloop_private.require_supplier_return_access('request');
 else raise exception 'Choose a valid Supplier Return action.' using errcode='22023'; end if;
 if p_idempotency_key is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'An action object and idempotency key are required.' using errcode='22023'; end if;
 v_command:=jsonb_build_object('action',p_action,'return_id',p_return_id,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_idempotency_key::text,0));
 select * into v_saved from greenloop_private.supplier_return_commands where actor_id=auth.uid() and idempotency_key=p_idempotency_key;
 if found then
  if v_saved.command<>v_command then raise exception 'This idempotency key was used for a different action.' using errcode='22023'; end if;
  return v_saved.response;
 end if;
 -- Same job-before-return lock order as the workshop write guard.
 select job_id into v_job from public.supplier_returns where id=p_return_id;
 if v_job is not null then perform 1 from public.jobs where id=v_job for update; end if;
 select * into r from public.supplier_returns where id=p_return_id for update;
 if r.id is null then raise exception 'Supplier Return was not found.' using errcode='22023'; end if;
 if r.archived_at is not null then raise exception 'This Supplier Return is a permanent archived audit record.' using errcode='55000'; end if;
 if r.batch_id is not null then perform 1 from public.receiving_batches where id=r.batch_id for update; end if;
 if r.device_id is not null then perform 1 from public.devices where id=r.device_id for update; end if;
 v_notes:=nullif(btrim(p_payload->>'notes'),''); v_next:=r.status;
 if p_action='approve' and r.status<>'requested' or p_action='reject' and r.status<>'requested'
  or p_action='cancel' and r.status not in ('requested','approved') or p_action='handover' and r.status<>'approved'
  or p_action='settlement' and r.status<>'returned' or p_action='request_part_return' and r.status<>'requested'
 then raise exception 'This action is not valid for the current Supplier Return status (%). Refresh the record.',r.status using errcode='55000'; end if;
 if p_action='cancel' and r.status='approved' then perform greenloop_private.require_supplier_return_access('approve'); end if;
 if p_action in ('reject','cancel') and v_notes is null then raise exception 'A reason is required to reject or cancel a return.' using errcode='22023'; end if;
 insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),r.id);
 if p_action='approve' then
  perform greenloop_private.require_supplier_return_parts_clear(r.job_id);
  v_next:='approved';
  update public.supplier_returns set status=v_next,approved_by=auth.uid(),approved_at=now(),updated_at=now() where id=r.id;
  if r.job_id is not null then
   update public.jobs set current_status='return_pending' where id=r.job_id;
   update public.devices set current_status='return_pending' where id=r.device_id;
  end if;
 elsif p_action in ('reject','cancel') then
  v_next:=case when p_action='reject' then 'rejected' else 'cancelled' end;
  -- Restore only workflow fields frozen by this feature, retaining all parts
  -- reconciliation that happened during the hold.
  if r.job_id is not null then
   update public.jobs set current_status=(r.prior_state->>'job_status')::public.job_status where id=r.job_id;
   update public.devices set current_status=(r.prior_state->>'device_status')::public.job_status where id=r.device_id;
   update public.job_work_orders o set status=x->>'status' from jsonb_array_elements(r.prior_state->'orders') x where o.id=(x->>'id')::uuid;
   update public.job_work_order_steps s set step_status=(x->>'status')::public.work_order_step_status from jsonb_array_elements(r.prior_state->'steps') x where s.id=(x->>'id')::uuid;
   update public.job_part_requests q set status=case when q.quantity_returned+q.quantity_installed>=q.quantity_requested then case when q.quantity_installed>=q.quantity_requested then 'installed' else 'unused_returned' end else x->>'status' end
    from jsonb_array_elements(r.prior_state->'parts') x where q.id=(x->>'id')::uuid;
   if r.prior_state->'timer' <> 'null'::jsonb and r.prior_state->'timer'->>'stopped_at' is null then
    update public.technician_job_timers set started_at=started_at+(now()-r.requested_at),stopped_at=null,elapsed_seconds=null,stopped_by=null where job_id=r.job_id;
   end if;
  end if;
  update public.supplier_returns set status=v_next,closed_by=auth.uid(),closed_at=now(),closure_notes=v_notes,updated_at=now() where id=r.id;
 elsif p_action='handover' then
  if nullif(btrim(p_payload->>'slip_reference'),'') is null then raise exception 'Record the return slip/reference for physical handover.' using errcode='22023'; end if;
  perform greenloop_private.require_supplier_return_parts_clear(r.job_id);
  if exists(select 1 from public.export_box_items where device_id=r.device_id) then raise exception 'Remove the phone from its export box before physical handover.' using errcode='55000'; end if;
  v_next:='returned';
  update public.supplier_returns set status=v_next,handed_over_by=auth.uid(),handed_over_at=now(),slip_reference=btrim(p_payload->>'slip_reference'),updated_at=now() where id=r.id;
  if r.job_id is not null then
   update public.jobs set current_status='returned_to_supplier',closed_at=now() where id=r.job_id;
   update public.devices set current_status='returned_to_supplier' where id=r.device_id;
  end if;
  v_data:=jsonb_build_object('slip_reference',btrim(p_payload->>'slip_reference'));
 elsif p_action='settlement' then
  if coalesce(p_payload->>'settlement_type','') not in ('replacement','credit','refund') or nullif(btrim(p_payload->>'settlement_reference'),'') is null then raise exception 'Choose replacement, credit, or refund and record its reference.' using errcode='22023'; end if;
  if r.settled_at is not null then raise exception 'Settlement is already recorded. Its permanent record cannot be overwritten.' using errcode='55000'; end if;
  if nullif(p_payload->>'amount','') is not null and (p_payload->>'amount')::numeric<0 then raise exception 'Settlement amount cannot be negative.' using errcode='22023'; end if;
  update public.supplier_returns set settlement_type=p_payload->>'settlement_type',settlement_reference=btrim(p_payload->>'settlement_reference'),settlement_amount=nullif(p_payload->>'amount','')::numeric,
   settlement_notes=v_notes,settled_by=auth.uid(),settled_at=now(),updated_at=now() where id=r.id;
  v_data:=jsonb_build_object('settlement_type',p_payload->>'settlement_type','settlement_reference',btrim(p_payload->>'settlement_reference'),'amount',nullif(p_payload->>'amount','')::numeric,'financial_posting',false);
 elsif p_action='request_part_return' then
  if r.job_id is null then raise exception 'Only entered phones have issued parts.' using errcode='22023'; end if;
  v_condition:=p_payload->>'return_reason';
  if coalesce(v_condition,'') not in ('not_needed','faulty','damaged') then raise exception 'Choose Not Needed, Faulty, or Damaged for the unused part.' using errcode='22023'; end if;
  select * into v_request from public.job_part_requests where id=(p_payload->>'part_request_id')::uuid and job_id=r.job_id for update;
  if v_request.id is null then raise exception 'The part does not belong to this phone.' using errcode='22023'; end if;
  if exists(select 1 from public.lab_part_return_requests where part_request_id=v_request.id and status='pending') then raise exception 'This part already has a pending Parts Department return request.' using errcode='55000'; end if;
  select s.id into v_step from public.job_work_order_steps s join public.job_work_orders o on o.id=s.work_order_id where o.job_id=r.job_id and s.department in ('laboratory','glass') order by s.created_at desc limit 1;
  if v_step is null then raise exception 'No laboratory step exists for this issued part. Ask Parts to reconcile the original issue.' using errcode='55000'; end if;
  -- Existing Parts review processes one issue per request; choose exactly the
  -- outstanding quantity of the oldest issue so nothing is silently dropped.
  select i.id,greatest(i.quantity_issued-i.quantity_returned-coalesce((select sum(quantity_installed) from public.part_installations where part_issue_id=i.id),0),0)::integer available
   into v_issue from public.part_issue_transactions i where i.part_request_id=v_request.id
   and i.quantity_issued-i.quantity_returned-coalesce((select sum(quantity_installed) from public.part_installations where part_issue_id=i.id),0)>0
   order by i.issued_at,i.id limit 1 for update;
  if v_issue.id is null then raise exception 'No unused issued quantity remains.' using errcode='22023'; end if;
  insert into public.lab_part_return_requests(work_order_step_id,part_request_id,job_id,device_id,part_name,quantity,return_reason,requested_by)
   values(v_step,v_request.id,r.job_id,r.device_id,v_request.part_name,v_issue.available,v_condition,auth.uid());
  v_data:=jsonb_build_object('part_request_id',v_request.id,'part_name',v_request.part_name,'quantity',v_issue.available,'return_reason',v_condition,'inventory_updated',false);
 end if;
 perform greenloop_private.supplier_return_event(r.id,p_action,r.status,v_next,v_notes,v_data);
 v_result:=greenloop_private.supplier_return_record(r.id);
 delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid() and return_id=r.id;
 insert into greenloop_private.supplier_return_commands(actor_id,idempotency_key,command,response) values(auth.uid(),p_idempotency_key,v_command,v_result);
 return v_result;
end; $$;

create or replace function greenloop_private.supplier_return_receipt_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if exists(select 1 from public.supplier_returns where batch_id=old.id) and
   (tg_op='DELETE' or (to_jsonb(new)-array['updated_at','notes'])<>(to_jsonb(old)-array['updated_at','notes'])) then
  raise exception 'This original receipt has permanent Supplier Return history; its supplier and received quantity must remain unchanged.' using errcode='55000';
 end if;
 return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists supplier_return_receipt_guard on public.receiving_batches;
create trigger supplier_return_receipt_guard before update or delete on public.receiving_batches for each row execute function greenloop_private.supplier_return_receipt_guard();

alter table public.user_page_permissions drop constraint if exists user_page_permissions_page_key_check;
alter table public.user_page_permissions add constraint user_page_permissions_page_key_check check(page_key in (
 'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass','lab_live_board','frame_department','parts','inventory',
 'final_qc','ready_stock','export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover'));
alter table public.user_page_permissions drop constraint if exists user_page_permissions_access_level_check;
alter table public.user_page_permissions add constraint user_page_permissions_access_level_check check(access_level in ('view','edit') or (access_level='none' and page_key in ('supplier_returns','supplier_return_approval','supplier_return_handover')));

create or replace function public.get_my_page_access_v2()
returns table(page_key text,access_level text) language sql stable security definer set search_path=pg_catalog,public as $$
 select p.page_key,p.access_level from public.user_page_permissions p join public.user_profiles u on u.id=p.user_id where p.user_id=auth.uid() and u.is_active
 union all select k,'edit'::text from unnest(array['supplier_returns','supplier_return_approval','supplier_return_handover']) k
 where public.is_active_staff() and public.has_role(array['owner','super_admin']::public.app_role_key[])
 and not exists(select 1 from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key=k);
$$;
create or replace function public.get_user_page_access_matrix_v2()
returns table(user_id uuid,login_username text,full_name text,email text,is_active boolean,page_permissions jsonb)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not coalesce(public.has_role(array['super_admin','owner']::public.app_role_key[]),false) then raise exception 'Only Super Admin and Owner can view user access.' using errcode='42501'; end if;
 return query select u.id,u.login_username,u.full_name,u.email,u.is_active,
  (case when exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=u.id and ro.role_key::text in ('owner','super_admin'))
   then '{"supplier_returns":"edit","supplier_return_approval":"edit","supplier_return_handover":"edit"}'::jsonb else '{}'::jsonb end)
  || coalesce((select jsonb_object_agg(p.page_key,p.access_level) from public.user_page_permissions p where p.user_id=u.id),'{}'::jsonb)
 from public.user_profiles u order by u.is_active desc,lower(coalesce(u.full_name,'')),lower(coalesce(u.login_username,''));
end; $$;

create or replace function public.get_open_stock_entry_batches_with_lines()
returns table(batch_id uuid,batch_number text,supplier_id uuid,supplier_code text,supplier_name text,stock_channel text,planned_label text,planned_quantity integer,entered_quantity integer,remaining_quantity integer,receiving_notes text,planned_lines jsonb)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not public.is_active_staff() or not (public.has_page_access('imei_entry') or public.has_page_access('stock_received')) then raise exception 'Stock Received or IMEI Entry view permission is required.' using errcode='42501'; end if;
 return query select b.id,b.batch_number,s.id,s.supplier_code,case when public.get_my_partner_name_access() then s.company_name else null end,c.channel_name,
  case when jsonb_array_length(x.data->'plan_lines')=1 and x.data->'plan_lines'->0->>'model' is null then 'Quantity-only stock' when jsonb_array_length(x.data->'plan_lines')>0 then 'Mixed stock plan' else coalesce(b.planned_model,'Stock batch') end,
  b.planned_quantity,(x.data->>'entered_quantity')::integer,(x.data->>'remaining_quantity')::integer,b.notes,
  coalesce((select jsonb_agg(p||jsonb_build_object('planned_quantity',(p->>'received_quantity')::integer)) from jsonb_array_elements(x.data->'plan_lines') p),'[]'::jsonb)
 from public.receiving_batches b join public.stock_channels c on c.id=b.stock_channel_id join public.suppliers s on s.id=b.supplier_id
 cross join lateral(select greenloop_private.supplier_return_batch(b.id) data) x
 where b.planned_quantity is not null and c.is_active and s.is_active and s.deleted_at is null and (x.data->>'remaining_quantity')::integer>0 order by b.received_at desc;
end; $$;
create or replace function public.get_open_stock_entry_batches()
returns table(batch_id uuid,batch_number text,supplier_id uuid,supplier_code text,supplier_name text,stock_channel text,planned_model text,planned_quantity integer,entered_quantity integer,remaining_quantity integer,receiving_notes text)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 return query select x.batch_id,x.batch_number,x.supplier_id,x.supplier_code,x.supplier_name,x.stock_channel,x.planned_label,x.planned_quantity,x.entered_quantity,x.remaining_quantity,x.receiving_notes from public.get_open_stock_entry_batches_with_lines() x;
end; $$;

create or replace function public.get_overview_workflow_counts()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not coalesce(public.is_active_staff(),false) or not coalesce(public.has_page_access('overview'),false) then raise exception 'Overview view permission is required.' using errcode='42501'; end if;
 return jsonb_build_object(
  'stock_received',coalesce((select sum(planned_quantity)::integer from public.receiving_batches),0),
  'imei_entry',coalesce((select sum((greenloop_private.supplier_return_batch(id)->>'remaining_quantity')::integer)::integer from public.receiving_batches where planned_quantity is not null),0),
  'initial_qc',(select count(*) from public.jobs where deleted_at is null and current_status='initial_qc_pending'),
  'lab_glass',(select count(*) from public.jobs where deleted_at is null and current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')),
  'parts',(select count(*) from public.job_part_requests r join public.jobs j on j.id=r.job_id where j.deleted_at is null and j.current_status::text not in ('supplier_return_requested','return_pending','returned_to_supplier') and r.status in ('requested','partially_issued','issued','partially_installed')),
  'final_qc',(select count(*) from public.jobs where deleted_at is null and current_status='final_qc_pending'),
  'frame',(select count(*) from public.jobs where deleted_at is null and current_status in ('frame_pending','frame_in_progress')),
  'ready_stock',(select count(*) from public.jobs j where j.deleted_at is null and j.current_status in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment') and exists(select 1 from public.final_qc_inspections i where i.job_id=j.id and i.result='pass')),
  'export_data',(select count(*) from public.export_box_items),
  'supplier_return_requested',(select count(*) from public.supplier_returns where status='requested' and archived_at is null),
  'supplier_return_pending',(select count(*) from public.supplier_returns where status='approved' and archived_at is null),
  'returned_to_supplier',(select count(*) from public.supplier_returns where status='returned' and archived_at is null));
end; $$;
-- BEGIN REVIEWED EXISTING RPC DEFINITIONS
create or replace function public.save_user_page_access(
  p_user_id uuid, p_full_name text, p_login_username text, p_is_active boolean, p_page_keys text[]
)
returns boolean language plpgsql security definer set search_path = public
as $$
declare
  v_username text := lower(nullif(regexp_replace(btrim(coalesce(p_login_username, '')), '\s+', '', 'g'), ''));
  v_pages text[] := coalesce(array(select distinct unnest(p_page_keys)), array[]::text[]);
  v_allowed_pages constant text[] := array[
    'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass',
    'lab_live_board','frame_department','parts','inventory','final_qc','ready_stock',
    'export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover'
  ]::text[];
  v_is_super_admin boolean := public.has_role(array['super_admin']::public.app_role_key[]);
  v_existing_user_access boolean;
begin
  if not public.has_role(array['super_admin', 'owner']::public.app_role_key[]) then raise exception 'Only Super Admin and Owner can manage user access.' using errcode = '42501'; end if;
  if not exists (select 1 from public.user_profiles where id = p_user_id) then raise exception 'The selected user account was not found.' using errcode = '22023'; end if;
  if v_username is null or v_username !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Username must use 3 to 40 letters, numbers, dots, underscores, or hyphens.' using errcode = '22023'; end if;
  if cardinality(v_pages) = 0 then raise exception 'Select at least one page for this user.' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_pages) page_key where not page_key = any(v_allowed_pages)) then raise exception 'One or more selected pages are not valid.' using errcode = '22023'; end if;
  select exists (select 1 from public.user_page_permissions where user_id = p_user_id and page_key = 'user_access') into v_existing_user_access;
  if not v_is_super_admin and v_existing_user_access is distinct from ('user_access' = any(v_pages)) then raise exception 'Only Super Admin can change User Access permission.' using errcode = '42501'; end if;
  if p_user_id = auth.uid() and (not coalesce(p_is_active, true) or not ('user_access' = any(v_pages))) then raise exception 'You cannot remove your own active User Access permission.' using errcode = '22023'; end if;

  update public.user_profiles set full_name = coalesce(btrim(p_full_name), ''), login_username = v_username, is_active = coalesce(p_is_active, true) where id = p_user_id;
  delete from public.user_page_permissions where user_id = p_user_id;
  insert into public.user_page_permissions (user_id, page_key, assigned_by) select p_user_id, page_key, auth.uid() from unnest(v_pages) page_key;

  delete from public.user_roles assignment using public.roles role where assignment.user_id = p_user_id and assignment.role_id = role.id and role.role_key::text <> 'super_admin';
  insert into public.user_roles (user_id, role_id, assigned_by)
  select distinct p_user_id, role.id, auth.uid() from public.roles role
  where role.role_key::text = any(array_remove(array[
    case when v_pages && array['overview','reports']::text[] then 'manager' end,
    case when v_pages && array['stock_received','imei_entry']::text[] then 'receiving' end,
    case when 'imei_search' = any(v_pages) then 'shipping' end,
    case when 'initial_qc' = any(v_pages) then 'initial_qc' end,
    case when v_pages && array['lab_glass','lab_live_board']::text[] then 'technician' end,
    case when v_pages && array['lab_glass','lab_live_board']::text[] then 'glass' end,
    case when 'frame_department' = any(v_pages) then 'frame' end,
    case when v_pages && array['parts','inventory']::text[] then 'parts' end,
    case when 'final_qc' = any(v_pages) then 'final_qc' end,
    case when v_pages && array['ready_stock','ready_stock_journey']::text[] then 'production' end,
    case when 'export_boxes' = any(v_pages) then 'shipping' end,
    case when 'user_access' = any(v_pages) then 'owner' end
  ]::text[], null)) on conflict (user_id, role_id) do update set assigned_by = excluded.assigned_by, assigned_at = now();
  return true;
end;
$$;

create or replace function public.save_user_page_access_v2(
  p_user_id uuid,
  p_full_name text,
  p_login_username text,
  p_is_active boolean,
  p_page_permissions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page_keys text[];
begin
  if jsonb_typeof(coalesce(p_page_permissions, '{}'::jsonb)) <> 'object' then
    raise exception 'Page permissions must be a valid object.' using errcode = '22023';
  end if;
  if exists(
    select 1
    from jsonb_each_text(coalesce(p_page_permissions, '{}'::jsonb)) as permission
    where permission.value not in ('view', 'edit') and not (permission.value='none' and permission.key in ('supplier_returns','supplier_return_approval','supplier_return_handover'))
  ) then
    raise exception 'Each selected page must be Only View or Entry Allowed.' using errcode = '22023';
  end if;

  select coalesce(array_agg(permission.key), array[]::text[])
  into v_page_keys
  from jsonb_each_text(coalesce(p_page_permissions, '{}'::jsonb)) as permission;

  perform public.save_user_page_access(
    p_user_id, p_full_name, p_login_username, p_is_active, v_page_keys
  );

  update public.user_page_permissions as saved
  set access_level = permission.value,
      assigned_by = auth.uid(),
      assigned_at = now()
  from jsonb_each_text(p_page_permissions) as permission
  where saved.user_id = p_user_id and saved.page_key = permission.key;

  return true;
end;
$$;

create or replace function public.receive_stock_batch_imei(
  p_batch_id uuid,
  p_imei_1 text,
  p_model text,
  p_storage_gb integer,
  p_color text,
  p_battery_health smallint
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
  if p_battery_health is null or p_battery_health not between 0 and 100 then
    raise exception 'Battery health must be between 0 and 100.' using errcode = '22023';
  end if;

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
      device_number, imei_1, model, storage_gb, color, battery_health,
      current_owner_type, current_location_id, current_status, notes, created_by
    )
    values (
      null, v_imei, v_model, p_storage_gb, v_color, p_battery_health,
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
    jsonb_build_object('batch_number', v_batch.batch_number, 'stock_channel', v_batch.receiving_source), auth.uid()
  );

  v_entered := v_entered + 1;
  return query select v_device_id, v_device_number, v_job_id, v_job_number, v_existing,
    v_entered, v_batch.planned_quantity, (greenloop_private.supplier_return_batch(p_batch_id)->>'remaining_quantity')::integer;
end;
$$;

create or replace function public.receive_stock_batch_imei_with_plan(
  p_batch_id uuid, p_imei_1 text, p_model text, p_storage_gb integer, p_color text, p_battery_health smallint
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
  select * from public.receive_stock_batch_imei(p_batch_id, p_imei_1, p_model, p_storage_gb, p_color, p_battery_health);
end;
$$;

create or replace function greenloop_private.supplier_return_plan_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare b uuid;
begin
 b:=case when tg_op='DELETE' then old.receiving_batch_id else new.receiving_batch_id end;
 perform 1 from public.receiving_batches where id=b for update;
 if exists(select 1 from public.supplier_returns where batch_id=b) then raise exception 'Receipt plan lines with Supplier Return history must remain unchanged.' using errcode='55000'; end if;
 return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists supplier_return_plan_guard on public.stock_batch_plan_lines;
create trigger supplier_return_plan_guard before insert or update or delete on public.stock_batch_plan_lines for each row execute function greenloop_private.supplier_return_plan_guard();

-- Restricted Data keeps permanent returns/events while deleting operational
-- phone rows. Only its fully authorized, snapshotted execution calls this helper.
create or replace function greenloop_private.archive_supplier_returns_for_deletion(p_audit_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare h public.deletion_history%rowtype; r public.supplier_returns%rowtype; v_before jsonb; v_snapshot jsonb; v_actor text;
begin
 select * into h from public.deletion_history where id=p_audit_id and record_type='restricted_data_deletion' and deleted_by=auth.uid();
 if h.id is null then raise exception 'An authorized Restricted Data audit is required.' using errcode='42501'; end if;
 perform greenloop_private.require_deletion_access(h.record_data->>'scope');
 select coalesce(nullif(full_name,''),login_username,'Staff') into v_actor from public.user_profiles where id=auth.uid();
 for v_before in select value from jsonb_array_elements(coalesce(h.record_data->'supplier_returns_to_archive','[]'::jsonb)) loop
  select * into r from public.supplier_returns where id=(v_before->>'id')::uuid for update;
  if r.id is null or to_jsonb(r)<>v_before or r.archived_at is not null then raise exception 'Supplier Return data changed. Preview the deletion again.' using errcode='40001'; end if;
  select jsonb_build_object('device_id',r.device_id,'job_id',r.job_id,'batch_id',r.batch_id,'plan_line_id',r.plan_line_id,
   'supplier_code',s.supplier_code,'supplier_name',s.company_name,'batch_number',b.batch_number,'job_number',j.job_number,
   'purchase_cost',j.purchase_cost) into v_snapshot from public.suppliers s
   left join public.receiving_batches b on b.id=r.batch_id left join public.jobs j on j.id=r.job_id where s.id=r.supplier_id;
  insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),r.id);
  insert into public.supplier_return_events(return_id,action,from_status,to_status,actor_id,actor_name,notes,event_data)
   values(r.id,'archived_by_restricted_data',r.status,r.status,auth.uid(),coalesce(v_actor,'Staff'),h.deletion_reason,jsonb_build_object('deletion_audit_id',h.id,'scope',h.record_data->>'scope'));
  update public.supplier_returns set source_snapshot=v_snapshot,archived_at=now(),archived_by=auth.uid(),deletion_audit_id=h.id,
   device_id=null,job_id=null,batch_id=null,plan_line_id=null,updated_at=now() where id=r.id;
  delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid() and return_id=r.id;
 end loop;
end; $$;


-- BEGIN RESTRICTED DATA COMPATIBILITY
create or replace function greenloop_private.deletion_plan(p_scope text,p_imei text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_imei text := nullif(btrim(p_imei),'');
  v_devices uuid[]; v_jobs uuid[]; v_orders uuid[]; v_steps uuid[];
  v_inspections uuid[]; v_requests uuid[]; v_issues uuid[];
  v_batches uuid[]; v_boxes uuid[] := '{}'::uuid[];
  v_table text; v_rows jsonb; v_plan jsonb := '{}'::jsonb;
  v_filter text; v_fk record; v_cross_link boolean;
begin
  perform greenloop_private.require_deletion_access(p_scope);
  if p_scope='single' and (v_imei is null or v_imei !~ '^[0-9]{15}$') then
    raise exception 'Enter the complete 15-digit IMEI.' using errcode='22023';
  elsif p_scope='all' and v_imei is not null then
    raise exception 'All-IMEI reset must not include an IMEI filter.' using errcode='22023';
  end if;

  -- A consistent snapshot is also used at execution. Table locks prevent new
  -- children or edits between the rechecked preview and the final deletion.
  -- This intentionally briefly pauses writers, while normal reads continue.
  for v_table in select unnest(greenloop_private.restricted_tables() || array['part_inventory','part_stock_lots','part_lot_status_balances','data_change_history','deletion_history','supplier_returns','supplier_return_events']) order by 1 loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  select coalesce(array_agg(d.id order by d.id),'{}'::uuid[]) into v_devices
  from public.devices d where p_scope='all' or d.imei_1=v_imei or d.imei_2=v_imei;
  if p_scope='single' and cardinality(v_devices)=0 then
    raise exception 'No device matches that exact IMEI.' using errcode='22023';
  elsif p_scope='single' and cardinality(v_devices)>1 then
    raise exception 'This IMEI matches multiple devices. Correct the duplicate IMEI first.' using errcode='22023';
  end if;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_jobs from public.jobs where device_id=any(v_devices);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_orders from public.job_work_orders where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_steps from public.job_work_order_steps where work_order_id=any(v_orders);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_inspections from (
    select id from public.initial_qc_inspections where job_id=any(v_jobs)
    union select id from public.final_qc_inspections where job_id=any(v_jobs)
  ) q;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_requests from public.job_part_requests where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_issues from public.part_issue_transactions where part_request_id=any(v_requests);
  select coalesce(array_agg(b.id),'{}'::uuid[]) into v_batches from public.receiving_batches b
    where (p_scope='all' or exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and j.id=any(v_jobs)))
      and not exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and not(j.id=any(v_jobs)));
  if to_regclass('public.export_boxes') is not null and to_regclass('public.export_box_items') is not null then
    select coalesce(array_agg(b.id),'{}'::uuid[]) into v_boxes from public.export_boxes b
      where (p_scope='all' or exists(select 1 from public.export_box_items i where i.box_id=b.id and (i.device_id=any(v_devices) or i.job_id=any(v_jobs))))
        and not exists(select 1 from public.export_box_items i where i.box_id=b.id and not(i.device_id=any(v_devices) or i.job_id=any(v_jobs)));
  end if;

  -- Explicit allowlist: a newly added dependency must be reviewed, rather than
  -- silently being removed by an ON DELETE CASCADE without an audit snapshot.
  for v_fk in
    select child.relname as child_table, parent.relname as parent_table
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    where c.contype='f' and pn.nspname='public'
      and parent.relname=any(greenloop_private.restricted_tables())
      and not(ns.nspname='public' and (child.relname=any(greenloop_private.restricted_tables())
        or (child.relname='supplier_returns' and c.confdeltype='r'
          and parent.relname in ('devices','jobs','receiving_batches','stock_batch_plan_lines')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' when 'jobs' then 'job_id' when 'receiving_batches' then 'batch_id' else 'plan_line_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])
        or (child.relname='data_change_history' and c.confdeltype='n' and parent.relname in ('devices','jobs')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' else 'job_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])))
  loop
    raise exception 'Unreviewed dependency % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
  end loop;

  foreach v_table in array greenloop_private.restricted_tables() || array['data_change_history'] loop
    if to_regclass('public.'||v_table) is null then continue; end if;
    if p_scope='all' and v_table not in ('part_stock_movements','data_change_history') then v_filter := 'true';
    elsif v_table='devices' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($1)';
    elsif v_table='receiving_batches' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($8)';
    elsif v_table='stock_batch_plan_lines' then v_filter := '(to_jsonb(t)->>''receiving_batch_id'')::uuid=any($8)';
    elsif v_table='export_boxes' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($9)';
    else
      v_filter := '(to_jsonb(t)->>''device_id'')::uuid=any($1) or (to_jsonb(t)->>''job_id'')::uuid=any($2) or (to_jsonb(t)->>''work_order_id'')::uuid=any($3) or (to_jsonb(t)->>''work_order_step_id'')::uuid=any($4) or (to_jsonb(t)->>''inspection_id'')::uuid=any($5) or (to_jsonb(t)->>''part_request_id'')::uuid=any($6) or (to_jsonb(t)->>''part_issue_id'')::uuid=any($7)';
    end if;
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from public.%I t where %s',v_table,v_filter)
      into v_rows using v_devices,v_jobs,v_orders,v_steps,v_inspections,v_requests,v_issues,v_batches,v_boxes;
    v_plan := v_plan || jsonb_build_object(v_table,v_rows);
  end loop;
  -- Detect unplanned cross-links even if a future FK uses an existing table.
  -- This includes CASCADE/SET NULL FKs which otherwise could modify extra rows.
  for v_fk in
    select child.relname as child_table,parent.relname as parent_table,
      string_agg(format('to_jsonb(t)->%L = r->%L',ca.attname,pa.attname),' and ' order by k.ord) as predicate
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    cross join lateral unnest(c.conkey,c.confkey) with ordinality k(child_att,parent_att,ord)
    join pg_attribute ca on ca.attrelid=c.conrelid and ca.attnum=k.child_att
    join pg_attribute pa on pa.attrelid=c.confrelid and pa.attnum=k.parent_att
    where c.contype='f' and ns.nspname='public' and pn.nspname='public'
      and child.relname=any(greenloop_private.restricted_tables())
      and parent.relname=any(greenloop_private.restricted_tables())
    group by c.oid,child.relname,parent.relname
  loop
    execute format('select exists(select 1 from public.%I t where exists(select 1 from jsonb_array_elements($1) r where %s) and not exists(select 1 from jsonb_array_elements($2) r where r=to_jsonb(t)))',v_fk.child_table,v_fk.predicate)
      into v_cross_link using coalesce(v_plan->v_fk.parent_table,'[]'::jsonb),coalesce(v_plan->v_fk.child_table,'[]'::jsonb);
    if v_cross_link then
      raise exception 'Unreviewed cross-link % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
    end if;
  end loop;
  return jsonb_build_object('scope',p_scope,'imei',v_imei,'records',v_plan,
    'supplier_returns_to_archive',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from public.supplier_returns r where r.archived_at is null and (p_scope='all' or r.device_id=any(v_devices) or r.job_id=any(v_jobs) or r.batch_id=any(v_batches))),'[]'::jsonb));
end;
$$;

create or replace function public.execute_greenloop_deletion(
  p_scope text,p_imei text,p_deletion_code text,p_confirmation text,p_reason text,p_selection_token text
)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public set lock_timeout='5s' set statement_timeout='90s' as $$
declare
  v_plan jsonb; v_table text; v_rows jsonb; v_row jsonb;
  v_audit_id uuid := gen_random_uuid(); v_actor jsonb; v_counts jsonb;
  v_record_count bigint := 0; v_deleted bigint; v_restored numeric := 0;
  v_stock_before jsonb; v_stock_after jsonb;
  v_lots_before jsonb := '[]'::jsonb; v_balances_before jsonb := '[]'::jsonb;
  v_lots_after jsonb := '[]'::jsonb; v_balances_after jsonb := '[]'::jsonb;
begin
  perform greenloop_private.require_deletion_access(p_scope);
  if coalesce(p_deletion_code,'')<>'1213' then raise exception 'Incorrect deletion code.' using errcode='42501'; end if;
  if p_reason is null or char_length(btrim(p_reason))<5 or char_length(btrim(p_reason))>1000 then
    raise exception 'Enter a deletion reason (5 to 1000 characters).' using errcode='22023';
  end if;
  if p_confirmation is distinct from (case when p_scope='single' then 'DELETE '||btrim(p_imei) else 'DELETE ALL IMEIS' end) then
    raise exception 'Type the exact confirmation shown in the preview.' using errcode='22023';
  end if;
  v_plan := greenloop_private.deletion_plan(p_scope,p_imei);
  if p_selection_token is null or p_selection_token<>md5(v_plan::text||auth.uid()::text) then
    raise exception 'The selected data changed. Preview it again before deleting.' using errcode='40001';
  end if;
  select jsonb_object_agg(key,jsonb_array_length(value)),sum(jsonb_array_length(value))
    into v_counts,v_record_count from jsonb_each(v_plan->'records') where key<>'data_change_history';
  if coalesce(v_record_count,0)=0 then raise exception 'There are no IMEI records or phone processes to delete.' using errcode='22023'; end if;
  select jsonb_build_object('id',id,'name',to_jsonb(p)->>'full_name','email',to_jsonb(p)->>'email')
    into v_actor from public.user_profiles p where id=auth.uid();
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_before from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_before from public.part_stock_lots l
      where l.id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_before from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;

  -- Archive complete ORIGINAL rows (including technician IDs, issue/return
  -- details and existing correction audit links) before any mutation.
  insert into public.deletion_history(id,deleted_by,record_type,record_id,record_label,deletion_method,deletion_reason,record_data)
    values(v_audit_id,auth.uid(),'restricted_data_deletion',v_audit_id::text,
      case when p_scope='single' then 'Single IMEI: '||btrim(p_imei) else 'All IMEIs reset' end,
      'hard_delete',btrim(p_reason),v_plan||jsonb_build_object('audit_id',v_audit_id,'actor',v_actor,'counts',v_counts,'inventory_before',v_stock_before,
        'professional_lots_before',v_lots_before,'professional_balances_before',v_balances_before,
        'professional_inventory_policy','Physical lot quantities and statuses retained. Removing phone history is not a physical stock return.'));

  -- Detach only the exact Supplier Return rows included in the preview token;
  -- the return and its events remain as permanent, readable audit records.
  perform greenloop_private.archive_supplier_returns_for_deletion(v_audit_id);

  -- Retain the established stock rule: only uninstalled, unreturned units are
  -- restored. Installed/damaged/manual parts are never added to available stock.
  with remaining as (
    select i.inventory_part_id,sum(greatest(i.quantity_issued-coalesce((select sum(x.quantity_installed) from public.part_installations x where x.part_issue_id=i.id),0)-i.quantity_returned,0)) as quantity
    from public.part_issue_transactions i
    where i.id::text in(select r->>'id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r)
    group by i.inventory_part_id
  ), changed as (
    update public.part_inventory i set stock_quantity=i.stock_quantity+r.quantity::integer
      from remaining r where i.id=r.inventory_part_id and r.quantity>0 returning r.quantity
  ) select coalesce(sum(quantity),0) into v_restored from changed;

  insert into greenloop_private.ledger_delete_capabilities(transaction_id,backend_pid,movement_id,audit_id)
    select txid_current(),pg_backend_pid(),(r->>'id')::uuid,v_audit_id
    from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r;

  foreach v_table in array greenloop_private.restricted_tables() loop
    v_rows := coalesce(v_plan->'records'->v_table,'[]'::jsonb);
    if jsonb_array_length(v_rows)=0 then continue; end if;
    -- Compare the complete archived row, not caller-provided identifiers.
    execute format('delete from public.%I t where exists(select 1 from jsonb_array_elements($1) r where r=to_jsonb(t))',v_table) using v_rows;
    get diagnostics v_deleted=row_count;
    if v_deleted<>jsonb_array_length(v_rows) then
      raise exception 'Selected % records changed during deletion. No changes saved.',v_table using errcode='40001';
    end if;
  end loop;
  if exists(select 1 from greenloop_private.ledger_delete_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid()) then
    raise exception 'Ledger deletion did not consume its exact audit authorization.' using errcode='55000';
  end if;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_after from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_after from public.part_stock_lots l
      where l.id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_after from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if v_lots_after<>v_lots_before or v_balances_after<>v_balances_before then
    raise exception 'Professional inventory changed during phone deletion. No changes saved.' using errcode='40001';
  end if;
  update public.deletion_history set record_data=record_data||jsonb_build_object('restored_part_units',v_restored,'inventory_after',v_stock_after,
    'professional_lots_after',v_lots_after,'professional_balances_after',v_balances_after)
    where id=v_audit_id;
  return jsonb_build_object('audit_id',v_audit_id,'scope',p_scope,
    'deleted_devices',jsonb_array_length(v_plan->'records'->'devices'),
    'deleted_jobs',jsonb_array_length(v_plan->'records'->'jobs'),
    'deleted_records',v_record_count,'restored_part_units',v_restored,'counts',v_counts);
end;
$$;

-- Preserve the Restricted Data installation receipt for its reviewed extension.
update greenloop_private.restricted_routine_receipt r set definition_hash=md5(pg_get_functiondef(to_regprocedure(r.function_identity)))
where to_regprocedure(r.function_identity) in ('greenloop_private.deletion_plan(text,text)'::regprocedure,'public.execute_greenloop_deletion(text,text,text,text,text,text)'::regprocedure);
revoke all on function greenloop_private.archive_supplier_returns_for_deletion(uuid) from public,anon,authenticated;
-- END RESTRICTED DATA COMPATIBILITY

-- BEGIN SUPPLIER PROGRESS INTEGRATION
create or replace function public.get_supplier_stock_progress(
  p_date_from date,
  p_date_to date
)
returns table (
  supplier_id uuid,
  supplier_code text,
  supplier_name text,
  model text,
  storage_label text,
  batch_numbers text,
  stock_channels text,
  planned_quantity integer,
  received_quantity integer,
  imei_entry_pending integer,
  initial_qc_pending integer,
  lab_glass_pending integer,
  parts_pending integer,
  final_qc_pending integer,
  ready_quantity integer,
  exported_quantity integer,
  other_quantity integer,
  last_received_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_page_access('reports') then
    raise exception 'Your account does not have Reports permission.' using errcode = '42501';
  end if;

  if p_date_from is null or p_date_to is null or p_date_from > p_date_to then
    raise exception 'Select a valid From date and To date.' using errcode = '22023';
  end if;

  return query
  with selected_batches as (
    select
      batch.id,
      batch.batch_number,
      batch.received_at,
      batch.planned_model,
      batch.planned_quantity,
      supplier.id as supplier_id,
      supplier.supplier_code,
      case when public.get_my_partner_name_access() then supplier.company_name else null end as supplier_name,
      coalesce(channel.channel_name, batch.receiving_source, 'Unknown') as stock_channel
    from public.receiving_batches batch
    join public.suppliers supplier on supplier.id = batch.supplier_id
    left join public.stock_channels channel on channel.id = batch.stock_channel_id
    where timezone('Asia/Dubai', batch.received_at)::date between p_date_from and p_date_to
      and supplier.deleted_at is null
  ), plan_source as (
    select
      selected.id as batch_id,
      selected.supplier_id,
      selected.supplier_code,
      selected.supplier_name,
      selected.batch_number,
      selected.stock_channel,
      selected.received_at,
      plan.model,
      plan.storage_gb,
      plan.planned_quantity,
      (select count(*)::integer from public.supplier_returns r where r.plan_line_id=plan.id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')) as return_reserved
    from selected_batches selected
    join public.stock_batch_plan_lines plan on plan.receiving_batch_id = selected.id

    union all

    select
      selected.id,
      selected.supplier_id,
      selected.supplier_code,
      selected.supplier_name,
      selected.batch_number,
      selected.stock_channel,
      selected.received_at,
      coalesce(nullif(btrim(selected.planned_model), ''), 'Unspecified'),
      null::integer,
      coalesce(selected.planned_quantity, 0),
      (select count(*)::integer from public.supplier_returns r where r.batch_id=selected.id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned'))
    from selected_batches selected
    where not exists (
      select 1 from public.stock_batch_plan_lines plan where plan.receiving_batch_id = selected.id
    )
  ), planned as (
    select
      source.supplier_id,
      source.supplier_code,
      source.supplier_name,
      lower(regexp_replace(btrim(coalesce(source.model, 'Unspecified')), '\s+', ' ', 'g')) as model_key,
      min(coalesce(nullif(btrim(source.model), ''), 'Unspecified')) as model,
      coalesce(string_agg(distinct source.storage_gb::text || ' GB', ', ' order by source.storage_gb::text || ' GB') filter (where source.storage_gb is not null), 'Not planned') as storage_label,
      string_agg(distinct source.batch_number, ', ' order by source.batch_number) as batch_numbers,
      string_agg(distinct source.stock_channel, ', ' order by source.stock_channel) as stock_channels,
      sum(source.planned_quantity)::integer as planned_quantity,
      sum(source.return_reserved)::integer as return_reserved,
      max(source.received_at) as last_received_at
    from plan_source source
    group by source.supplier_id, source.supplier_code, source.supplier_name,
      lower(regexp_replace(btrim(coalesce(source.model, 'Unspecified')), '\s+', ' ', 'g'))
  ), actual as (
    select
      selected.supplier_id,
      selected.supplier_code,
      selected.supplier_name,
      case when exists(select 1 from public.stock_batch_plan_lines p where p.receiving_batch_id=selected.id and p.model is null) or (not exists(select 1 from public.stock_batch_plan_lines p where p.receiving_batch_id=selected.id) and nullif(btrim(selected.planned_model),'') is null) then 'unspecified' else lower(regexp_replace(btrim(coalesce(device.model, 'Unspecified')), '\s+', ' ', 'g')) end as model_key,
      min(coalesce(nullif(btrim(device.model), ''), 'Unspecified')) as model,
      coalesce(string_agg(distinct device.storage_gb::text || ' GB', ', ' order by device.storage_gb::text || ' GB') filter (where device.storage_gb is not null), '—') as storage_label,
      string_agg(distinct selected.batch_number, ', ' order by selected.batch_number) as batch_numbers,
      string_agg(distinct selected.stock_channel, ', ' order by selected.stock_channel) as stock_channels,
      count(distinct job.id)::integer as received_quantity,
      count(distinct job.id) filter (
        where export_item.id is null
          and job.current_status::text in ('received', 'initial_qc_pending', 'initial_qc_completed', 'no_work_required')
      )::integer as initial_qc_pending,
      count(distinct job.id) filter (
        where export_item.id is null
          and job.current_status::text in (
            'work_required', 'laboratory_pending', 'laboratory_in_progress',
            'glass_pending', 'glass_in_progress', 'frame_pending', 'frame_in_progress', 'rework'
          )
      )::integer as lab_glass_pending,
      count(distinct job.id) filter (
        where export_item.id is null and job.current_status::text = 'parts_pending'
      )::integer as parts_pending,
      count(distinct job.id) filter (
        where export_item.id is null and job.current_status::text in ('final_qc_pending', 'qc_failed')
      )::integer as final_qc_pending,
      count(distinct job.id) filter (
        where export_item.id is null
          and job.current_status::text in (
            'qc_passed', 'production_pending', 'production_completed',
            'ready_for_packing', 'ready_for_shipment'
          )
      )::integer as ready_quantity,
      count(distinct job.id) filter (
        where export_item.id is not null or job.current_status::text = 'shipped'
      )::integer as exported_quantity,
      count(distinct job.id) filter (
        where export_item.id is null
          and job.current_status::text not in (
            'received', 'initial_qc_pending', 'initial_qc_completed', 'no_work_required',
            'work_required', 'laboratory_pending', 'laboratory_in_progress',
            'glass_pending', 'glass_in_progress', 'frame_pending', 'frame_in_progress', 'rework',
            'parts_pending', 'final_qc_pending', 'qc_failed', 'qc_passed',
            'production_pending', 'production_completed', 'ready_for_packing',
            'ready_for_shipment', 'shipped','supplier_return_requested','return_pending','returned_to_supplier'
          )
      )::integer as other_quantity,
      max(job.received_at) as last_received_at
    from selected_batches selected
    join public.jobs job on job.receiving_batch_id = selected.id and job.deleted_at is null
    join public.devices device on device.id = job.device_id and device.deleted_at is null
    left join public.export_box_items export_item on export_item.job_id = job.id
    group by selected.supplier_id, selected.supplier_code, selected.supplier_name,
      case when exists(select 1 from public.stock_batch_plan_lines p where p.receiving_batch_id=selected.id and p.model is null) or (not exists(select 1 from public.stock_batch_plan_lines p where p.receiving_batch_id=selected.id) and nullif(btrim(selected.planned_model),'') is null) then 'unspecified' else lower(regexp_replace(btrim(coalesce(device.model, 'Unspecified')), '\s+', ' ', 'g')) end
  )
  select
    coalesce(plan.supplier_id, entered.supplier_id),
    coalesce(plan.supplier_code, entered.supplier_code),
    coalesce(plan.supplier_name, entered.supplier_name),
    coalesce(entered.model, plan.model, 'Unspecified'),
    case
      when entered.storage_label is not null and plan.storage_label is not null and entered.storage_label <> plan.storage_label
        then plan.storage_label || ' / Entered: ' || entered.storage_label
      else coalesce(entered.storage_label, plan.storage_label, '—')
    end,
    coalesce(entered.batch_numbers, plan.batch_numbers, '—'),
    coalesce(entered.stock_channels, plan.stock_channels, '—'),
    coalesce(plan.planned_quantity, entered.received_quantity, 0)::integer,
    coalesce(entered.received_quantity, 0)::integer,
    greatest(coalesce(plan.planned_quantity, entered.received_quantity, 0) - coalesce(entered.received_quantity, 0) - coalesce(plan.return_reserved,0), 0)::integer,
    coalesce(entered.initial_qc_pending, 0)::integer,
    coalesce(entered.lab_glass_pending, 0)::integer,
    coalesce(entered.parts_pending, 0)::integer,
    coalesce(entered.final_qc_pending, 0)::integer,
    coalesce(entered.ready_quantity, 0)::integer,
    coalesce(entered.exported_quantity, 0)::integer,
    coalesce(entered.other_quantity, 0)::integer,
    greatest(plan.last_received_at, entered.last_received_at)
  from planned plan
  full join actual entered
    on entered.supplier_id = plan.supplier_id
   and entered.model_key = plan.model_key
  order by
    lower(coalesce(plan.supplier_code, entered.supplier_code)),
    lower(coalesce(entered.model, plan.model));
end;
$$;
-- END SUPPLIER PROGRESS INTEGRATION

-- Read-only installation receipt; changing a protected routine or disabling a
-- guard invalidates the version rather than reporting a partial installation.
create table if not exists greenloop_private.supplier_return_installation (
 object_identity text primary key, object_kind text not null, definition_hash text not null
);
revoke all on greenloop_private.supplier_return_installation from public,anon,authenticated;
create or replace function public.get_greenloop_supplier_returns_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare m record; actual text;
begin
 if not exists(select 1 from greenloop_private.supplier_return_installation) then return null; end if;
 for m in select * from greenloop_private.supplier_return_installation loop
  if m.object_kind='function' then
   if to_regprocedure(m.object_identity) is null then return null; end if;
   actual:=md5(pg_get_functiondef(to_regprocedure(m.object_identity)));
  else
   select md5(pg_get_triggerdef(t.oid)||t.tgenabled::text) into actual from pg_trigger t where t.tgrelid=split_part(m.object_identity,':',1)::regclass and t.tgname=split_part(m.object_identity,':',2);
  end if;
  if actual is distinct from m.definition_hash then return null; end if;
 end loop;
 if has_function_privilege('anon','public.create_supplier_return(jsonb,uuid)','execute')
   or has_function_privilege('anon','public.transition_supplier_return(uuid,text,jsonb,uuid)','execute')
   or has_table_privilege('authenticated','public.supplier_returns','insert,update,delete')
   or has_table_privilege('authenticated','public.supplier_return_events','insert,update,delete') then return null; end if;
 return '20260925-supplier-returns-1';
end; $$;

do $$
declare p record;
begin
 for p in select oid::regprocedure as signature from pg_proc where pronamespace='greenloop_private'::regnamespace and (proname like 'supplier_return_%' or proname like 'require_supplier_return_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',p.signature);
 end loop;
 for p in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname in (
  'get_supplier_return_context','lookup_supplier_return_device','list_supplier_returns','get_supplier_return_detail','create_supplier_return','transition_supplier_return') loop
  execute format('revoke all on function %s from public,anon,authenticated',p.signature);
  execute format('grant execute on function %s to authenticated',p.signature);
 end loop;
end; $$;
revoke all on function public.get_greenloop_supplier_returns_version() from public;
grant execute on function public.get_greenloop_supplier_returns_version() to anon,authenticated;

delete from greenloop_private.supplier_return_installation;
insert into greenloop_private.supplier_return_installation(object_identity,object_kind,definition_hash)
 select n.nspname||'.'||p.proname||'('||oidvectortypes(p.proargtypes)||')','function',md5(pg_get_functiondef(p.oid))
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where
 (n.nspname='greenloop_private' and (p.proname like 'supplier_return_%' or p.proname like 'require_supplier_return_%' or p.proname in ('archive_supplier_returns_for_deletion','deletion_plan'))) or
 (n.nspname='public' and p.proname in ('get_greenloop_supplier_returns_version','get_supplier_return_context','lookup_supplier_return_device','list_supplier_returns','get_supplier_return_detail',
 'create_supplier_return','transition_supplier_return','execute_greenloop_deletion','save_user_page_access','save_user_page_access_v2','get_my_page_access_v2','get_user_page_access_matrix_v2',
 'get_supplier_stock_progress','get_open_stock_entry_batches','get_open_stock_entry_batches_with_lines','get_overview_workflow_counts','receive_stock_batch_imei','receive_stock_batch_imei_with_plan'));
insert into greenloop_private.supplier_return_installation(object_identity,object_kind,definition_hash)
 select n.nspname||'.'||c.relname||':'||t.tgname,'trigger',md5(pg_get_triggerdef(t.oid)||t.tgenabled::text)
 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and t.tgname like 'supplier_return%';
do $$begin
 if public.get_greenloop_supplier_returns_version() is distinct from '20260925-supplier-returns-1' then raise exception 'Supplier Return installation verification failed; no transactional changes were installed.' using errcode='55000'; end if;
end;$$;
notify pgrst,'reload schema';
commit;
select public.get_greenloop_supplier_returns_version() as installed_supplier_returns_version;
