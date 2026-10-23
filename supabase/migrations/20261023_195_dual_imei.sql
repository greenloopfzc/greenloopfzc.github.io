-- Keep secondary IMEI private; one device and one main workflow IMEI.
begin;
do $$begin if public.get_production_recent_entries_version() is distinct from '20261023-production-recent-entries-1' then raise exception 'Verify the existing Recent Production Entries update first.';end if;end;$$;

create or replace function greenloop_private.reject_secondary_imei(p_imei text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare main text;v text:=btrim(coalesce(p_imei,''));begin
 if v !~ '^[0-9]{15}$' then return;end if;
 select d.imei_1 into main from public.devices d where d.imei_2=v and d.imei_1<>v order by d.id limit 1;
 if main is not null then raise exception 'Duplicate phone: this is IMEI 2 of IMEI 1 %. Use IMEI 1 to continue.',main using errcode='23505',detail=jsonb_build_object('reason','secondary_imei','primary_imei',main)::text;end if;
end;$$;
create or replace function greenloop_private.reject_secondary_args(p_args jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare value text;begin
 perform greenloop_private.reject_secondary_imei(p_args->>'p_imei');perform greenloop_private.reject_secondary_imei(p_args->>'p_imei_1');
 if jsonb_typeof(p_args->'p_payload'->'imeis')='array' then for value in select jsonb_array_elements_text(p_args->'p_payload'->'imeis') loop perform greenloop_private.reject_secondary_imei(value);end loop;end if;
end;$$;

-- Reuse the existing permission boundary. Both nested and outer workflow calls
-- reject secondary identifiers before any business operation can execute.
do $$declare d text;begin
 select pg_get_functiondef('greenloop_private.begin_capability(text,jsonb)'::regprocedure) into d;
 if strpos(d,'-- dual-imei-guard-20261023')=0 then
  if strpos(d,'update greenloop_private.capability_scope set depth=depth+1')=0 or strpos(d,'perform greenloop_private.require_capability_rule(r,p_args);')=0 then raise exception 'Unrecognized permission boundary.';end if;
  d:=replace(d,'update greenloop_private.capability_scope set depth=depth+1',E'perform greenloop_private.reject_secondary_args(p_args);\n  update greenloop_private.capability_scope set depth=depth+1');
  d:=replace(d,'perform greenloop_private.require_capability_rule(r,p_args);',E'perform greenloop_private.require_capability_rule(r,p_args);\n -- dual-imei-guard-20261023\n perform greenloop_private.reject_secondary_args(p_args);');execute d;
 end if;
end;$$;

-- Serialize both IMEI columns and serials, including direct authorized writes.
-- No existing identities or historical rows are changed by installation.
create or replace function greenloop_private.guard_device_identity_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$declare k text;other public.devices%rowtype;begin
 if new.imei_2 is not null and (new.imei_2 !~ '^[0-9]{15}$' or new.imei_2=new.imei_1) then raise exception 'A distinct valid 15-digit secondary IMEI is required.' using errcode='22023';end if;
 for k in select distinct x from unnest(array['imei:'||new.imei_1,'imei:'||new.imei_2,'serial:'||upper(nullif(btrim(new.serial_number),''))])x where x is not null order by x loop perform pg_advisory_xact_lock(hashtextextended('gl-device-identity:'||k,0));end loop;
 select d.* into other from public.devices d where d.id<>new.id and (d.imei_1=new.imei_1 or d.imei_2=new.imei_1 or (new.imei_2 is not null and (d.imei_1=new.imei_2 or d.imei_2=new.imei_2))) order by d.id limit 1;
 if other.id is not null then
  if other.imei_2=new.imei_1 then raise exception 'Duplicate phone: this is IMEI 2 of IMEI 1 %. Use IMEI 1 to continue.',other.imei_1 using errcode='23505',detail=jsonb_build_object('reason','secondary_imei','primary_imei',other.imei_1)::text;end if;
  raise exception 'Duplicate IMEI: this phone identity already belongs to IMEI 1 %.',other.imei_1 using errcode='23505';
 end if;
 if nullif(btrim(new.serial_number),'') is not null and exists(select 1 from public.devices d where d.id<>new.id and upper(btrim(d.serial_number))=upper(btrim(new.serial_number))) then raise exception 'This Serial Number already belongs to another phone.' using errcode='23505';end if;
 return new;
end;$$;
drop trigger if exists aa_device_identity_guard_v1 on public.devices;
create trigger aa_device_identity_guard_v1 before insert or update of imei_1,imei_2,serial_number on public.devices for each row execute function greenloop_private.guard_device_identity_v1();

create or replace function greenloop_private.lock_cable_identity_v1(p_imei_1 text,p_imei_2 text,p_serial text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare k text;begin
 for k in select distinct x from unnest(array['imei:'||btrim(p_imei_1),'imei:'||nullif(btrim(p_imei_2),''),'serial:'||upper(nullif(btrim(p_serial),''))])x where x is not null order by x loop perform pg_advisory_xact_lock(hashtextextended('gl-device-identity:'||k,0));end loop;
end;$$;
create or replace function greenloop_private.store_cable_identity_v1(p_imei_1 text,p_imei_2 text,p_serial_number text,p_specification_region text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare d public.devices%rowtype;v2 text:=nullif(btrim(p_imei_2),'');sn text:=nullif(btrim(p_serial_number),'');region text:=nullif(btrim(p_specification_region),'');begin
 if btrim(coalesce(p_imei_1,'')) !~ '^[0-9]{15}$' then raise exception 'A valid main IMEI is required.' using errcode='22023';end if;
 if v2 is not null and (v2 !~ '^[0-9]{15}$' or v2=btrim(p_imei_1)) then raise exception 'The secondary IMEI must be a distinct 15-digit value.' using errcode='22023';end if;
 if length(sn)>128 or length(region)>128 then raise exception 'Cable identity details are too long.' using errcode='22023';end if;
 perform greenloop_private.lock_cable_identity_v1(p_imei_1,v2,sn);
 select * into d from public.devices where imei_1=btrim(p_imei_1) and deleted_at is null for update;
 if d.id is null then raise exception 'The main IMEI was not found.' using errcode='22023';end if;
 if v2 is not null and d.imei_2 is not null and v2<>d.imei_2 then raise exception 'A different secondary IMEI is already linked. Use authorized IMEI correction.' using errcode='23505';end if;
 if sn is not null and nullif(btrim(d.serial_number),'') is not null and upper(sn)<>upper(btrim(d.serial_number)) then raise exception 'A different Serial Number is already linked. Use authorized IMEI correction.' using errcode='23505';end if;
 update public.devices set imei_2=coalesce(v2,imei_2),serial_number=coalesce(sn,serial_number),specification_region=coalesce(region,specification_region) where id=d.id;
 return true;
end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('receive_stock_batch_imei_with_identity_v1','{"page":"imei_entry","capability":"entry"}'),
 ('save_stock_device_identity_v1','{"any":[{"page":"imei_entry","capability":"entry"},{"page":"ready_stock_journey","capability":"edit"},{"page":"stock_received","capability":"entry"}]}')
 on conflict(rpc_name) do update set rule=excluded.rule;
create or replace function public.receive_stock_batch_imei_with_identity_v1(
 p_batch_id uuid,p_imei_1 text,p_model text,p_storage_gb integer,p_color text,p_battery_health smallint,p_brand text,p_platform text,p_battery_health_unavailable boolean,
 p_imei_2 text default null,p_serial_number text default null,p_specification_region text default null)
returns table(device_id uuid,device_number text,job_id uuid,job_number text,existing_device boolean,entered_quantity integer,planned_quantity integer,remaining_quantity integer)
language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.begin_capability('receive_stock_batch_imei_with_identity_v1',jsonb_build_object('p_imei_1',p_imei_1));
 perform greenloop_private.lock_cable_identity_v1(p_imei_1,p_imei_2,p_serial_number);
 return query select * from public.receive_stock_batch_imei_with_plan_v2(p_batch_id,p_imei_1,p_model,p_storage_gb,p_color,p_battery_health,p_brand,p_platform,p_battery_health_unavailable);
 perform greenloop_private.store_cable_identity_v1(p_imei_1,p_imei_2,p_serial_number,p_specification_region);
 perform greenloop_private.end_capability();
end;$$;
create or replace function public.save_stock_device_identity_v1(p_imei_1 text,p_imei_2 text default null,p_serial_number text default null,p_specification_region text default null)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare r boolean;begin
 perform greenloop_private.begin_capability('save_stock_device_identity_v1',jsonb_build_object('p_imei_1',p_imei_1));
 r:=greenloop_private.store_cable_identity_v1(p_imei_1,p_imei_2,p_serial_number,p_specification_region);
 perform greenloop_private.end_capability();return r;
end;$$;
create or replace function public.get_imei_duplicate_stage_v1(p_imei text)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $stage$
declare
 v_imei text:=regexp_replace(coalesce(p_imei,''),'\D','','g');
 v_device_id uuid; v_job_id uuid; v_status text; v_department text; v_stage text;
begin
 -- Operators need the same minimal location notice without needing access to
 -- the separate IMEI Search report or any supplier/cost/name permission.
 if auth.uid() is null or coalesce((select tv_only from greenloop_private.damage_tv_settings where user_id=auth.uid()),false) or not coalesce(public.is_active_staff(),false) or not exists (
  select 1 from unnest(array['stock_received','imei_entry','initial_qc','lab_glass',
   'parts','final_qc','frame_department','ready_stock','export_boxes','supplier_returns',
   'supplier_return_approval','supplier_return_handover','imei_search','ready_stock_journey']) as allowed(page_key)
  where coalesce((select p.access_level in ('view','edit') from public.user_page_permissions p
    where p.user_id=auth.uid() and p.page_key=allowed.page_key),
   public.has_role(array['owner','super_admin']::public.app_role_key[]),false)
 ) then
  raise exception 'Workflow page permission is required to check the current stage.' using errcode='42501';
 end if;
 if v_imei !~ '^[0-9]{15}$' then
  raise exception 'Scan a valid 15-digit IMEI.' using errcode='22023';
 end if;

 -- Select the latest live job first. Historical transfers/events and old box
 -- memberships must not override a phone that has since returned for rework.
 select d.id,j.id,coalesce(j.current_status::text,d.current_status::text)
 into v_device_id,v_job_id,v_status
 from public.devices d
 left join lateral (
  select j.id,j.current_status from public.jobs j
  where j.device_id=d.id and j.deleted_at is null
  order by j.received_at desc,j.created_at desc,j.id desc limit 1
 ) j on true
 where (d.imei_1=v_imei or d.imei_2=v_imei) and d.deleted_at is null
 order by (d.imei_1=v_imei) desc,d.id limit 1;
 if v_device_id is null then
  return jsonb_build_object('found',false,'current_stage',null,'primary_imei',null,'matched_type',null);
 end if;

 -- A generic rework/work-required state can be clarified by an active step
 -- from its latest work order. Pending or completed steps are not locations.
 if v_status in ('work_required','rework','qc_failed','initial_qc_completed','no_work_required') then
  select case when count(distinct s.department)=1 then min(s.department::text) end
  into v_department
  from public.job_work_order_steps s
  where s.work_order_id=(select w.id from public.job_work_orders w where w.job_id=v_job_id
   order by w.created_at desc,w.id desc limit 1)
   and s.step_status::text='in_progress';
 end if;
 v_stage:=case v_status
  when 'received' then 'Stock Received'
  when 'initial_qc_pending' then 'Initial QC (QC 1)'
  when 'initial_qc_completed' then 'Initial QC (QC 1) â€” completed'
  when 'work_required' then 'Work required â€” department not recorded'
  when 'no_work_required' then 'Initial QC (QC 1) â€” no work required'
  when 'parts_pending' then 'Parts'
  when 'laboratory_pending' then 'Lab & Glass â€” Laboratory'
  when 'laboratory_in_progress' then 'Lab & Glass â€” Laboratory'
  when 'glass_pending' then 'Lab & Glass â€” Glass'
  when 'glass_in_progress' then 'Lab & Glass â€” Glass'
  when 'frame_pending' then 'Frame Department'
  when 'frame_in_progress' then 'Frame Department'
  when 'final_qc_pending' then 'Final QC (QC 2)'
  when 'qc_failed' then 'Final QC (QC 2) â€” failed'
  when 'rework' then 'Rework â€” department not recorded'
  when 'qc_passed' then 'Ready Stock'
  when 'production_pending' then 'Ready Stock'
  when 'production_completed' then 'Ready Stock'
  when 'ready_for_packing' then 'Ready Stock'
  when 'ready_for_shipment' then 'Ready Stock'
  when 'shipped' then 'Export / Shipped'
  when 'ready_for_customer_return' then 'Ready for customer return'
  when 'returned_to_customer' then 'Returned to customer'
  when 'shop_stock' then 'Shop stock'
  when 'rma_received' then 'RMA â€” received'
  when 'rma_qc_pending' then 'RMA â€” QC'
  when 'rma_work_pending' then 'RMA â€” work pending'
  when 'rma_rework' then 'RMA â€” rework'
  when 'rma_qc_passed' then 'RMA â€” QC passed'
  when 'rma_ready_return' then 'RMA â€” ready for return'
  when 'rma_ready_export' then 'RMA â€” ready for export'
  when 'rma_completed' then 'RMA â€” completed'
  when 'scrap' then 'Scrap'
  when 'supplier_return_requested' then 'Stock Return â€” requested'
  when 'return_pending' then 'Stock Return â€” pending'
  when 'returned_to_supplier' then 'Returned to supplier'
  else null
 end;
 v_stage:=coalesce(case v_department
  when 'parts' then 'Parts'
  when 'laboratory' then 'Lab & Glass â€” Laboratory'
  when 'glass' then 'Lab & Glass â€” Glass'
  when 'frame' then 'Frame Department'
  when 'final_qc' then 'Final QC (QC 2)'
 end,v_stage);
 return (select jsonb_build_object('found',true,'current_stage',v_stage,'primary_imei',d.imei_1,'matched_type',case when d.imei_1=v_imei then 'primary' else 'secondary' end) from public.devices d where d.id=v_device_id);
end;
$stage$;

-- Initial QC's identifier lookup must not load a secondary scan into an editable row.
do $$declare f record;d text;begin
 select p.*,pg_get_functiondef(p.oid) ddl into strict f from pg_proc p where p.oid='public.get_initial_qc_job_by_identifier(text)'::regprocedure;
 if strpos(f.prosrc,'-- dual-imei-lookup-20261023')=0 then
  d:=f.prosrc;
  if strpos(d,'return query select')>0 then d:=replace(d,'return query select',E'-- dual-imei-lookup-20261023\n perform greenloop_private.reject_secondary_imei(p_identifier);return query select');
  elsif strpos(d,'result:=')>0 then d:=replace(d,'result:=',E'-- dual-imei-lookup-20261023\n perform greenloop_private.reject_secondary_imei(p_identifier);result:=');
  elsif strpos(d,'if v_identifier is null then')>0 then d:=replace(d,'if v_identifier is null then',E'-- dual-imei-lookup-20261023\n perform greenloop_private.reject_secondary_imei(p_identifier);if v_identifier is null then');
  else raise exception 'Unrecognized Initial QC lookup.';end if;
  execute replace(f.ddl,f.prosrc,d);
 end if;
end;$$;

revoke all on function public.receive_stock_batch_imei_with_identity_v1(uuid,text,text,integer,text,smallint,text,text,boolean,text,text,text),public.save_stock_device_identity_v1(text,text,text,text) from public,anon;
grant execute on function public.receive_stock_batch_imei_with_identity_v1(uuid,text,text,integer,text,smallint,text,text,boolean,text,text,text),public.save_stock_device_identity_v1(text,text,text,text) to authenticated;
do $$declare r record;begin for r in select p.oid::regprocedure::text id from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['reject_secondary_imei','reject_secondary_args','guard_device_identity_v1','lock_cable_identity_v1','store_cable_identity_v1']) loop execute format('revoke all on function %s from public,anon,authenticated',r.id);end loop;end;$$;

-- Refresh only the reviewed changed definitions, retaining all old version guards.
update greenloop_private.page_capability_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity not in ('catalog','rules') and to_regprocedure(identity)='greenloop_private.begin_capability(text,jsonb)'::regprocedure;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r) where identity='rules';
update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='public.get_initial_qc_job_by_identifier(text)'::regprocedure;
update greenloop_private.qc_duplicate_stage_installation set definition_hash=md5(pg_get_functiondef(to_regprocedure(function_identity))) where to_regprocedure(function_identity)='public.get_imei_duplicate_stage_v1(text)'::regprocedure;
create table if not exists greenloop_private.dual_imei_installation(identity text primary key,hash text not null);
alter table greenloop_private.dual_imei_installation enable row level security;
revoke all on greenloop_private.dual_imei_installation from public,anon,authenticated;
insert into greenloop_private.dual_imei_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where
 (p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['reject_secondary_imei','reject_secondary_args','guard_device_identity_v1','lock_cable_identity_v1','store_cable_identity_v1','begin_capability']))
 or (p.pronamespace='public'::regnamespace and p.proname=any(array['get_imei_duplicate_stage_v1','get_initial_qc_job_by_identifier','receive_stock_batch_imei_with_identity_v1','save_stock_device_identity_v1']))
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_dual_imei_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_production_recent_entries_version()='20261023-production-recent-entries-1'
 and (select count(*)=10 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.dual_imei_installation)
 and exists(select 1 from pg_trigger where tgrelid='public.devices'::regclass and tgname='aa_device_identity_guard_v1' and tgenabled='O' and tgtype=23 and tgfoid='greenloop_private.guard_device_identity_v1()'::regprocedure)
 and not has_function_privilege('anon','public.receive_stock_batch_imei_with_identity_v1(uuid,text,text,integer,text,smallint,text,text,boolean,text,text,text)','EXECUTE')
 and not has_function_privilege('anon','public.save_stock_device_identity_v1(text,text,text,text)','EXECUTE')
 and not exists(select 1 from greenloop_private.dual_imei_installation where identity like 'greenloop_private.%' and (has_function_privilege('authenticated',identity,'EXECUTE') or has_function_privilege('anon',identity,'EXECUTE')))
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.dual_imei_installation'::regclass)
 then '20261023-dual-imei-1' end;$$;
revoke all on function public.get_dual_imei_version() from public;
grant execute on function public.get_dual_imei_version() to anon,authenticated;
do $$begin if public.get_dual_imei_version() is distinct from '20261023-dual-imei-1' then raise exception 'Dual IMEI installation verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_dual_imei_version() as installed_dual_imei_version;
