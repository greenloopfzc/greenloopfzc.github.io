-- Aggregate badges only. No business records or selected permissions are changed.
begin;
do $$begin
 if public.get_parts_tabs_boundary_version()is distinct from '20261107-parts-tabs-boundary-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 or public.get_workflow_live_notifications_version()is distinct from '20261017-workflow-live-notifications-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 then raise exception 'Verified stock, Parts boundary and live notifications are required.';end if;
 if to_regprocedure('public.get_sidebar_counts_version()')is not null then
  if public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'then raise exception 'Existing Sidebar Counts integrity needs review.';end if;
 end if;
end;$$;
create or replace function greenloop_private.sbn_can(p text)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(public.has_page_capability_v1(p,'view'),false);
$$;
create or replace function greenloop_private.sbn_counts()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb:='{}';qc jsonb;n bigint;
begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())then raise exception 'Active staff access required.'using errcode='42501';end if;
 if greenloop_private.sbn_can('stock_received')then
  select coalesce(sum(planned_quantity),0)into n from public.receiving_batches;
  result:=result||jsonb_build_object('stock_received',n);
 end if;
 if greenloop_private.sbn_can('imei_entry')then
  select coalesce(sum(greatest(0,b.planned_quantity-coalesce(x.n,0))),0)into n from public.receiving_batches b
  left join lateral(select count(distinct d.id)n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.receiving_batch_id=b.id and j.deleted_at is null)x on true;
  result:=result||jsonb_build_object('imei_entry',n);
 end if;
 if greenloop_private.sbn_can('initial_qc')then
  qc:=greenloop_private.qcn_counts();result:=result||qc;
 end if;
 if greenloop_private.sbn_can('lab_glass')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department in('laboratory','glass')and s.step_status='in_progress'and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','parts_pending');
  result:=result||jsonb_build_object('lab_glass',n);
 end if;
 if greenloop_private.sbn_can('parts')then
  select count(distinct imei)into n from(
   select d.imei_1 imei from greenloop_private.parts_flow_orders o join greenloop_private.parts_flow_requests m on m.order_id=o.id join public.job_part_requests p on p.id=m.request_id join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null
   where o.completed_at is null and o.cycle=greenloop_private.pf_cycle(o.job_id)and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and p.status<>'cancelled'and p.quantity_requested>p.quantity_issued
   union select imei from greenloop_private.pp_returns()where status='pending')pending;
  result:=result||jsonb_build_object('parts',n);
 end if;
 if greenloop_private.sbn_can('final_qc')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='final_qc'and s.step_status='in_progress'and j.current_status in('final_qc_pending','qc_failed');
  result:=result||jsonb_build_object('final_qc',n);
 end if;
 if greenloop_private.sbn_can('frame_department')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='frame'and s.step_status='in_progress'and j.current_status in('frame_pending','frame_in_progress');
  result:=result||jsonb_build_object('frame',n);
 end if;
 if greenloop_private.sbn_can('ready_stock')then
  select count(distinct d.id)into n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null
  where j.deleted_at is null and j.current_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
  and exists(select 1 from greenloop_private.qdr_ready_outcomes f where f.job_id=j.id and f.result='pass');
  result:=result||jsonb_build_object('ready_stock',n);
 end if;
 if greenloop_private.sbn_can('accounts')then
  select count(*)into n from greenloop_private.box_workflow w join public.export_boxes b on b.id=w.box_id where w.state='accounts';
  result:=result||jsonb_build_object('accounts',n);
 end if;
 if greenloop_private.sbn_can('export_boxes')then
  select count(*)into n from public.export_boxes b left join greenloop_private.box_workflow w on w.box_id=b.id
  where coalesce(w.state,case when b.box_status='open'then 'draft'else 'legacy'end)in('draft','recheck')and exists(select 1 from public.export_box_items i where i.box_id=b.id);
  result:=result||jsonb_build_object('box_entry',n);
 end if;
 if greenloop_private.sbn_can('stock_exported')then
  select count(distinct i.device_id)into n from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id and w.state='exported'join public.jobs j on j.id=i.job_id and j.deleted_at is null join public.devices d on d.id=i.device_id and d.deleted_at is null where j.current_status='shipped';
  result:=result||jsonb_build_object('stock_exported',n);
 end if;
 if greenloop_private.sbn_can('ready_stock_journey')then
  select count(distinct d.id)into n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.deleted_at is null;
  result:=result||jsonb_build_object('stock_journey',n);
 end if;
 if greenloop_private.sbn_can('supplier_returns')then
  select count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))into n from public.supplier_returns where archived_at is null and status in('requested','approved');
  result:=result||jsonb_build_object('supplier_returns',n);
 end if;
 return result;
end;$$;
revoke all on function greenloop_private.sbn_can(text),greenloop_private.sbn_counts()from public,anon,authenticated;
create or replace function public.get_sidebar_notification_counts_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.sbn_counts();end;$$;
revoke all on function public.get_sidebar_notification_counts_v1()from public,anon,authenticated;
grant execute on function public.get_sidebar_notification_counts_v1()to authenticated;
insert into greenloop_private.office_routines values('public.get_sidebar_notification_counts_v1()','greenloop_private.sbn_counts()',md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure)),md5(pg_get_functiondef('public.get_sidebar_notification_counts_v1()'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_sidebar_notification_counts_v1','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
-- Extend the existing token-only policy, retaining the office boundary.
alter policy workflow_notification_signal_read on public.workflow_notification_signal using(
 (public.has_page_capability_v1('initial_qc','view')or public.has_page_capability_v1('lab_glass','view')or public.has_page_capability_v1('parts','view')or public.has_page_capability_v1('final_qc','view')or public.has_page_capability_v1('frame_department','view')or public.has_page_capability_v1('stock_received','view')or public.has_page_capability_v1('imei_entry','view')or public.has_page_capability_v1('ready_stock','view')or public.has_page_capability_v1('accounts','view')or public.has_page_capability_v1('export_boxes','view')or public.has_page_capability_v1('stock_exported','view')or public.has_page_capability_v1('ready_stock_journey','view')or public.has_page_capability_v1('supplier_returns','view'))and(select public.greenloop_network_allowed_v1()));
update greenloop_private.workflow_notification_installation set definition_hash=(select md5(pg_get_expr(polqual,polrelid))from pg_policy where polrelid='public.workflow_notification_signal'::regclass and polname='workflow_notification_signal_read')where object_name='read_policy';
create table if not exists greenloop_private.sidebar_counts_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.sidebar_counts_installation enable row level security;
revoke all on greenloop_private.sidebar_counts_installation from public,anon,authenticated;
do $$declare target text;t text;begin
 foreach target in array array['public.receiving_batches','public.devices','public.export_boxes','public.export_box_items','public.supplier_returns','public.final_qc_inspections','greenloop_private.box_workflow','greenloop_private.qc_saved_issuance','greenloop_private.parts_flow_orders','greenloop_private.parts_flow_returns']loop
  execute format('drop trigger if exists greenloop_sidebar_signal on %s',target);
  execute format('create constraint trigger greenloop_sidebar_signal after insert or update or delete on %s deferrable initially deferred for each row execute function greenloop_private.signal_workflow_change()',target);
  execute format('drop trigger if exists greenloop_sidebar_signal_truncate on %s',target);
  execute format('create trigger greenloop_sidebar_signal_truncate after truncate on %s for each statement execute function greenloop_private.signal_workflow_change()',target);
  foreach t in array array['greenloop_sidebar_signal','greenloop_sidebar_signal_truncate']loop
   insert into greenloop_private.sidebar_counts_installation values('trigger',target||':'||t,(select md5(pg_get_triggerdef(oid))from pg_trigger where tgrelid=target::regclass and tgname=t))on conflict(identity)do update set hash=excluded.hash;
  end loop;
 end loop;
end;$$;
create or replace function public.get_sidebar_counts_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_complete_stock_lists_version()='20261105-complete-stock-lists-1'and public.get_workflow_live_notifications_version()='20261017-workflow-live-notifications-1'
 and(select count(*)=24 and bool_and(coalesce(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else(select md5(pg_get_triggerdef(t.oid))from pg_trigger t where t.tgrelid=to_regclass(split_part(identity,':',1))and t.tgname=split_part(identity,':',2)and t.tgenabled='O')end,false))from greenloop_private.sidebar_counts_installation)
 and not has_function_privilege('anon','public.get_sidebar_notification_counts_v1()','execute')and has_function_privilege('authenticated','public.get_sidebar_notification_counts_v1()','execute')
 and not has_function_privilege('authenticated','greenloop_private.sbn_counts()','execute')and not has_function_privilege('anon','greenloop_private.sbn_counts()','execute')
 and not has_function_privilege('authenticated','greenloop_private.sbn_can(text)','execute')and not has_function_privilege('anon','greenloop_private.sbn_can(text)','execute')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_sidebar_notification_counts_v1'and rule='{"read":true}'::jsonb)
 and not has_table_privilege('authenticated','greenloop_private.sidebar_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.sidebar_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.sidebar_counts_installation'::regclass and relrowsecurity)
 then '20261107-sidebar-counts-1'end;
$$;
revoke all on function public.get_sidebar_counts_version()from public;grant execute on function public.get_sidebar_counts_version()to anon,authenticated;
insert into greenloop_private.sidebar_counts_installation select 'function',s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.sbn_can(text)','greenloop_private.sbn_counts()','public.get_sidebar_notification_counts_v1()','public.get_sidebar_counts_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Sidebar counts verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_sidebar_counts_version()as installed_sidebar_counts_version;
