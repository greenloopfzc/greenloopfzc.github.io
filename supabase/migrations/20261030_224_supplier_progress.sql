-- Read-only receipt/model progress. No stock or workflow records are modified.
begin;
do $$begin
 if public.get_restricted_scopes_version()is distinct from '20261030-restricted-scopes-1'then raise exception 'Install and verify Restricted Data scopes first.';end if;
end;$$;

create or replace function public.get_supplier_progress_v2(p_date_from date,p_date_to date)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;names boolean;
begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_access('reports'),false)then raise exception 'Reports permission is required.'using errcode='42501';end if;
 if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Select a valid From date and To date.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with batches as materialized(
  select b.id batch_id,b.batch_number,b.invoice_number,b.received_at,b.supplier_id,s.supplier_code,
   case when names then s.company_name end supplier_name,coalesce(c.channel_name,b.receiving_source,'Unknown')stock_channel,
   coalesce(b.planned_quantity,(select sum(p.planned_quantity)::integer from public.stock_batch_plan_lines p where p.receiving_batch_id=b.id),0)receipt_quantity
  from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id left join public.stock_channels c on c.id=b.stock_channel_id
  where b.received_at>=p_date_from::timestamp at time zone 'Asia/Dubai'and b.received_at<(p_date_to+1)::timestamp at time zone 'Asia/Dubai'and s.deleted_at is null
 ), phones as materialized(
  -- A rework job must not count the same physical phone twice in its receipt.
  select distinct on(j.receiving_batch_id,j.device_id)b.batch_id,j.id job_id,j.device_id,j.current_status::text status,d.imei_1 imei,
   coalesce(nullif(btrim(d.model),''),'Unspecified')model,d.storage_gb,d.color,
   exists(select 1 from public.export_box_items x where x.job_id=j.id)exported
  from batches b join public.jobs j on j.receiving_batch_id=b.batch_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  order by j.receiving_batch_id,j.device_id,j.received_at desc,j.id desc
 ), returns as materialized(
  select b.batch_id,r.id return_id,r.device_id,r.job_id,r.imei_1 imei,r.return_number,r.status,
   coalesce(nullif(btrim(r.model),''),nullif(btrim(d.model),''),nullif(btrim(p.model),''),'Unentered stock')model,
   coalesce(d.storage_gb,p.storage_gb,case when r.source_snapshot->>'storage_gb'~'^\d+$'then(r.source_snapshot->>'storage_gb')::integer end)storage_gb,
   d.color,r.reason,r.notes,r.handed_over_at returned_at,r.slip_reference
  from batches b join public.supplier_returns r on r.batch_id=b.batch_id
  left join public.devices d on d.id=r.device_id left join public.jobs j on j.id=r.job_id left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
  where r.archived_at is null and r.status in('requested','approved','returned')
   and(r.device_id is null or(d.id is not null and d.deleted_at is null))and(r.job_id is null or(j.id is not null and j.deleted_at is null))
 ), states as materialized(
  select p.*,case
   when p.status='returned_to_supplier'or exists(select 1 from returns r where r.batch_id=p.batch_id and r.status='returned'and(r.job_id=p.job_id or(r.job_id is null and r.device_id=p.device_id)))then 'returned'
   when p.status in('supplier_return_requested','return_pending')or exists(select 1 from returns r where r.batch_id=p.batch_id and r.status in('requested','approved')and(r.job_id=p.job_id or(r.job_id is null and r.device_id=p.device_id)))then 'return_pending'
   when p.exported or p.status='shipped'then 'exported'
   when p.status in('received','initial_qc_pending','initial_qc_completed','no_work_required')then 'initial_qc'
   when p.status in('work_required','laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','frame_pending','frame_in_progress','rework')then 'lab_glass'
   when p.status='parts_pending'then 'parts'
   when p.status in('final_qc_pending','qc_failed')then 'final_qc'
   when p.status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then 'ready'else 'other'end stage
  from phones p
 ), model_rows as(
  select batch_id,min(model)model,storage_gb,count(*)::integer stock_quantity,count(*)::integer received_quantity,0::integer imei_entry_pending,
   count(*)filter(where stage='initial_qc')::integer initial_qc_pending,count(*)filter(where stage='lab_glass')::integer lab_glass_pending,
   count(*)filter(where stage='parts')::integer parts_pending,count(*)filter(where stage='final_qc')::integer final_qc_pending,
   count(*)filter(where stage='ready')::integer ready_quantity,count(*)filter(where stage='exported')::integer exported_quantity,
   count(*)filter(where stage='returned')::integer returned_quantity,count(*)filter(where stage='return_pending')::integer return_pending,
   count(*)filter(where stage='other')::integer other_quantity,false receipt_balance
  from states group by batch_id,lower(regexp_replace(btrim(model),'\s+',' ','g')),storage_gb
 ), balances as(
  select b.batch_id,b.receipt_quantity,(select count(*)::integer from phones p where p.batch_id=b.batch_id)entered,
   (select count(*)::integer from returns r where r.batch_id=b.batch_id and r.device_id is null and r.status='returned')returned,
   (select count(*)::integer from returns r where r.batch_id=b.batch_id and r.device_id is null and r.status in('requested','approved'))reserved
  from batches b
 ), rows as(
  select *from model_rows union all
  select batch_id,'Unentered stock',null::integer,greatest(receipt_quantity-entered,returned+reserved),0,greatest(receipt_quantity-entered-returned-reserved,0),0,0,0,0,0,0,returned,reserved,0,true
  from balances where greatest(receipt_quantity-entered,returned+reserved)>0
 ), return_details as(
  select r.batch_id,r.return_id,r.imei,r.return_number,r.model,r.storage_gb,r.color,r.reason,r.notes,r.returned_at,r.slip_reference,false status_only,
   r.device_id is null receipt_balance,coalesce(s.model,r.model)group_model,coalesce(s.storage_gb,r.storage_gb)group_storage_gb
  from returns r left join states s on s.batch_id=r.batch_id and s.device_id=r.device_id where r.status='returned'and(r.device_id is null or(s.stage='returned'and(r.job_id=s.job_id or r.job_id is null)))
  union all
  select s.batch_id,null::uuid,s.imei,null::text,s.model,s.storage_gb,s.color,null::text,null::text,null::timestamptz,null::text,true,false,s.model,s.storage_gb
  from states s where s.stage='returned'and not exists(select 1 from returns r where r.status='returned'and r.batch_id=s.batch_id and(r.job_id=s.job_id or(r.job_id is null and r.device_id=s.device_id)))
 )select jsonb_build_object('receipts',coalesce((select jsonb_agg(to_jsonb(b)||jsonb_build_object('entered_quantity',x.entered,'unentered_return_quantity',x.returned,'return_reserved',x.reserved,'over_entered',greatest(x.entered+x.returned+x.reserved-x.receipt_quantity,0))order by b.received_at desc,b.batch_id)from batches b join balances x using(batch_id)),'[]'::jsonb),
  'rows',coalesce((select jsonb_agg(to_jsonb(r)||to_jsonb(b)order by b.supplier_code,b.batch_number,r.receipt_balance,r.model,r.storage_gb)from rows r join batches b using(batch_id)),'[]'::jsonb),
  'returns',coalesce((select jsonb_agg(to_jsonb(r)||to_jsonb(b)order by r.returned_at desc nulls last,r.return_id)from return_details r join batches b using(batch_id)),'[]'::jsonb))into result;
 return result;
end;$$;
revoke all on function public.get_supplier_progress_v2(date,date)from public,anon,authenticated;
grant execute on function public.get_supplier_progress_v2(date,date)to authenticated;

-- Register the office wrapper using the existing integrity mechanism.
do $wrap$declare f record;impl text;sig text;body text;begin
 select p.*,pg_get_functiondef(p.oid)ddl into f from pg_proc p where p.oid='public.get_supplier_progress_v2(date,date)'::regprocedure;
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'(date,date)';
 execute regexp_replace(f.ddl,'FUNCTION public\.get_supplier_progress_v2\(','FUNCTION greenloop_private.'||impl||'(');
 execute format('revoke all on function %s from public,anon,authenticated',sig);
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||E'($1,$2);\nend;';
 execute format('create or replace function public.get_supplier_progress_v2(p_date_from date,p_date_to date)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as %L',body);
 insert into greenloop_private.office_routines values('public.get_supplier_progress_v2(date,date)',sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
end;$wrap$;
create table if not exists greenloop_private.supplier_progress_installation(identity text primary key,hash text not null);
alter table greenloop_private.supplier_progress_installation enable row level security;revoke all on greenloop_private.supplier_progress_installation from public,anon,authenticated;
create or replace function public.get_supplier_progress_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_restricted_scopes_version()='20261030-restricted-scopes-1'
 and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.supplier_progress_installation)
 and not has_function_privilege('anon','public.get_supplier_progress_v2(date,date)','EXECUTE')and has_function_privilege('authenticated','public.get_supplier_progress_v2(date,date)','EXECUTE')
 and not exists(select 1 from greenloop_private.supplier_progress_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and exists(select 1 from pg_class where oid='greenloop_private.supplier_progress_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.supplier_progress_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.supplier_progress_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261030-supplier-progress-1'end;
$$;
revoke all on function public.get_supplier_progress_version()from public;grant execute on function public.get_supplier_progress_version()to anon,authenticated;
insert into greenloop_private.supplier_progress_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('public.get_supplier_progress_v2(date,date)'::regprocedure,'public.get_supplier_progress_version()'::regprocedure,(select to_regprocedure(implementation)from greenloop_private.office_routines where identity='public.get_supplier_progress_v2(date,date)'))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_supplier_progress_version()is distinct from '20261030-supplier-progress-1'then raise exception 'Supplier Progress verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_supplier_progress_version()as installed_supplier_progress_version;
