-- Combined QC scan snapshots. Existing inspection/save/receive rules remain authoritative.
begin;
do $$begin
 if to_regprocedure('public.get_qc_fast_work_trays_version()')is not null then
  if public.get_qc_fast_work_trays_version()is distinct from '20261111-qc-fast-work-trays-1'then raise exception 'Existing QC Fast installation requires review.';end if;
 end if;
 if public.get_qc_issuance_version()is distinct from '20261104-qc-inspection-issuance-1'
 or public.get_diagnostic_battery_issued_version()is distinct from '20261107-diagnostic-battery-issued-1'
 then raise exception 'Verified QC Issuance and Diagnostic Battery support are required.';end if;
end;$$;
create or replace function greenloop_private.qcf_rows(p_imeis text[],p_final boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v text;seen text[]:='{}';out_rows jsonb:='[]';item jsonb;identity_record jsonb;step_row record;job_row record;step_ids uuid[]:='{}';defaults jsonb;contexts jsonb;message text;names boolean;
begin
 perform greenloop_private.require_office_network();
 perform greenloop_private.pf_cap(case when p_final then 'final_qc'else 'initial_qc'end,case when p_final then 'entry'else 'view'end);
 if greenloop_private.damage_tv_only(auth.uid())then raise exception 'QC access is required.'using errcode='42501';end if;
 if coalesce(cardinality(p_imeis),0)not between 1 and 100 then raise exception 'Send between 1 and 100 IMEIs per request.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 foreach v in array p_imeis loop
  item:=null;identity_record:=null;
  begin
   if v is null or v!~'^[0-9]{15}$'then raise exception 'Use an exact 15-digit IMEI.'using errcode='22023';end if;
   if v=any(seen)then raise exception 'Duplicate IMEI in this request.'using errcode='22023';end if;seen:=array_append(seen,v);
   if not p_final then
    item:=public.get_initial_qc_work_item_v1(v);
    if not coalesce((item->>'found')::boolean,false)then raise exception '%',coalesce(item->>'message','This phone is not waiting in Initial QC.');end if;
    select b.planned_quantity,b.invoice_number,b.batch_number,d.device_platform,d.battery_health_unavailable
     into job_row from public.jobs j join public.devices d on d.id=j.device_id left join public.receiving_batches b on b.id=j.receiving_batch_id where j.id=(item->'job'->>'id')::uuid and j.deleted_at is null and d.deleted_at is null;
    if not found then raise exception 'This phone changed. Scan it again.';end if;
    item:=item||jsonb_build_object('receiving_batch',jsonb_build_object('planned_quantity',job_row.planned_quantity,'invoice_number',job_row.invoice_number,'batch_number',job_row.batch_number),
     'device',(item->'device')||jsonb_build_object('device_platform',job_row.device_platform,'battery_health_unavailable',job_row.battery_health_unavailable));
    -- The existing reader masks supplier names; retain that policy explicitly.
    if not names then item:=item||jsonb_build_object('supplier',null);end if;
   else
    select s.id,j.id job_id into step_row from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
     where d.imei_1=v and s.department='final_qc'and s.step_status='in_progress';
    if not found then raise exception 'This phone is not waiting in Final QC.'using errcode='22023';end if;
    if (select count(*)from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id where w.job_id=step_row.job_id and s.department='final_qc'and s.step_status='in_progress')<>1 then raise exception 'Final QC work is ambiguous. Review this phone in Reports.';end if;
    -- Preserve receipt of the phone. This does not pass, fail or save QC results.
    perform public.receive_final_qc_phone(step_row.id);
    select jsonb_build_object('id',s.id,'work_order',jsonb_build_object('work_order_number',w.work_order_number,'job',jsonb_build_object('id',j.id,'job_number',j.job_number,'supplier_grade',j.supplier_grade,
     'supplier',jsonb_build_object('supplier_code',sp.supplier_code,'company_name',case when names then sp.company_name end),
     'receiving_batch',jsonb_build_object('planned_quantity',b.planned_quantity,'invoice_number',b.invoice_number,'batch_number',b.batch_number),
     'device',jsonb_build_object('device_number',d.device_number,'imei_1',d.imei_1,'imei_2',d.imei_2,'serial_number',d.serial_number,'brand',d.brand,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,'battery_health',d.battery_health,'device_platform',d.device_platform,'battery_health_unavailable',d.battery_health_unavailable,'gc_grade',d.gc_grade))))into item
     from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id join public.devices d on d.id=j.device_id left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers sp on sp.id=coalesce(j.supplier_id,b.supplier_id)where s.id=step_row.id;
    step_ids:=array_append(step_ids,step_row.id);
   end if;
   out_rows:=out_rows||jsonb_build_array(jsonb_build_object('imei',v,'ok',true,'item',item));
  exception when sqlstate '22023'or sqlstate '23505'or sqlstate '55000'or sqlstate 'P0001'then
   message:=sqlerrm;
   if v~'^[0-9]{15}$'then identity_record:=public.get_imei_duplicate_stage_v1(v);end if;
   if identity_record->>'matched_type'='secondary'then message:='This is IMEI 2 of IMEI 1 '||coalesce(identity_record->>'primary_imei','not recorded')||'. Use IMEI 1 for this phone.';end if;
   out_rows:=out_rows||jsonb_build_array(jsonb_build_object('imei',v,'ok',false,'message',message,'record',identity_record));
  end;
 end loop;
 if p_final and cardinality(step_ids)>0 then
  defaults:=public.get_final_qc_battery_defaults_v1(step_ids);contexts:=public.get_final_qc_return_context_v1(step_ids);
  select jsonb_agg(case when (r->>'ok')::boolean then jsonb_set(r,'{item}',r->'item'||jsonb_build_object('batteryDefault',(select b from jsonb_array_elements(defaults)b where b->>'step_id'=r->'item'->>'id'),'failureReturnContext',(select c from jsonb_array_elements(contexts)c where c->>'step_id'=r->'item'->>'id')))else r end order by n)into out_rows from jsonb_array_elements(out_rows)with ordinality x(r,n);
 end if;
 return out_rows;
end;$$;
revoke all on function greenloop_private.qcf_rows(text[],boolean)from public,anon,authenticated;
create or replace function public.get_initial_qc_fast_rows_v1(p_imeis text[])returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.qcf_rows(p_imeis,false);end;$$;
create or replace function public.receive_final_qc_fast_rows_v1(p_imeis text[])returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.qcf_rows(p_imeis,true);end;$$;
revoke all on function public.get_initial_qc_fast_rows_v1(text[]),public.receive_final_qc_fast_rows_v1(text[])from public,anon,authenticated;
grant execute on function public.get_initial_qc_fast_rows_v1(text[]),public.receive_final_qc_fast_rows_v1(text[])to authenticated;
insert into greenloop_private.office_routines select identity,'greenloop_private.qcf_rows(text[],boolean)',md5(pg_get_functiondef('greenloop_private.qcf_rows(text[],boolean)'::regprocedure)),md5(pg_get_functiondef(identity::regprocedure))from unnest(array['public.get_initial_qc_fast_rows_v1(text[])','public.receive_final_qc_fast_rows_v1(text[])'])identity on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_initial_qc_fast_rows_v1','{"page":"initial_qc","capability":"view","read":true}'),('receive_final_qc_fast_rows_v1','{"page":"final_qc","capability":"entry"}'),('get_qc_fast_work_trays_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.qc_fast_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_fast_installation enable row level security;revoke all on greenloop_private.qc_fast_installation from public,anon,authenticated;
create or replace function public.get_qc_fast_work_trays_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_fast_installation)
 and not has_function_privilege('authenticated','greenloop_private.qcf_rows(text[],boolean)','EXECUTE')and not has_function_privilege('anon','greenloop_private.qcf_rows(text[],boolean)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.qc_fast_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.qc_fast_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.qc_fast_installation'::regclass and relrowsecurity)
 and has_function_privilege('authenticated','public.get_initial_qc_fast_rows_v1(text[])','EXECUTE')and not has_function_privilege('anon','public.get_initial_qc_fast_rows_v1(text[])','EXECUTE')
 and has_function_privilege('authenticated','public.receive_final_qc_fast_rows_v1(text[])','EXECUTE')and not has_function_privilege('anon','public.receive_final_qc_fast_rows_v1(text[])','EXECUTE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_initial_qc_fast_rows_v1'and rule='{"page":"initial_qc","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='receive_final_qc_fast_rows_v1'and rule='{"page":"final_qc","capability":"entry"}'::jsonb)
 then '20261111-qc-fast-work-trays-1'end;
$$;
revoke all on function public.get_qc_fast_work_trays_version()from public;grant execute on function public.get_qc_fast_work_trays_version()to anon,authenticated;
insert into greenloop_private.qc_fast_installation select identity,md5(pg_get_functiondef(identity::regprocedure))from unnest(array['greenloop_private.qcf_rows(text[],boolean)','public.get_initial_qc_fast_rows_v1(text[])','public.receive_final_qc_fast_rows_v1(text[])','public.get_qc_fast_work_trays_version()'])identity on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_qc_fast_work_trays_version()is distinct from '20261111-qc-fast-work-trays-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'QC Fast installation failed verification. No changes installed.';end if;
end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_fast_work_trays_version()as installed_qc_fast_work_trays_version;
