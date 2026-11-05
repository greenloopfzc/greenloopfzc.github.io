-- Correct read projections: a box scan is not a verified export. Rename only
-- the human-readable Ready Stock location; keep IDs and workflow codes intact.
begin;
do $$begin
 if public.get_qc_issuance_edit_version()is distinct from '20261105-qc-issuance-edit-1'then
  raise exception 'Install verified QC Issuance Edit first.';
 end if;
end;$$;

update public.locations set location_name='Ready Stock'
where location_code in('PRODUCTION','READY','READY-STOCK')and lower(btrim(location_name))in('production','production department');

create or replace function greenloop_private.jst_proofs(p_device uuid)
returns table(job_id uuid,occurred_at timestamptz,box_number text,actor uuid,proof text)
language sql stable security definer set search_path=pg_catalog,public as $$
 select e.job_id,e.created_at,e.event_data->>'box_number',e.actor_id,'accounts_verified'
 from public.device_events e where e.device_id=p_device and e.event_type='box_accounts_verified'
 union
 select i.job_id,w.verified_at,b.box_number,w.verified_by,'accounts_verified'
 from public.export_box_items i join public.export_boxes b on b.id=i.box_id
 join greenloop_private.box_workflow w on w.box_id=b.id
 where i.device_id=p_device and w.state='exported'and w.verified_at is not null and i.scanned_at<=w.verified_at
 union
 select r.job_id,r.dispatched_at,null,r.dispatched_by,'dispatch'
 from public.stock_out_records r join public.jobs j on j.id=r.job_id
 where j.device_id=p_device and r.dispatched_at is not null;
$$;
revoke all on function greenloop_private.jst_proofs(uuid)from public,anon,authenticated;

create or replace function greenloop_private.jst_stage(p_status text,p_job uuid,p_device uuid)
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case
 when p_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then 'Ready Stock'
 when p_status='box_entry'then 'Box Entry'
 when p_status='accounts_pending'then case when exists(select 1 from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id where i.job_id=p_job and w.state='recheck')then 'Box Re-check'else 'Accounts Pending'end
 when p_status='shipped'then case when exists(select 1 from greenloop_private.jst_proofs(p_device)p where p.job_id=p_job)then 'Exported'else 'Box Entry (export not verified)'end
 when p_status='initial_qc_pending'and exists(select 1 from greenloop_private.qc_saved_issuance s where s.job_id=p_job and s.issued_at is null)then 'Lab & Glass Issuance'
 when p_status='initial_qc_pending'then 'Initial QC'
 when p_status='received'then 'IMEI Entry â€” saved'
 when p_status='initial_qc_completed'then 'Initial QC â€” completed'
 when p_status='no_work_required'then 'Initial QC â€” no work required'
 when p_status='parts_pending'then 'Parts'
 when p_status='qc_failed'then 'Final QC â€” failed'
 when p_status like 'laboratory_%'then 'Lab & Glass'
 when p_status like 'glass_%'then 'Lab & Glass'
 when p_status like 'frame_%'then 'B-DEPT'
 when p_status like 'final_qc_%'then 'Final QC'
 when p_status like 'supplier_return_%'then 'Stock Return'
 else initcap(replace(coalesce(p_status,'Not recorded'),'_',' '))end;
$$;
revoke all on function greenloop_private.jst_stage(text,uuid,uuid)from public,anon,authenticated;

create or replace function greenloop_private.jst_history(data jsonb)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d public.devices%rowtype;j public.jobs%rowtype;r jsonb;out_rows jsonb:='[]';details jsonb;
 event_kind text;box text;key text;label text;meaning text;status text;loc text;proof record;
begin
 if data is null or data->>'found'is distinct from 'true'or jsonb_typeof(data->'device')is distinct from 'object'then return data;end if;
 select *into d from public.devices where imei_1=data->'device'->>'imei_1'and deleted_at is null;
 if d.id is null then return data;end if;
 select *into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc nulls last,created_at desc,id limit 1;
 status:=coalesce(j.current_status::text,d.current_status::text);
 loc:=data->'device'->>'current_location';
 if lower(btrim(coalesce(loc,'')))in('production','production department','ready','ready-stock')then loc:='Ready Stock';end if;
 if status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then loc:='Ready Stock';end if;
 if lower(btrim(coalesce(loc,'')))in('outbound','export','exported')then loc:=greenloop_private.jst_stage(status,j.id,d.id);end if;
 data:=jsonb_set(data,'{device}',data->'device'||jsonb_build_object('current_stage',greenloop_private.jst_stage(status,j.id,d.id),'current_status',status,'current_location',loc));
 for r in select value from jsonb_array_elements(coalesce(data->'rows','[]'))loop
  event_kind:=null;key:=null;label:=null;meaning:=null;box:=null;
  if split_part(r->>'id',':',1)='event'then
   select e.event_type,e.event_data->>'box_number'into event_kind,box from public.device_events e where e.id::text=split_part(r->>'id',':',2)and e.device_id=d.id;
  end if;
  if split_part(r->>'id',':',1)='export-box'or event_kind='export_box_scanned'then
   key:=case when status in('box_entry','accounts_pending')and r->>'job_number'=j.job_number then 'box_entry'else 'box_history'end;
   label:=case when key='box_entry'then 'Scanned into Box Entry'else 'Box scan history (not an export)'end;
   meaning:='A box scan is not Accounts verification or a confirmed export.';
  elsif event_kind in('box_saved_to_accounts','box_resubmitted_accounts')then
   key:='accounts_pending';label:='Box sent to Accounts';meaning:='Submitted for verification; not exported at this time.';
  elsif event_kind in('box_recheck_requested','box_returned_for_recheck')then
   key:='box_recheck';label:='Accounts requested box re-check';meaning:='Not exported; correction required.';
  elsif event_kind='box_accounts_verified'or split_part(r->>'id',':',1)='dispatch'or event_kind='stock_out_completed'then
   key:=case when status='shipped'and r->>'job_number'=j.job_number then 'export'else 'export_history'end;
   label:=case when key='export'then 'Verified export'else 'Verified export history'end;
   meaning:='Confirmed by the recorded Accounts verification or stock dispatch, not by scanning into a box.';
  elsif split_part(r->>'id',':',1)='movement'and exists(select 1 from jsonb_array_elements(coalesce(r->'details','[]'))x where x->>'label'='To'and lower(x->>'value')in('outbound','export','exported'))then
   if exists(select 1 from greenloop_private.jst_proofs(d.id)p join public.jobs pj on pj.id=p.job_id where pj.job_number=r->>'job_number'and p.occurred_at=(r->>'occurred_at')::timestamptz)then
    key:=case when status='shipped'and r->>'job_number'=j.job_number then 'export'else 'export_history'end;
    label:='Verified export location record';
   else key:='box_history';label:='Recorded outbound location (export not verified)';meaning:='Historical location record only; no export confirmation is recorded at this time.';end if;
  elsif r->>'stage'='export'then
   key:='box_history';label:='Box activity (export not verified)';meaning:='This activity alone does not confirm export.';
  end if;
  select coalesce(jsonb_agg(case when x->>'label'in('From','To','Department','Next department','Next step')and lower(x->>'value')in('production','production department')then jsonb_set(x,'{value}','"Ready Stock"')else x end order by pos),'[]')into details
  from jsonb_array_elements(coalesce(r->'details','[]'))with ordinality q(x,pos)where key is null or x->>'label'<>'Stage meaning';
  if key is not null then
   if box is not null and not exists(select 1 from jsonb_array_elements(details)x where x->>'label'='Box number')then details:=details||jsonb_build_array(jsonb_build_object('label','Box number','value',box));end if;
   if meaning is not null then details:=details||jsonb_build_array(jsonb_build_object('label','Stage meaning','value',meaning));end if;
   r:=r||jsonb_build_object('stage',key,'title',label,'status',case when key='export'then 'shipped'when key='export_history'then 'historical'when key='box_entry'then 'box_entry'when key='accounts_pending'then 'accounts_pending'else 'recorded'end);
  end if;
  out_rows:=out_rows||jsonb_build_array(r||jsonb_build_object('details',details));
 end loop;
 -- Some installations retained verification metadata without a device event.
 -- Add only dated, device-specific proof, never the earlier box scan timestamp.
 for proof in select distinct p.job_id,p.occurred_at,p.box_number,p.actor,p.proof,pj.job_number from greenloop_private.jst_proofs(d.id)p join public.jobs pj on pj.id=p.job_id where pj.deleted_at is null loop
  if not exists(select 1 from jsonb_array_elements(out_rows)x where x->>'stage'in('export','export_history')and x->>'job_number'=proof.job_number and(x->>'occurred_at')::timestamptz=proof.occurred_at)then
   key:=case when status='shipped'and proof.job_id=j.id then 'export'else 'export_history'end;
   out_rows:=out_rows||jsonb_build_array(jsonb_build_object('id','verified-export:'||proof.job_id||':'||proof.occurred_at,'occurred_at',proof.occurred_at,'stage',key,'title',case when key='export'then 'Verified export'else 'Verified export history'end,'job_number',proof.job_number,'status',case when key='export'then 'shipped'else 'historical'end,
    'actor',(select full_name from public.user_profiles where id=proof.actor),'parts','[]'::jsonb,'details',jsonb_build_array(jsonb_build_object('label','Box number','value',coalesce(proof.box_number,'Recorded stock dispatch')))));
  end if;
 end loop;
 return jsonb_set(data,'{rows}',out_rows);
end;$$;
revoke all on function greenloop_private.jst_history(jsonb)from public,anon,authenticated;

-- Fix source rows before filtering, sorting and pagination as well. Otherwise
-- an old scan date could still affect Export-date ordering or stage facets.
do $sources$declare id regprocedure;ddl text;patched text;start_at integer;end_at integer;t record;
 needle text:='left join lateral (select box.box_number, item.scanned_at as export_date from public.export_box_items as item join public.export_boxes as box on box.id = item.box_id where item.job_id = job.id order by item.scanned_at desc limit 1) as export_info on true';
 replacement text:='left join lateral (select p.box_number,p.occurred_at as export_date from greenloop_private.jst_proofs(device.id)p where p.job_id=job.id and coalesce(job.current_status::text,device.current_status::text)=''shipped''order by p.occurred_at desc limit 1)as export_info on true';
begin
 for id in select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure
 union select 'greenloop_private.filter_get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure loop
  ddl:=pg_get_functiondef(id);
  if strpos(ddl,'greenloop_private.jst_proofs(')=0 then
   if strpos(ddl,needle)=0 then raise exception 'Reviewed journey export source differs. Nothing changed.';end if;
   patched:=replace(ddl,needle,replacement);
   start_at:=strpos(patched,'coalesce(case active_department.department');end_at:=strpos(patched,'  from selected');
   if start_at=0 or end_at<=start_at then raise exception 'Reviewed journey stage source differs. Nothing changed.';end if;
   patched:=substr(patched,1,start_at-1)||'greenloop_private.jst_stage(coalesce(job.current_status::text,device.current_status::text),job.id,device.id)'||chr(10)||substr(patched,end_at);
   execute patched;
  end if;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
  end loop;
 end loop;
end;$sources$;

-- Amend only the reviewed public read wrappers. Keep their existing Office
-- check and original read/permission implementation. Seal the new definitions.
do $wrappers$declare signature text;id regprocedure;impl text;ddl text;needle text;expr text;t record;begin
 for signature in select unnest(array['public.search_imei_journey_v1(text)','public.get_stock_journey_details_v1(uuid)'])loop
  id:=signature::regprocedure;ddl:=pg_get_functiondef(id);
  if strpos(ddl,'greenloop_private.jst_')=0 then
   select split_part(implementation,'(',1)into impl from greenloop_private.office_routines where to_regprocedure(identity)=id;
   expr:=impl||'($1)';
   needle:='return '||expr||';';
   if impl is null or strpos(ddl,needle)=0 then raise exception 'Reviewed journey reader boundary differs: %. Nothing changed.',signature;end if;
   execute replace(ddl,needle,'return greenloop_private.jst_history('||expr||');');
  end if;
  update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(id))where to_regprocedure(identity)=id;
  update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(id))where to_regprocedure(identity)=id;
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
  end loop;
 end loop;
end;$wrappers$;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_journey_status_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.journey_status_installation(identity text primary key,hash text not null);
alter table greenloop_private.journey_status_installation enable row level security;
revoke all on greenloop_private.journey_status_installation from public,anon,authenticated;
insert into greenloop_private.journey_status_installation select signature,md5(pg_get_functiondef(signature::regprocedure))from unnest(array[
 'greenloop_private.jst_proofs(uuid)','greenloop_private.jst_stage(text,uuid,uuid)','greenloop_private.jst_history(jsonb)',
 'public.search_imei_journey_v1(text)','public.get_stock_journey_details_v1(uuid)','public.get_stock_journey_v1(date,date,text,integer,integer)','public.get_stock_batch_report_v1(text,jsonb,integer,integer,text,text)'])signature
on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.journey_status_installation
select id::text,md5(pg_get_functiondef(id))from (
 select to_regprocedure(implementation)id from greenloop_private.office_routines where to_regprocedure(identity)='public.get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure
 union select 'greenloop_private.filter_get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure)q
on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_journey_status_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_issuance_edit_version()='20261105-qc-issuance-edit-1'
 and(select count(*)=9 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.journey_status_installation)
 and not exists(select 1 from greenloop_private.journey_status_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from public.locations where location_code in('PRODUCTION','READY','READY-STOCK')and lower(btrim(location_name))in('production','production department'))
 and not has_table_privilege('authenticated','greenloop_private.journey_status_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.journey_status_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261105-journey-status-1'end;
$$;
revoke all on function public.get_journey_status_version()from public;grant execute on function public.get_journey_status_version()to anon,authenticated;
do $$begin if public.get_journey_status_version()is distinct from '20261105-journey-status-1'then raise exception 'Journey status verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_journey_status_version()as installed_journey_status_version;
