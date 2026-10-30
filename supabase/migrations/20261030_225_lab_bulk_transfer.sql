-- Atomic Lab / Glass handover using the existing Job Completed workflow.
begin;
do $$begin if public.get_supplier_progress_version()is distinct from '20261030-supplier-progress-1'then raise exception 'Install and verify Supplier Progress first.';end if;end;$$;
create table if not exists greenloop_private.lab_bulk_transfers(
 user_id uuid not null,request_id uuid not null,command jsonb not null,response jsonb not null,created_at timestamptz not null default now(),primary key(user_id,request_id));
alter table greenloop_private.lab_bulk_transfers enable row level security;revoke all on greenloop_private.lab_bulk_transfers from public,anon,authenticated;
create or replace function greenloop_private.lbt_immutable()returns trigger language plpgsql set search_path=pg_catalog,public as $$begin raise exception 'Bulk Lab handover history is permanent.'using errcode='55000';end;$$;
drop trigger if exists lbt_immutable on greenloop_private.lab_bulk_transfers;
create trigger lbt_immutable before update or delete on greenloop_private.lab_bulk_transfers for each row execute function greenloop_private.lbt_immutable();
create or replace function greenloop_private.lbt_access()returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_edit_access('lab_glass'),false)or not coalesce(public.has_page_capability_v1('lab_glass','entry'),false)then raise exception 'Lab Job Completed access is required.'using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.lbt_phone(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d public.devices%rowtype;j public.jobs%rowtype;s public.job_work_order_steps%rowtype;plan jsonb;reasons jsonb:='[]';steps integer;result jsonb;
begin
 if p_imei is null or btrim(p_imei)!~'^[0-9]{15}$'then raise exception 'Enter or scan one complete 15-digit IMEI.'using errcode='22023';end if;
 if(select count(*)from public.devices where deleted_at is null and(btrim(p_imei)=imei_1 or btrim(p_imei)=imei_2))>1 then raise exception 'This IMEI matches more than one phone. Ask an administrator to review its identity.'using errcode='22023';end if;
 select *into d from public.devices where deleted_at is null and(btrim(p_imei)=imei_1 or btrim(p_imei)=imei_2);
 if d.id is null then raise exception 'This IMEI was not found in the active stock.'using errcode='22023';end if;
 select *into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1;
 if j.id is null then reasons:=reasons||jsonb_build_array('No active receiving job was found.');
 elsif j.current_status not in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')then
  reasons:=reasons||jsonb_build_array(case when j.current_status='final_qc_pending'then 'This phone is already in Final QC.'else 'This phone is not currently in Lab & Glass ('||replace(j.current_status::text,'_',' ')||').'end);
 else
  select count(*)into steps from public.job_work_order_steps st join public.job_work_orders w on w.id=st.work_order_id where w.job_id=j.id and st.department in('laboratory','glass')and st.step_status='in_progress';
  if steps<>1 then reasons:=reasons||jsonb_build_array(case when steps=0 then 'No active Lab / Glass work line was found.'else 'Multiple active Lab / Glass work lines need review before handover.'end);
  else
   select st.*into s from public.job_work_order_steps st join public.job_work_orders w on w.id=st.work_order_id where w.job_id=j.id and st.department in('laboratory','glass')and st.step_status='in_progress';
   plan:=greenloop_private.ps_plan(s.id);
   if plan is null then reasons:=reasons||jsonb_build_array('The current parts and services state is unavailable.');
   else
    if not coalesce((plan->>'services_saved')::boolean,false)and jsonb_array_length(coalesce(plan->'services','[]'))>0 then reasons:=reasons||jsonb_build_array('Save the Lab services list before transfer.');end if;
    if exists(select 1 from jsonb_array_elements(coalesce(plan->'parts','[]'))p where coalesce((p->>'issued')::integer,0)<(p->>'quantity')::integer)or(not coalesce((plan->>'submitted')::boolean,false)and jsonb_array_length(coalesce(plan->'parts','[]'))>0)then reasons:=reasons||jsonb_build_array('Required parts have not all been issued.');end if;
    if exists(select 1 from jsonb_array_elements(coalesce(plan->'returns','[]'))r where r->>'status'='pending')then reasons:=reasons||jsonb_build_array('A Parts return is waiting for review.');end if;
   end if;
   if exists(select 1 from public.initial_qc_part_requirements where job_id=j.id and status='identified')then reasons:=reasons||jsonb_build_array('Initial QC parts are still awaiting the saved parts workflow.');end if;
   if exists(select 1 from public.job_part_requests where job_id=j.id and status in('requested','partially_issued'))then reasons:=reasons||jsonb_build_array('Parts Department has not fully issued all required parts.');end if;
   if exists(select 1 from public.lab_part_return_requests where job_id=j.id and status='pending')and not reasons?'A Parts return is waiting for review.'then reasons:=reasons||jsonb_build_array('A Parts return is waiting for review.');end if;
  end if;
 end if;
 result:=jsonb_build_object('device_id',d.id,'job_id',j.id,'step_id',s.id,'imei',d.imei_1,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,
  'supplier_code',(select supplier_code from public.suppliers where id=j.supplier_id),'technician',coalesce(nullif(s.assigned_technician_name,''),(select full_name from public.technician_roster where id=s.assigned_technician_roster_id),'Unassigned'),
  'status',j.current_status,'ready',jsonb_array_length(reasons)=0,'reasons',reasons,'revision',coalesce((plan->>'revision')::integer,0),'services_revision',coalesce((plan->>'services_revision')::integer,0));
 return result||jsonb_build_object('selection_token',md5(jsonb_build_object('phone',to_jsonb(d),'job',to_jsonb(j),'step',to_jsonb(s),'plan',plan,'result',result)::text),'matched_secondary',btrim(p_imei)<>d.imei_1);
end;$$;
create or replace function public.lookup_lab_bulk_phone_v1(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.lbt_access();return greenloop_private.lbt_phone(p_imei);end;$$;
create or replace function public.transfer_lab_bulk_to_final_qc_v1(p_items jsonb,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare x jsonb;phone jsonb;preview jsonb:='[]';v_phones uuid[]:='{}';v_jobs uuid[]:='{}';v_steps uuid[]:='{}';saved greenloop_private.lab_bulk_transfers%rowtype;result jsonb;v_status text;
begin
 perform greenloop_private.lbt_access();
 if p_request_id is null or jsonb_typeof(p_items)is distinct from 'array'or jsonb_array_length(p_items)not between 1 and 500 then raise exception 'Add 1 to 500 phones before transfer.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('lab-bulk:'||auth.uid()::text||p_request_id::text,0));
 select *into saved from greenloop_private.lab_bulk_transfers where user_id=auth.uid()and request_id=p_request_id;
 if found then if saved.command<>p_items then raise exception 'This transfer key belongs to a different phone list.'using errcode='22023';end if;return saved.response;end if;
 perform pg_advisory_xact_lock(19920261026);
 for x in select value from jsonb_array_elements(p_items)loop
  if jsonb_typeof(x)is distinct from 'object'or exists(select 1 from jsonb_object_keys(x)k where k<>all(array['imei','step_id','selection_token']))or nullif(x->>'selection_token','')is null then raise exception 'Review the full scanned phone list before transfer.'using errcode='22023';end if;
  phone:=greenloop_private.lbt_phone(x->>'imei');
  if(phone->>'device_id')::uuid=any(v_phones)then raise exception 'The same physical phone was scanned more than once.'using errcode='22023';end if;
  if not(phone->>'ready')::boolean then raise exception '%: %',phone->>'imei',(select string_agg(value,' ')from jsonb_array_elements_text(phone->'reasons'))using errcode='22023';end if;
  v_phones:=array_append(v_phones,(phone->>'device_id')::uuid);v_jobs:=array_append(v_jobs,(phone->>'job_id')::uuid);v_steps:=array_append(v_steps,(phone->>'step_id')::uuid);
 end loop;
 perform 1 from public.jobs where id=any(v_jobs)order by id for update;
 perform 1 from public.devices where id=any(v_phones)order by id for update;
 perform 1 from public.job_work_order_steps where id=any(v_steps)order by id for update;
 -- Recheck every snapshot after locking, before completing any phone.
 for x in select value from jsonb_array_elements(p_items)loop
  phone:=greenloop_private.lbt_phone(x->>'imei');
  if not(phone->>'ready')::boolean or phone->>'step_id'is distinct from x->>'step_id'or phone->>'selection_token'is distinct from x->>'selection_token'then raise exception '% changed. Recheck the phone list before transfer. No phones were transferred.',phone->>'imei'using errcode='40001';end if;
  preview:=preview||jsonb_build_array(phone);
 end loop;
 for phone in select value from jsonb_array_elements(preview)loop
  perform public.complete_parts_only_lab_v1((phone->>'step_id')::uuid,(phone->>'revision')::integer,(phone->>'services_revision')::integer);
  select current_status::text into v_status from public.jobs where id=(phone->>'job_id')::uuid;
  if v_status is distinct from 'final_qc_pending'then raise exception 'A phone did not reach Final QC. The entire transfer was rolled back.'using errcode='55000';end if;
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values((phone->>'device_id')::uuid,(phone->>'job_id')::uuid,'lab_bulk_transfer','Bulk Lab handover to Final QC',jsonb_build_object('transfer_id',p_request_id,'phone_count',jsonb_array_length(p_items),'step_id',phone->>'step_id'),auth.uid());
 end loop;
 result:=jsonb_build_object('transfer_id',p_request_id,'transferred_count',jsonb_array_length(p_items),'imeis',(select jsonb_agg(value->>'imei')from jsonb_array_elements(preview)),'status','final_qc_pending','transferred_at',now());
 insert into greenloop_private.lab_bulk_transfers(user_id,request_id,command,response)values(auth.uid(),p_request_id,p_items,result);return result;
end;$$;
revoke all on function greenloop_private.lbt_access(),greenloop_private.lbt_phone(text),greenloop_private.lbt_immutable()from public,anon,authenticated;
revoke all on function public.lookup_lab_bulk_phone_v1(text),public.transfer_lab_bulk_to_final_qc_v1(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.lookup_lab_bulk_phone_v1(text),public.transfer_lab_bulk_to_final_qc_v1(jsonb,uuid)to authenticated;
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('lookup_lab_bulk_phone_v1','transfer_lab_bulk_to_final_qc_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select string_agg('$'||i,','order by i)into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.lab_bulk_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_bulk_installation enable row level security;revoke all on greenloop_private.lab_bulk_installation from public,anon,authenticated;
create or replace function public.get_lab_bulk_transfer_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_supplier_progress_version()='20261030-supplier-progress-1'
 and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_bulk_installation)
 and not exists(select 1 from unnest(array['public.lookup_lab_bulk_phone_v1(text)','public.transfer_lab_bulk_to_final_qc_v1(jsonb,uuid)'])f where has_function_privilege('anon',to_regprocedure(f),'EXECUTE')or not has_function_privilege('authenticated',to_regprocedure(f),'EXECUTE'))
 and not exists(select 1 from greenloop_private.lab_bulk_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from unnest(array['greenloop_private.lab_bulk_transfers','greenloop_private.lab_bulk_installation'])t where not exists(select 1 from pg_class where oid=to_regclass(t)and relrowsecurity)or has_table_privilege('anon',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.lab_bulk_transfers'::regclass and tgname='lbt_immutable'and tgenabled='O')then '20261030-lab-bulk-transfer-1'end;$$;
revoke all on function public.get_lab_bulk_transfer_version()from public;grant execute on function public.get_lab_bulk_transfer_version()to anon,authenticated;
insert into greenloop_private.lab_bulk_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'lbt_%'or p.pronamespace='public'::regnamespace and p.proname in('lookup_lab_bulk_phone_v1','transfer_lab_bulk_to_final_qc_v1','get_lab_bulk_transfer_version')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.lookup_lab_bulk_phone_v1(text)'::regprocedure,'public.transfer_lab_bulk_to_final_qc_v1(jsonb,uuid)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_lab_bulk_transfer_version()is distinct from '20261030-lab-bulk-transfer-1'then raise exception 'Bulk Lab transfer verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_lab_bulk_transfer_version()as installed_lab_bulk_transfer_version;
