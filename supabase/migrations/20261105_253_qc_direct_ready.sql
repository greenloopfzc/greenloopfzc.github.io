-- Initial QC may release a no-work company phone directly to Ready Stock.
-- Keep the saved inspection and an explicit source receipt; never invent a
-- Final QC inspection, technician assignment, parts order or repair time.
begin;
do $$begin if public.get_return_location_version()is distinct from '20261105-return-location-1'then raise exception 'Install verified Return Location first.';end if;end;$$;
create table if not exists greenloop_private.qc_direct_ready(
 job_id uuid primary key,device_id uuid not null,inspection_id uuid not null,
 request_id uuid not null unique,payload_hash text not null,final_grade text not null,
 battery_health smallint,battery_health_unavailable boolean not null default false,
 ready_at timestamptz not null default now(),actor_id uuid not null,response jsonb not null
);
alter table greenloop_private.qc_direct_ready enable row level security;
revoke all on greenloop_private.qc_direct_ready from public,anon,authenticated;
-- Compatibility column names are used only by stock outcome readers. These
-- rows are not exposed as Final QC inspections or included in QC pass counts.
create or replace view greenloop_private.qdr_ready_outcomes as
 select job_id,device_id,final_grade,final_battery_health,inspected_at,result::text result
 from public.final_qc_inspections where result='pass'
 union all select r.job_id,r.device_id,r.final_grade,r.battery_health,r.ready_at,'pass'
 from greenloop_private.qc_direct_ready r join public.jobs j on j.id=r.job_id and j.deleted_at is null
 join public.devices d on d.id=r.device_id and d.deleted_at is null;
revoke all on greenloop_private.qdr_ready_outcomes from public,anon,authenticated;

create or replace function public.save_initial_qc_direct_ready_v1(p_job_id uuid,p_findings jsonb default '[]',p_part_requests jsonb default '[]',p_supplier_grade text default null,p_gc_grade text default null,p_notes text default null,p_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare prior greenloop_private.qc_direct_ready%rowtype;j public.jobs%rowtype;d public.devices%rowtype;s greenloop_private.qc_saved_issuance%rowtype;
 fingerprint text;grade text:=nullif(upper(btrim(p_gc_grade)),'');loc uuid;from_loc uuid;result jsonb;actor uuid:=auth.uid();begin
 perform greenloop_private.qcis_require(true);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 if p_request_id is null or p_job_id is null then raise exception 'A phone and save request are required.'using errcode='22023';end if;
 if p_findings is null or p_part_requests is null or jsonb_typeof(p_findings)<>'array'or jsonb_typeof(p_part_requests)<>'array'or jsonb_array_length(p_findings)<>0 or jsonb_array_length(p_part_requests)<>0 then
  raise exception 'Direct Ready Stock needs no selected parts or services. Remove the work explicitly, or untick Direct Ready Stock and save for Issuance.'using errcode='22023';end if;
 if grade is null or grade='D'or not greenloop_private.qc_grade_allowed('gc_grade',grade)then raise exception 'Choose a saved, non-D GL Grade before sending directly to Ready Stock.'using errcode='22023';end if;
 fingerprint:=md5(jsonb_build_object('job',p_job_id,'findings',p_findings,'parts',p_part_requests,'supplier_grade',p_supplier_grade,'grade',p_gc_grade,'notes',p_notes)::text);
 select *into prior from greenloop_private.qc_direct_ready where job_id=p_job_id or request_id=p_request_id for update;
 if prior.job_id is not null then
  if prior.job_id=p_job_id and prior.request_id=p_request_id and prior.payload_hash=fingerprint then return prior.response||jsonb_build_object('replayed',true);end if;
  raise exception 'This phone or save request is already recorded. Refresh or use Reports for a correction.'using errcode='22023';end if;
 select *into j from public.jobs where id=p_job_id and deleted_at is null for update;
 select *into d from public.devices where id=j.device_id and deleted_at is null for update;
 if j.id is null or d.id is null or j.current_status<>'initial_qc_pending'then raise exception 'This phone is not waiting for Initial QC.'using errcode='22023';end if;
 if j.id is distinct from(select jj.id from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by jj.received_at desc nulls last,jj.created_at desc,jj.id limit 1)then raise exception 'This phone has a newer workflow. Reload its current stage.'using errcode='22023';end if;
 if j.ownership_type<>'company_owned'then raise exception 'Direct Ready Stock is available for company-owned stock. Use the normal workflow for customer repair phones.'using errcode='22023';end if;
 if not coalesce(d.battery_health_unavailable,false)and(d.battery_health is null or d.battery_health not between 1 and 100)then raise exception 'Battery Health must be recorded before Direct Ready Stock.'using errcode='22023';end if;
 select id into loc from public.locations where location_code='PRODUCTION'and is_active;
 if loc is null then raise exception 'Ready Stock location is not configured.';end if;
 from_loc:=j.current_location_id;
 -- The original inspected save is part of this same transaction. If any
 -- release check/write fails, no partial inspection or Issuance item survives.
 perform public.save_initial_qc_inspection_v1(p_job_id,p_findings,p_part_requests,p_supplier_grade,p_gc_grade,p_notes,p_request_id);
 select *into s from greenloop_private.qc_saved_issuance where job_id=p_job_id for update;
 if s.state<>'awaiting_issuance'or exists(select 1 from public.job_work_orders where job_id=p_job_id)
 or exists(select 1 from public.initial_qc_part_requirements where job_id=p_job_id and status not in('not_required','cancelled'))
 or exists(select 1 from public.initial_qc_findings where inspection_id=s.inspection_id and issue_found)then raise exception 'This inspection has work or was already issued. Review it before Direct Ready Stock.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('save_initial_qc_direct_ready_v1',jsonb_build_object('p_job_id',p_job_id));begin
  update public.jobs set current_status='production_pending',current_location_id=loc where id=p_job_id;
  update public.devices set current_status='production_pending',current_location_id=loc where id=d.id;
  update greenloop_private.qc_saved_issuance set state='issued',issued_at=now(),issued_by=actor,destination='ready_stock',issue_request_id=p_request_id where job_id=p_job_id;
  result:=jsonb_build_object('saved',true,'state','ready_stock','destination','ready_stock','job_id',p_job_id,'inspection_id',s.inspection_id,'final_grade',grade,'battery_health',d.battery_health);
  insert into greenloop_private.qc_direct_ready(job_id,device_id,inspection_id,request_id,payload_hash,final_grade,battery_health,battery_health_unavailable,actor_id,response)
  values(p_job_id,d.id,s.inspection_id,p_request_id,fingerprint,grade,d.battery_health,coalesce(d.battery_health_unavailable,false),actor,result);
  insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)
  values(d.id,p_job_id,from_loc,loc,'Initial QC - no work required - directly to Ready Stock',actor);
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
  values(d.id,p_job_id,'initial_qc_direct_ready','Initial QC - directly to Ready Stock',jsonb_build_object('inspection_id',s.inspection_id,'final_grade',grade,'final_battery_health',case when d.battery_health is not null then d.battery_health::text||'%'else 'Not available'end,'next_status','production_pending','source','Initial QC','no_work',true),actor);
 exception when others then perform greenloop_private.end_capability();raise;end;
 perform greenloop_private.end_capability();return result;
end;$$;
revoke all on function public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)from public,anon,authenticated;
grant execute on function public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)to authenticated;

create or replace function public.get_qc_stock_selection_v1(p_stage text,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;begin
 perform greenloop_private.qcis_require();
 if p_stage is null or p_stage not in('inspection','issuance')or p_filters is null or jsonb_typeof(p_filters)<>'object'or exists(select 1 from jsonb_object_keys(p_filters)x where x not in('supplier_id','batch_id','invoice_number'))
 or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 500 then raise exception 'Choose valid stock filters and page.'using errcode='22023';end if;
 if p_filters<>'{}'then perform greenloop_private.pf_cap('initial_qc','search');end if;
 with stock as materialized(select *from greenloop_private.sc_receipts()r where
  (nullif(p_filters->>'supplier_id','')is null or r.supplier_id=(p_filters->>'supplier_id')::uuid)
  and(nullif(p_filters->>'batch_id','')is null or r.batch_id=(p_filters->>'batch_id')::uuid)
  and(nullif(p_filters->>'invoice_number','')is null or r.invoice_number=p_filters->>'invoice_number')),
 eligible as materialized(select j.id job_id,d.imei_1 imei,j.received_at from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null
 where j.deleted_at is null and j.current_status='initial_qc_pending'
 and j.id=(select jj.id from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by jj.received_at desc nulls last,jj.created_at desc,jj.id limit 1)
 and((p_stage='issuance')=exists(select 1 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id where s.job_id=j.id and s.state='awaiting_issuance'))
 and(p_filters='{}'or exists(select 1 from stock r where j.receiving_batch_id=any(r.descendant_ids)))),page as(select *from eligible order by received_at,job_id offset p_offset limit p_limit)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(p)order by received_at,job_id)from page p),'[]'),'total',(select count(*)from eligible),'offset',p_offset,'limit',p_limit)into result;
 return result;
end;$$;
revoke all on function public.get_qc_stock_selection_v1(text,jsonb,integer,integer)from public,anon,authenticated;
grant execute on function public.get_qc_stock_selection_v1(text,jsonb,integer,integer)to authenticated;

do $wrap$declare f record;impl text;signature text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text identity from pg_proc p
 where p.oid in('public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure,'public.get_qc_stock_selection_v1(text,jsonb,integer,integer)'::regprocedure)loop
  impl:=case when f.proname='save_initial_qc_direct_ready_v1'then 'qdr_save'else 'qdr_stock_selection'end;
  signature:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';
  execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');
  execute format('revoke all on function %s from public,anon,authenticated',signature);
  select string_agg('$'||i,','order by i)into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
  insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)values(f.identity,signature,md5(pg_get_functiondef(signature::regprocedure)),md5(pg_get_functiondef(f.oid)))
  on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;

-- Extend stock-only grade/BH readers. Raw Final QC inspections, history and
-- performance counts continue to read the real Final QC table unchanged.
create table if not exists greenloop_private.qc_direct_ready_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_direct_ready_installation enable row level security;revoke all on greenloop_private.qc_direct_ready_installation from public,anon,authenticated;
do $outcomes$declare id regprocedure;ddl text;replaced text;t record;changed integer:=0;begin
 for id in
 select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)=any(array[
 'public.get_ready_stock_final_grade_table(date,date)'::regprocedure,'public.get_ready_stock_journey(date,date)'::regprocedure,
 'public.get_ready_stock_summary_by_date(date,date)'::regprocedure,'public.get_ready_stock_imeis_v1(jsonb,date,date,integer,integer)'::regprocedure,
 'public.get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure,'public.add_box_recheck_imei_v1(uuid,integer,text)'::regprocedure])
 union select 'greenloop_private.filter_get_stock_journey_v1(date,date,text,integer,integer)'::regprocedure
 union select to_regprocedure(implementation)from greenloop_private.capability_routines where to_regprocedure(identity)='public.scan_imei_to_export_box(text)'::regprocedure
 loop
  ddl:=pg_get_functiondef(id);
  if strpos(ddl,'greenloop_private.qdr_ready_outcomes')=0 then
   if strpos(lower(ddl),'from public.final_qc_inspections')=0 then raise exception 'Reviewed stock grade source differs: %. Nothing changed.',id;end if;
   replaced:=regexp_replace(ddl,'from public\.final_qc_inspections','from greenloop_private.qdr_ready_outcomes','gi');execute replaced;
  end if;
  changed:=changed+1;
  insert into greenloop_private.qc_direct_ready_installation values(id::text,md5(pg_get_functiondef(id)))on conflict(identity)do update set hash=excluded.hash;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
  where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
  end loop;
 end loop;
 if changed<>8 then raise exception 'Expected eight reviewed stock outcome readers. Nothing changed.';end if;
end;$outcomes$;
-- A direct-release phone has no old repair order. Create its first real order
-- only if an authorized Ready Stock user later requests rework.
do $rework$declare id regprocedure;ddl text;t record;
 needle text:='if v_work_order is null then raise exception ''The work-order history for this IMEI is missing.'' using errcode=''22023''; end if;';
 replacement text:='if v_work_order is null and exists(select 1 from greenloop_private.qc_direct_ready dr where dr.job_id=v_job)then
 insert into public.job_work_orders(work_order_number,job_id,device_id,initial_qc_inspection_id,work_required,created_by)
 select ''WO-''||to_char(current_date,''YYYY'')||''-''||lpad(nextval(''public.work_order_number_sequence''::regclass)::text,5,''0''),v_job,v_device,dr.inspection_id,true,v_actor from greenloop_private.qc_direct_ready dr where dr.job_id=v_job returning id into v_work_order;
 insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(v_work_order,10,v_department,''pending''),(v_work_order,20,''final_qc'',''pending'');
 end if;';
begin
 select to_regprocedure(implementation)into id from greenloop_private.capability_routines where to_regprocedure(identity)='public.send_ready_stock_for_rework(text,text,text)'::regprocedure;
 ddl:=pg_get_functiondef(id);
 if strpos(ddl,'greenloop_private.qc_direct_ready')=0 then
  if strpos(ddl,needle)=0 then raise exception 'Reviewed Ready Stock rework boundary differs.';end if;
  execute replace(ddl,needle,replacement||chr(10)||needle);
 end if;
 insert into greenloop_private.qc_direct_ready_installation values(id::text,md5(pg_get_functiondef(id)))on conflict(identity)do update set hash=excluded.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(id))where to_regprocedure(implementation)=id;
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
 where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
 end loop;
end;$rework$;
do $journey$declare id regprocedure:='greenloop_private.jst_history(jsonb)'::regprocedure;ddl text;t record;needle text:='if split_part(r->>''id'','':'',1)=''export-box''';begin
 ddl:=pg_get_functiondef(id);
 if strpos(ddl,'event_kind=''initial_qc_direct_ready''')=0 then
  if strpos(ddl,needle)=0 then raise exception 'Reviewed journey stage boundary differs.';end if;
  execute replace(ddl,needle,'if event_kind=''initial_qc_direct_ready''then key:=''ready_stock'';label:=''Initial QC - directly to Ready Stock'';meaning:=''No parts or services required. Initial QC release; not a Final QC inspection.'';'||chr(10)||
   '  elsif event_kind=''initial_qc_saved''and exists(select 1 from greenloop_private.qc_direct_ready dr join public.jobs dj on dj.id=dr.job_id where dr.device_id=d.id and dj.job_number=r->>''job_number'')then key:=''initial_qc'';label:=''Initial QC inspection saved - no work required'';meaning:=''Released directly to Ready Stock in this save.'';'||chr(10)||'  els'||needle);
 end if;
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
 where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
 end loop;
end;$journey$;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values
 ('save_initial_qc_direct_ready_v1','{"page":"initial_qc","capability":"entry"}'),('get_qc_stock_selection_v1','{"page":"initial_qc","capability":"view","read":true}'),('get_qc_direct_ready_version','{"read":true}')
on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.qc_direct_ready_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_direct_ready_installation enable row level security;revoke all on greenloop_private.qc_direct_ready_installation from public,anon,authenticated;
insert into greenloop_private.qc_direct_ready_installation select signature,md5(pg_get_functiondef(signature::regprocedure))from unnest(array[
 'public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)','public.get_qc_stock_selection_v1(text,jsonb,integer,integer)','greenloop_private.jst_history(jsonb)',
 'greenloop_private.qdr_save(uuid,jsonb,jsonb,text,text,text,uuid)','greenloop_private.qdr_stock_selection(text,jsonb,integer,integer)'])signature on conflict(identity)do update set hash=excluded.hash;
create table if not exists greenloop_private.qc_direct_ready_view_seal(id boolean primary key default true check(id),hash text not null);
alter table greenloop_private.qc_direct_ready_view_seal enable row level security;revoke all on greenloop_private.qc_direct_ready_view_seal from public,anon,authenticated;
insert into greenloop_private.qc_direct_ready_view_seal values(true,md5(pg_get_viewdef('greenloop_private.qdr_ready_outcomes'::regclass,true)))on conflict(id)do update set hash=excluded.hash;
create or replace function public.get_qc_direct_ready_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_return_location_version()='20261105-return-location-1'
 and(select count(*)=14 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_direct_ready_installation)
 and exists(select 1 from greenloop_private.qc_direct_ready_view_seal where id and hash=md5(pg_get_viewdef('greenloop_private.qdr_ready_outcomes'::regclass,true)))
 and has_function_privilege('authenticated','public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)','EXECUTE')
 and not has_function_privilege('anon','public.save_initial_qc_direct_ready_v1(uuid,jsonb,jsonb,text,text,text,uuid)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.qc_direct_ready','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.qdr_ready_outcomes','SELECT,INSERT,UPDATE,DELETE')
 then '20261105-qc-direct-ready-1'end;
$$;
revoke all on function public.get_qc_direct_ready_version()from public;grant execute on function public.get_qc_direct_ready_version()to anon,authenticated;
do $$begin if public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'then raise exception 'QC Direct Ready verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_direct_ready_version()as installed_qc_direct_ready_version;
