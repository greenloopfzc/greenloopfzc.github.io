-- Read-only duplicate notifications. No intake, routing, or deletion rules change.
begin;
create schema if not exists greenloop_private;

create or replace function public.get_imei_duplicate_stage_v1(p_imei text)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $stage$
declare
 v_imei text:=regexp_replace(coalesce(p_imei,''),'\D','','g');
 v_device_id uuid; v_job_id uuid; v_status text; v_department text; v_stage text;
begin
 -- Operators need the same minimal location notice without needing access to
 -- the separate IMEI Search report or any supplier/cost/name permission.
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not exists (
  select 1 from unnest(array['stock_received','imei_entry','initial_qc','lab_glass',
   'parts','final_qc','frame_department','ready_stock','export_boxes','supplier_returns',
   'supplier_return_approval','supplier_return_handover','imei_search']) as allowed(page_key)
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
  return jsonb_build_object('found',false,'current_stage',null);
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
 end;
 v_stage:=coalesce(case v_department
  when 'parts' then 'Parts'
  when 'laboratory' then 'Lab & Glass — Laboratory'
  when 'glass' then 'Lab & Glass — Glass'
  when 'frame' then 'Frame Department'
  when 'final_qc' then 'Final QC (QC 2)'
 end,v_stage);
 return jsonb_build_object('found',true,'current_stage',v_stage);
end;
$stage$;
revoke all on function public.get_imei_duplicate_stage_v1(text) from public,anon;
grant execute on function public.get_imei_duplicate_stage_v1(text) to authenticated;

create table if not exists greenloop_private.qc_duplicate_stage_installation(
 function_identity text primary key,definition_hash text not null);
revoke all on greenloop_private.qc_duplicate_stage_installation from public,anon,authenticated;
insert into greenloop_private.qc_duplicate_stage_installation
select 'public.get_imei_duplicate_stage_v1(text)',md5(pg_get_functiondef(p.oid)) from pg_proc p
where p.oid='public.get_imei_duplicate_stage_v1(text)'::regprocedure
on conflict(function_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_qc_duplicate_stage_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when exists (
  select 1 from greenloop_private.qc_duplicate_stage_installation i
  where i.function_identity='public.get_imei_duplicate_stage_v1(text)'
   and to_regprocedure(i.function_identity) is not null
   and md5(pg_get_functiondef(to_regprocedure(i.function_identity)))=i.definition_hash
 ) and not has_function_privilege('anon','public.get_imei_duplicate_stage_v1(text)','EXECUTE')
   and has_function_privilege('authenticated','public.get_imei_duplicate_stage_v1(text)','EXECUTE')
 then '20261003-qc-duplicate-stage-1' end;
$version$;
revoke all on function public.get_qc_duplicate_stage_version() from public;
grant execute on function public.get_qc_duplicate_stage_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_qc_duplicate_stage_version() as installed_qc_duplicate_stage_version;
