-- Current company custody, audited bulk technician changes and optional return specifications.
do $stage_fix$
declare reviewed jsonb:='[]';sig text;old text;updated text;f record;b record;c record;t record;matches integer;one integer;api_oid oid;target_oid oid;wrapper_oid oid;root_api text;target_name text;
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_chaman_bulk_return_version()')is not null then
  if public.get_chaman_bulk_return_version()is distinct from '20261118-chaman-bulk-return-1'then raise exception 'Existing Chaman / Bulk / Return update integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_chaman_shop_flow_version()is distinct from '20261113-chaman-section-flow-1'or public.get_specific_replacement_version()is distinct from '20261113-specific-replacement-1'or public.get_technician_timer_handover_version()is distinct from '20261117-technician-timer-handover-1'then raise exception 'Install the verified Chaman, replacement and technician timer prerequisites first.';end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Existing permission rules are not verified.';end if;
 create table greenloop_private.chaman_bulk_return_installation(identity text primary key,hash text not null);
 alter table greenloop_private.chaman_bulk_return_installation enable row level security;revoke all on greenloop_private.chaman_bulk_return_installation from public,anon,authenticated;
create or replace function greenloop_private.company_job_available(p_job uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select p_job is not null and not exists(select 1 from greenloop_private.chaman_lines l join public.jobs j on j.id=p_job where l.device_id=j.device_id and l.phase<>'company'and l.voided_at is null);
$$;

create or replace function greenloop_private.bct_target(p_job uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with active as(select s.* from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id
 where j.id=p_job and j.deleted_at is null and greenloop_private.company_job_available(j.id)and s.step_status='in_progress'
 and(s.department in('laboratory','glass')and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','parts_pending')or s.department='frame'and j.current_status in('frame_pending','frame_in_progress')))
 select case when count(*)=1 then jsonb_agg(to_jsonb(a)||jsonb_build_object('current_timer',(select to_jsonb(t)from public.technician_job_timers t where t.job_id=p_job)))->0 end from active a;
$$;

create or replace function greenloop_private.bct_assign(p_job uuid,p_device uuid,p_technician uuid)returns void language plpgsql security definer set search_path=pg_catalog,public as $$
 declare target jsonb;tech public.technician_roster%rowtype;previous public.job_work_order_steps%rowtype;
 begin
  perform greenloop_private.bci_guard();
  perform 1 from public.jobs where id=p_job and device_id=p_device and deleted_at is null for update;
  if not found or not greenloop_private.company_job_available(p_job)then raise exception 'Receive this phone back at Greenloop before correcting its technician.'using errcode='22023';end if;
  target:=greenloop_private.bct_target(p_job);
  if target is null then raise exception 'Technician correction requires one active Lab / Glass or B-DEPT assignment. Historical assignments remain unchanged.'using errcode='22023';end if;
  select *into previous from public.job_work_order_steps where id=(target->>'id')::uuid for update;
  select *into tech from public.technician_roster where id=p_technician and is_active for share;
  if tech.id is null then raise exception 'Choose an active technician.'using errcode='22023';end if;
  if previous.assigned_technician_roster_id is not distinct from tech.id and previous.assigned_technician_name is not distinct from tech.full_name then return;end if;
  update public.job_work_order_steps set assigned_technician_roster_id=tech.id,assigned_technician_name=tech.full_name,assigned_technician_id=null,assigned_at=now()where id=previous.id;
  perform greenloop_private.handover_technician_timer(p_job,p_device,tech.id,'Bulk IMEI Correction');
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(p_device,p_job,'technician_assignment_corrected','Technician corrected in Reports',jsonb_build_object('step_id',previous.id,'previous_technician',previous.assigned_technician_name,'technician_name',tech.full_name,'previous_technician_id',previous.assigned_technician_roster_id,'technician_id',tech.id),auth.uid());
 end;
$$;

revoke all on function greenloop_private.company_job_available(uuid),greenloop_private.bct_target(uuid),greenloop_private.bct_assign(uuid,uuid,uuid)from public,anon,authenticated;

create or replace function public.get_stock_return_candidates_v1(p_batch_id uuid,p_query text default '',p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
 declare result jsonb;
 begin
  perform greenloop_private.require_office_network();perform greenloop_private.require_supplier_return_access('request');perform greenloop_private.pf_cap('supplier_returns','entry');
  if p_batch_id is null or length(coalesce(p_query,''))>200 or p_offset is null or p_offset<0 or p_offset%50<>0 then raise exception 'Choose a receipt and valid50-row page.'using errcode='22023';end if;
  if not exists(select 1 from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id and s.deleted_at is null where b.id=p_batch_id and b.planned_quantity is not null)then raise exception 'Choose an available original receipt.'using errcode='22023';end if;
  with candidates as materialized(
   select j.id job_id,d.id device_id,d.imei_1::text imei,d.model,d.storage_gb,d.color,d.serial_number,j.current_status::text current_stage
   from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null
   where j.receiving_batch_id=p_batch_id and j.supplier_id=(select supplier_id from public.receiving_batches where id=p_batch_id)and j.deleted_at is null and j.closed_at is null and j.ownership_type='company_owned'and d.imei_1~'^[0-9]{15}$'and greenloop_private.company_job_available(j.id)
   and j.id=(select jj.id from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by jj.received_at desc,jj.created_at desc,jj.id desc limit 1)
   and j.current_status not in('shipped','returned_to_customer','rma_completed','scrap','supplier_return_requested','return_pending','returned_to_supplier','shop_stock')
   and not exists(select 1 from public.supplier_returns r where r.device_id=d.id and r.archived_at is null and r.status in('requested','approved','returned'))
   and not exists(select 1 from public.export_box_items x where x.device_id=d.id)
   and not exists(select 1 from public.jobs x where x.device_id=d.id and x.id<>j.id and x.deleted_at is null and x.closed_at is null and x.current_status not in('shipped','returned_to_customer','rma_completed','scrap'))
   and(position(lower(btrim(coalesce(p_query,'')))in lower(concat_ws(' ',d.imei_1,d.imei_2,d.serial_number,d.model,d.storage_gb,d.color)))>0 or nullif(btrim(p_query),'')is null)
  ),page as(select *from candidates order by imei,device_id offset p_offset limit 50)
  select jsonb_build_object('batch_id',p_batch_id,'offset',p_offset,'limit',50,'total',(select count(*)from candidates),'rows',coalesce((select jsonb_agg(to_jsonb(p)order by imei,device_id)from page p),'[]'))into result;
  return result;
 end;
$$;
revoke all on function public.get_stock_return_candidates_v1(uuid,text,integer)from public,anon,authenticated;
grant execute on function public.get_stock_return_candidates_v1(uuid,text,integer)to authenticated;

sig:=$patch$greenloop_private.ed_unassigned_rows(uuid)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$job\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$job\.deleted_at\s*is\s*null$token$,$patch$job.deleted_at is null and greenloop_private.company_job_available(job.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_initial_qc_work_tray_v1()$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_qc_issuance_options_v1()$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_initial_qc_job_by_identifier(text)$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$job\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$job\.deleted_at\s*is\s*null$token$,$patch$job.deleted_at is null and greenloop_private.company_job_available(job.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_frame_department_rows()$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$job\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$job\.deleted_at\s*is\s*null$token$,$patch$job.deleted_at is null and greenloop_private.company_job_available(job.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_lab_employee_board_v1()$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.get_lab_workbench_v1(uuid,text)$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
if position(target_name in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.qcis_rows(text[])$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.qcn_counts()$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.qdr_stock_selection(text,jsonb,integer,integer)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated!~$token$jj\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$jj\.deleted_at\s*is\s*null$token$,$patch$jj.deleted_at is null and greenloop_private.company_job_available(jj.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.sbn_counts()$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$j\.deleted_at\s*is\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$j\.deleted_at\s*is\s*null$token$,$patch$j.deleted_at is null and greenloop_private.company_job_available(j.id)$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.chaman_preview(text,jsonb)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'laboratory_pending','glass_pending','frame_pending'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'laboratory_pending','glass_pending','frame_pending'$token$,$patch$'laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','frame_pending','frame_in_progress'$patch$,'g');
if updated!~$token$'initial_qc_completed','parts_pending'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'initial_qc_completed','parts_pending'$token$,$patch$'initial_qc_completed','work_required','rework','parts_pending'$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'laboratory_pending','glass_pending','frame_pending'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'laboratory_pending','glass_pending','frame_pending'$token$,$patch$'laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','frame_pending','frame_in_progress'$patch$,'g');
if updated!~$token$'initial_qc_completed','parts_pending'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'initial_qc_completed','parts_pending'$token$,$patch$'initial_qc_completed','work_required','rework','parts_pending'$patch$,'g');
if updated!~$token$outcome:=jsonb_build_object\('document_id'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$outcome:=jsonb_build_object\('document_id'$token$,$patch$update public.workflow_notification_signal set revision=revision+1 where id=1;
 outcome:=jsonb_build_object('document_id'$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.bci_options()$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'receipts',coalesce$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'receipts',coalesce$token$,$patch$'technicians',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name)order by lower(full_name),id)from public.technician_roster where is_active),'[]'),
 'receipts',coalesce$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.bci_row(uuid)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$fp\s*text;final_bh\s*integer;$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$fp\s*text;final_bh\s*integer;$token$,$patch$fp text;final_bh integer;tech_target jsonb;$patch$,'g');
if updated!~$token$fp:=md5\(jsonb_build_object\($token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$fp:=md5\(jsonb_build_object\($token$,$patch$if not greenloop_private.company_job_available(j.id)then locked:='Phone is outside Greenloop in the Chaman process. Confirm its return receiving first.';end if;
 tech_target:=greenloop_private.bct_target(j.id);
 fp:=md5(jsonb_build_object($patch$,'g');
if updated!~$token$return\s*jsonb_build_object\('device_id'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$return\s*jsonb_build_object\('device_id'$token$,$patch$fp:=md5(jsonb_build_array(fp,tech_target)::text);
 return jsonb_build_object('can_change_technician',tech_target is not null and locked is null,'technician_step_id',tech_target->'id','device_id'$patch$,'g');
if updated!~$token$'values',jsonb_build_object\('model'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'values',jsonb_build_object\('model'$token$,$patch$'values',jsonb_build_object('technician_id',tech_target->'assigned_technician_roster_id','technician',tech_target->'assigned_technician_name','model'$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.bci_save(jsonb,text,text,uuid)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'parts','services'\)\)then$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'parts','services'\)\)then$token$,$patch$'parts','services','technician_id'))then$patch$,'g');
if updated!~$token$nowrow:=$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$nowrow:=$token$,$patch$if patch?'technician_id'and patch->'technician_id'is distinct from old->'values'->'technician_id'then perform greenloop_private.bct_assign(job,dev,(patch->>'technician_id')::uuid);end if;
 nowrow:=$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.bcg_save(jsonb,text,text,uuid)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'parts','services'\)\)then$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'parts','services'\)\)then$token$,$patch$'parts','services','technician_id'))then$patch$,'g');
if updated!~$token$nowrow:=$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$nowrow:=$token$,$patch$if patch?'technician_id'and patch->'technician_id'is distinct from old->'values'->'technician_id'then perform greenloop_private.bct_assign(job,dev,(patch->>'technician_id')::uuid);end if;
 nowrow:=$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$'Initial\s*QC\s*issuance'\)$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'Initial\s*QC\s*issuance'\)$token$,$patch$'Initial QC issuance','Bulk IMEI Correction')$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.srma_plan(uuid,uuid,jsonb)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$gb_changed:=nullif\(c\->>'storage_gb',''\)::integer\s*is\s*distinct\s*from\s*gb;$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$gb_changed:=nullif\(c\->>'storage_gb',''\)::integer\s*is\s*distinct\s*from\s*gb;$token$,$patch$gb_changed:=nullif(c->>'storage_gb','')is not null and nullif(c->>'storage_gb','')::integer is distinct from gb;$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
root_api:=$api$public.record_simple_stock_return(jsonb,uuid)$api$;api_oid:=to_regprocedure(root_api);
if api_oid is null then raise exception 'Required public API is not installed: %',root_api;end if;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.capability_routines where to_regprocedure(identity)=api_oid;
if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered implementation for %. Nothing installed.',root_api;end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prokind='f'and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Registered implementation shape differs for %',root_api;end if;
if not exists(select 1 from greenloop_private.capability_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered implementation integrity differs for %. Nothing installed.',root_api;end if;
select 'greenloop_private.'||proname||'('into target_name from pg_proc where oid=target_oid;
wrapper_oid:=api_oid;
 if position(target_name in regexp_replace(replace(pg_get_functiondef(wrapper_oid),'"',''),'\s','','g'))=0 then
  select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,wrapper_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
  if matches<>1 or wrapper_oid is null or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=wrapper_oid and original_hash=md5(pg_get_functiondef(wrapper_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered office chain integrity differs for %',root_api;end if;
  if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=wrapper_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Public API does not call its registered office wrapper: %',root_api;end if;
 end if;
 if position(target_name in regexp_replace(replace(pg_get_functiondef(wrapper_oid),'"',''),'\s','','g'))=0 then raise exception 'Office API does not call its registered implementation: %',root_api;end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$v_storage\s*integer;$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$v_storage\s*integer;$token$,$patch$v_storage integer;v_color text;$patch$,'g');
if updated!~$token$v_storage:=nullif\(p_payload\->>'storage_gb',''\)::integer;$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$v_storage:=nullif\(p_payload\->>'storage_gb',''\)::integer;$token$,$patch$v_storage:=nullif(p_payload->>'storage_gb','')::integer;v_color:=nullif(btrim(p_payload->>'color'),'');
 if p_payload?'color'and jsonb_typeof(p_payload->'color')not in('string','null')or length(coalesce(v_color,''))>120 or v_storage is not null and v_storage not between 1 and 16384 then raise exception 'Enter valid optional GB / Color, or leave them blank.'using errcode='22023';end if;$patch$,'g');
if updated!~$token$'serial_number',d\.serial_number\)\);$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'serial_number',d\.serial_number\)\);$token$,$patch$'serial_number',d.serial_number,'color',case when d.id is null then v_color else coalesce(nullif(d.color,''),v_color)end));$patch$,'g');
if updated!~$token$'storage_gb',v_unit\->'storage_gb'\)$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'storage_gb',v_unit\->'storage_gb'\)$token$,$patch$'storage_gb',v_unit->'storage_gb','color',v_unit->'color')$patch$,'g');
if updated!~$token$if\s*\(v_model\s*is\s*not\s*null$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$if\s*\(v_model\s*is\s*not\s*null$token$,$patch$if v_color is not null and nullif(d.color,'')is not null and lower(v_color)<>lower(d.color)then raise exception 'The optional Color does not match IMEI %.',v_imei using errcode='22023';end if;
        if (v_model is not null$patch$,'g');
if updated!~$token$v_plans\s*from\s*public\.stock_batch_plan_lines\s*p\s*where\s*p\.receiving_batch_id=b\.id$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$v_plans\s*from\s*public\.stock_batch_plan_lines\s*p\s*where\s*p\.receiving_batch_id=b\.id$token$,$patch$v_plans from public.stock_batch_plan_lines p where p.receiving_batch_id=b.id and(v_color is null or p.color is null or lower(p.color)=lower(v_color))$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;
sig:=$patch$greenloop_private.itc_changes(jsonb,jsonb,text,boolean,boolean)$patch$;old:=pg_get_functiondef(sig::regprocedure);updated:=old;
matches:=0;
 select count(*)into matches from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);
 if matches=0 then select count(*)into matches from greenloop_private.capability_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(old);end if;
 if matches=0 then
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($proof$select count(*)from %s where replace(%I,' ','')=replace($1,' ','')and %I=$2$proof$,t.name,c.idcol,c.hashcol)into one using sig,md5(old);matches:=matches+one;
 end loop;end loop;end if;
 if matches=0 then raise exception 'The existing routine integrity receipt differs: %. Nothing installed.',sig;end if;
if updated!~$token$and\s*k\s*not\s*in\('payload_hash'$token$then raise exception 'Reviewed routine boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$and\s*k\s*not\s*in\('payload_hash'$token$,$patch$and(k<>'technician_id'or not(coalesce(before_values?'technician',false)or coalesce(after_values?'technician',false)))and k not in('payload_hash'$patch$,'g');
if updated=old then raise exception 'Routine patch made no change: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));execute updated;

 -- Only advance existing integrity receipts that still match the reviewed old routine.
 for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format($sync$update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,' ','')=replace($1,' ','')and %I=$2$sync$,t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
 end loop;end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 end loop;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_stock_return_candidates_v1','{"page":"supplier_returns","capability":"entry","read":true}'),('get_chaman_bulk_return_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
execute $definition$create or replace function public.get_chaman_bulk_return_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
select case when exists(select 1 from greenloop_private.chaman_bulk_return_installation where identity='@routines'and hash=(select md5(string_agg(identity,','order by identity))from greenloop_private.chaman_bulk_return_installation where identity<>'@routines'))
and(select bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.chaman_bulk_return_installation where identity<>'@routines')
and not exists(select 1 from greenloop_private.chaman_bulk_return_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where i.identity<>'@routines'and p.pronamespace='greenloop_private'::regnamespace and(has_function_privilege('anon',p.oid,'EXECUTE')or has_function_privilege('authenticated',p.oid,'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.chaman_bulk_return_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.chaman_bulk_return_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.chaman_bulk_return_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and not has_function_privilege('anon','public.get_stock_return_candidates_v1(uuid,text,integer)','EXECUTE')and has_function_privilege('authenticated','public.get_stock_return_candidates_v1(uuid,text,integer)','EXECUTE')
and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_return_candidates_v1'and rule='{"page":"supplier_returns","capability":"entry","read":true}'::jsonb)
and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))
then '20261118-chaman-bulk-return-1'end;$$;
revoke all on function public.get_chaman_bulk_return_version()from public;grant execute on function public.get_chaman_bulk_return_version()to anon,authenticated;
$definition$;
insert into greenloop_private.chaman_bulk_return_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from jsonb_to_recordset(reviewed)as x(identity text);
insert into greenloop_private.chaman_bulk_return_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.company_job_available(uuid)','greenloop_private.bct_target(uuid)','greenloop_private.bct_assign(uuid,uuid,uuid)','public.get_stock_return_candidates_v1(uuid,text,integer)','public.get_chaman_bulk_return_version()'])s;
insert into greenloop_private.chaman_bulk_return_installation select '@routines',md5(string_agg(identity,','order by identity))from greenloop_private.chaman_bulk_return_installation;
if public.get_chaman_bulk_return_version()is distinct from '20261118-chaman-bulk-return-1'then raise exception 'Chaman / Bulk / Return verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$stage_fix$;
select public.get_chaman_bulk_return_version()as installed_chaman_bulk_return_version;
