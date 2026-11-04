-- Save the inspection first; assign and issue the same inspection later.
begin;
do $$begin
 if public.get_report_section_access_version()is distinct from '20261104-report-permissions-1'then raise exception 'Install verified Reports permissions first.';end if;
 if to_regprocedure('public.get_qc_issuance_version()')is not null then if public.get_qc_issuance_version()is distinct from '20261104-qc-inspection-issuance-1'then raise exception 'Existing QC Issuance requires review.';end if;end if;
end;$$;
-- This private ledger preserves the save/issue receipt even when an operational
-- phone is deleted. Active queue readers always join live jobs and inspections.
-- No cross-schema foreign key is added to the audited operational reset graph.
create table if not exists greenloop_private.qc_saved_issuance(
 job_id uuid primary key,device_id uuid not null,inspection_id uuid not null unique,
 state text not null default 'awaiting_issuance'check(state in('awaiting_issuance','issued')),
 request_id uuid not null unique,payload_hash text not null,saved_at timestamptz not null default now(),saved_by uuid not null,saved_by_name text not null,
 issued_at timestamptz,issued_by uuid,destination text,technician_id uuid,work_order_id uuid,issue_request_id uuid unique
);
alter table greenloop_private.qc_saved_issuance enable row level security;revoke all on greenloop_private.qc_saved_issuance from public,anon,authenticated;
create index if not exists qc_saved_issuance_pending on greenloop_private.qc_saved_issuance(saved_at,job_id)where state='awaiting_issuance';
create index if not exists qc_saved_issuance_device on greenloop_private.qc_saved_issuance(device_id)where state='awaiting_issuance';
create or replace function greenloop_private.qcis_require(write_access boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('initial_qc',case when write_access then 'entry'else 'view'end);
 if greenloop_private.damage_tv_only(auth.uid())then raise exception 'Initial QC access is required.'using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.qcis_revision(p_job uuid)returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select md5(jsonb_build_object('receipt',to_jsonb(s),'inspection',to_jsonb(i),'supplier_grade',j.supplier_grade,'gl_grade',d.gc_grade,'battery_health',d.battery_health,'battery_health_unavailable',d.battery_health_unavailable,'current_status',j.current_status,'location',j.current_location_id,
 'parts',(select jsonb_agg(to_jsonb(p)order by p.id)from public.initial_qc_part_requirements p where p.inspection_id=s.inspection_id),
 'findings',(select jsonb_agg(to_jsonb(f)order by f.id)from public.initial_qc_findings f where f.inspection_id=s.inspection_id))::text)
 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id join public.jobs j on j.id=s.job_id join public.devices d on d.id=s.device_id where s.job_id=p_job;
$$;
create or replace function greenloop_private.qcis_rows(p_imeis text[] default null)returns table(job_id uuid,device_id uuid,inspection_id uuid,imei text,model text,storage_gb integer,color text,battery_health smallint,battery_health_unavailable boolean,device_platform text,supplier_code text,supplier_name text,stock_quantity integer,invoice_number text,batch_number text,supplier_grade text,gl_grade text,parts jsonb,services jsonb,saved_at timestamptz,saved_by text,revision text)language sql stable security definer set search_path=pg_catalog,public as $$
 select s.job_id,s.device_id,s.inspection_id,d.imei_1::text,d.model,d.storage_gb,d.color,d.battery_health,d.battery_health_unavailable,d.device_platform::text,sp.supplier_code,
 case when coalesce(public.get_my_partner_name_access(),false)then sp.company_name end,b.planned_quantity,b.invoice_number,b.batch_number,j.supplier_grade,d.gc_grade,
 coalesce((select jsonb_agg(jsonb_build_object('name',p.part_name,'quantity',p.quantity_required)order by p.identified_at,p.id)from public.initial_qc_part_requirements p where p.inspection_id=s.inspection_id and p.status not in('not_required','cancelled')),'[]'),
 coalesce((select jsonb_agg(name order by lower(name))from(select distinct f.check_item name from public.initial_qc_findings f where f.inspection_id=s.inspection_id and f.issue_found and public.is_initial_qc_service(f.check_item))x),'[]'),
 s.saved_at,s.saved_by_name,greenloop_private.qcis_revision(j.id)
 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null
 left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers sp on sp.id=coalesce(j.supplier_id,b.supplier_id)where s.state='awaiting_issuance'and(p_imeis is null or d.imei_1=any(p_imeis));
$$;
create or replace function public.get_initial_qc_work_tray_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.qcis_require();return jsonb_build_object('pending',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'job_number',j.job_number,'received_at',j.received_at,
 'supplier',jsonb_build_object('supplier_code',s.supplier_code,'company_name',case when coalesce(public.get_my_partner_name_access(),false)then s.company_name end),
 'receiving_batch',jsonb_build_object('planned_quantity',b.planned_quantity,'invoice_number',b.invoice_number,'batch_number',b.batch_number),
 'device',jsonb_build_object('imei_1',d.imei_1,'device_number',d.device_number,'serial_number',d.serial_number,'brand',d.brand,'model',d.model,'storage_gb',d.storage_gb,'color',d.color))order by j.received_at,j.id)
 from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=coalesce(j.supplier_id,b.supplier_id)
 where j.deleted_at is null and j.current_status='initial_qc_pending'and not exists(select 1 from greenloop_private.qc_saved_issuance x where x.job_id=j.id and x.state='awaiting_issuance')),'[]'),
 'awaiting_issuance',(select count(*) from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance'));
end;$$;
create or replace function public.get_initial_qc_work_item_v1(p_identifier text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare data jsonb;begin
 perform greenloop_private.qcis_require();perform greenloop_private.reject_secondary_imei(p_identifier);data:=public.get_initial_qc_job_by_identifier(p_identifier);
 if coalesce((data->>'found')::boolean,false)and exists(select 1 from greenloop_private.qc_saved_issuance s where s.job_id=(data->'job'->>'id')::uuid and s.state='awaiting_issuance')then return jsonb_build_object('found',false,'issuance_pending',true,'message','Inspection already saved. Open Lab & Glass Issuance to assign and transfer this phone.');end if;
 return data;
end;$$;
create or replace function public.get_qc_issuance_options_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.qcis_require();return jsonb_build_object('awaiting_issuance',(select count(*) from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance'),'technicians',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',upper(full_name))order by upper(full_name),id)from public.technician_roster where is_active),'[]'));
end;$$;
create or replace function public.get_qc_issuance_rows_v1(p_imeis text[] default null,p_from date default null,p_to date default null,p_offset integer default 0,p_limit integer default 200)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.qcis_require();if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 500 or cardinality(p_imeis)>2000 or exists(select 1 from unnest(p_imeis)x where x!~'^[0-9]{15}$')or p_from>p_to then raise exception 'Choose valid Issuance filters.'using errcode='22023';end if;
 if p_from is not null or p_to is not null then perform greenloop_private.pf_cap('initial_qc','search');end if;
 with filtered as materialized(select s.job_id,s.saved_at,d.imei_1 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance' and(p_imeis is null or d.imei_1=any(p_imeis))and(p_from is null or(s.saved_at at time zone 'Asia/Dubai')::date>=p_from)and(p_to is null or(s.saved_at at time zone 'Asia/Dubai')::date<=p_to)),page as(select *from filtered order by saved_at,job_id offset p_offset limit p_limit)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(p)order by saved_at,job_id)from greenloop_private.qcis_rows(coalesce((select array_agg(imei_1::text)from page),array[]::text[]))p),'[]'),'total',(select count(*)from filtered))into result;return result;
end;$$;
create or replace function public.save_initial_qc_inspection_v1(p_job_id uuid,p_findings jsonb default '[]',p_part_requests jsonb default '[]',p_supplier_grade text default null,p_gc_grade text default null,p_notes text default null,p_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid();dev uuid;inspection uuid;request uuid:=coalesce(p_request_id,gen_random_uuid());fingerprint text;existing greenloop_private.qc_saved_issuance%rowtype;part jsonb;finding jsonb;parts jsonb;sg text:=nullif(upper(regexp_replace(btrim(coalesce(p_supplier_grade,'')),'\s+',' ','g')),'');gl text:=nullif(upper(regexp_replace(btrim(coalesce(p_gc_grade,'')),'\s+',' ','g')),'');pri public.qc_priority;
begin
 perform greenloop_private.qcis_require(true);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 parts:=greenloop_private.qca_housing(gl,coalesce(p_part_requests,'[]'));perform greenloop_private.qdp_validate(parts);
 if jsonb_typeof(p_findings)is distinct from 'array'or jsonb_array_length(p_findings)>100 or length(coalesce(p_notes,''))>4000 then raise exception 'Choose valid Initial QC findings.'using errcode='22023';end if;
 if sg is not null and not greenloop_private.qc_grade_allowed('supplier_grade',sg)or gl is not null and not greenloop_private.qc_grade_allowed('gc_grade',gl)then raise exception 'Choose saved Supplier and GL Grades from Manage Dropdowns.'using errcode='22023';end if;
 for finding in select value from jsonb_array_elements(p_findings)loop if jsonb_typeof(finding)is distinct from 'object'or length(btrim(coalesce(finding->>'check_item','')))not between 1 and 120 or length(btrim(coalesce(finding->>'action_required','')))not between 1 and 500 then raise exception 'Each finding needs a name and required action.'using errcode='22023';end if;end loop;
 fingerprint:=md5(jsonb_build_object('job',p_job_id,'parts',parts,'findings',p_findings,'supplier_grade',sg,'gl_grade',gl,'notes',p_notes)::text);
 select *into existing from greenloop_private.qc_saved_issuance where job_id=p_job_id for update;
 if existing.job_id is not null then
  if existing.request_id=request and existing.payload_hash=fingerprint then return jsonb_build_object('inspection_id',existing.inspection_id,'job_id',p_job_id,'saved',true,'state',existing.state);end if;
  raise exception 'This inspection is already saved. Use Lab & Glass Issuance, or Reports for an audited correction.'using errcode='22023';
 end if;
 if exists(select 1 from greenloop_private.qc_saved_issuance where request_id=request)then raise exception 'This save request belongs to another phone.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('save_initial_qc_inspection_v1',jsonb_build_object('p_job_id',p_job_id));begin
  perform public.greenloop_require_entry(array['initial_qc']::text[]);
  select j.device_id into dev from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.id=p_job_id and j.deleted_at is null and j.current_status='initial_qc_pending'for update of j,d;
  if dev is null then raise exception 'This phone is not waiting for Initial QC.'using errcode='22023';end if;
  if exists(select 1 from public.initial_qc_inspections where job_id=p_job_id)or exists(select 1 from public.job_work_orders where job_id=p_job_id)then raise exception 'This phone already has an inspection or workflow. Review it in Reports.'using errcode='22023';end if;
  update public.jobs set supplier_grade=sg where id=p_job_id;update public.devices set gc_grade=gl where id=dev;
  insert into public.initial_qc_inspections(job_id,device_id,notes,work_required,inspected_by,inspected_at)values(p_job_id,dev,nullif(btrim(p_notes),''),jsonb_array_length(parts)>0 or jsonb_array_length(p_findings)>0,actor,now())returning id into inspection;
  for finding in select value from jsonb_array_elements(p_findings)loop
   begin pri:=coalesce((finding->>'priority')::public.qc_priority,'normal');exception when invalid_text_representation then pri:='normal';end;
   insert into public.initial_qc_findings(inspection_id,check_item,issue_found,action_required,department,priority,notes)values(inspection,btrim(finding->>'check_item'),true,btrim(finding->>'action_required'),'laboratory',pri,nullif(btrim(finding->>'notes'),''));
  end loop;
  for part in select value from jsonb_array_elements(parts)loop insert into public.initial_qc_part_requirements(job_id,device_id,inspection_id,part_name,quantity_required,notes,identified_by)values(p_job_id,dev,inspection,btrim(part->>'part_name'),(part->>'quantity')::integer,nullif(btrim(part->>'notes'),''),actor);end loop;
  insert into greenloop_private.qc_saved_issuance(job_id,device_id,inspection_id,request_id,payload_hash,saved_by,saved_by_name)values(p_job_id,dev,inspection,request,fingerprint,actor,coalesce((select upper(full_name)from public.user_profiles where id=actor),'STAFF'));
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(dev,p_job_id,'initial_qc_saved','Initial QC saved - awaiting Lab & Glass Issuance',jsonb_build_object('inspection_id',inspection,'supplier_grade',sg,'gl_grade',gl,'parts',parts,'services',(select services from greenloop_private.qcis_rows(array[(select imei_1 from public.devices where id=dev)])where job_id=p_job_id),'transferred',false),actor);
 exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();return jsonb_build_object('saved',true,'state','awaiting_issuance','inspection_id',inspection,'job_id',p_job_id);
end;$$;
create or replace function public.issue_initial_qc_inspection_v1(p_job_id uuid,p_revision text,p_destination text,p_technician_roster_id uuid default null,p_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid();s greenloop_private.qc_saved_issuance%rowtype;r record;t public.technician_roster%rowtype;dest text:=lower(btrim(coalesce(p_destination,'')));wo uuid;number text;step uuid;from_loc uuid;to_loc uuid;request uuid:=coalesce(p_request_id,gen_random_uuid());output jsonb;
begin
 perform greenloop_private.qcis_require(true);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 if dest not in('lab_glass','b_dept')then raise exception 'Choose Lab & Glass or B-DEPT.'using errcode='22023';end if;
 select *into s from greenloop_private.qc_saved_issuance where job_id=p_job_id for update;
 if s.job_id is null then raise exception 'Save this phone in Initial QC before issuing it.'using errcode='22023';end if;
 if s.state='issued'then
  if s.issue_request_id=request and s.destination=dest and s.technician_id is not distinct from p_technician_roster_id then return jsonb_build_object('issued',true,'destination',s.destination,'work_order_id',s.work_order_id,'job_id',p_job_id,'inspection_id',s.inspection_id,'work_order_number',(select work_order_number from public.job_work_orders where id=s.work_order_id),'technician_name',case when s.destination='b_dept'then 'B-DEPT'else(select upper(full_name)from public.technician_roster where id=s.technician_id)end,'replayed',true);end if;
  raise exception 'This phone has already been issued. Refresh to check its current stage.'using errcode='22023';
 end if;
 perform 1 from public.jobs j join public.devices d on d.id=j.device_id where j.id=p_job_id for update of j,d;
 perform 1 from public.initial_qc_inspections where id=s.inspection_id for update;perform 1 from public.initial_qc_findings where inspection_id=s.inspection_id for update;perform 1 from public.initial_qc_part_requirements where inspection_id=s.inspection_id for update;
 select *into r from greenloop_private.qcis_rows(array[(select imei_1 from public.devices where id=s.device_id)])where job_id=p_job_id;
 if r.job_id is null then raise exception 'This phone is no longer awaiting Issuance.'using errcode='22023';end if;
 if p_revision is null or p_revision is distinct from r.revision then raise exception 'The saved inspection changed. Reload this phone before transferring it.'using errcode='40001';end if;
 if dest='lab_glass'then
  select *into t from public.technician_roster where id=p_technician_roster_id and is_active for share;if t.id is null then raise exception 'Select an active Lab technician.'using errcode='22023';end if;
 else
  if jsonb_array_length(r.parts)>0 or jsonb_array_length(r.services)>0 or upper(coalesce(r.gl_grade,''))='D'then raise exception 'B-DEPT direct routing keeps the existing no-parts/no-services rule. Send this repair phone to Lab & Glass.'using errcode='22023';end if;
  if p_technician_roster_id is not null then raise exception 'B-DEPT direct routing does not assign a Lab technician.'using errcode='22023';end if;
 end if;
 if exists(select 1 from public.job_work_orders where job_id=p_job_id)then raise exception 'This phone already has a workflow. Review it in Reports.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('issue_initial_qc_inspection_v1',jsonb_build_object('p_job_id',p_job_id));begin
  perform public.greenloop_require_entry(array['initial_qc']::text[]);
  select current_location_id into from_loc from public.jobs where id=p_job_id;
  insert into public.job_work_orders(work_order_number,job_id,device_id,initial_qc_inspection_id,work_required,created_by)values('WO-'||to_char(current_date,'YYYY')||'-'||lpad(nextval('public.work_order_number_sequence'::regclass)::text,5,'0'),p_job_id,s.device_id,s.inspection_id,dest='lab_glass',actor)returning id,work_order_number into wo,number;
  if dest='lab_glass'then
   select id into to_loc from public.locations where location_code='LAB'and is_active limit 1;if to_loc is null then raise exception 'Laboratory location is not configured.'using errcode='22023';end if;
   insert into public.job_work_order_steps(work_order_id,step_order,department,step_status,assigned_technician_roster_id,assigned_technician_name,assigned_at)values(wo,10,'laboratory','in_progress',t.id,t.full_name,now())returning id into step;
   insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(wo,20,'final_qc','pending');
   update public.jobs set current_status='laboratory_pending',current_location_id=to_loc where id=p_job_id;update public.devices set current_status='laboratory_pending',current_location_id=to_loc where id=s.device_id;
   insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)values(s.device_id,p_job_id,from_loc,to_loc,'Initial QC saved inspection issued to Lab & Glass',actor);
   insert into public.laboratory_work_records(job_id,device_id,work_order_step_id,rework_cycle,assigned_at,started_at,notes)values(p_job_id,s.device_id,step,0,now(),now(),'Issued from saved Initial QC inspection');
   if not exists(select 1 from public.technician_job_timers where job_id=p_job_id and stopped_at is null)then insert into public.technician_job_timers(job_id,device_id,technician_roster_id,technician_name,started_at)values(p_job_id,s.device_id,t.id,t.full_name,now());end if;
   perform greenloop_private.qdp_publish(p_job_id,s.inspection_id);perform greenloop_private.wp_seed_services(p_job_id);
  else
   select id into to_loc from public.locations where location_code='FINAL-QC'and is_active limit 1;if to_loc is null then raise exception 'Final QC routing location is not configured.'using errcode='22023';end if;
   insert into public.job_work_order_steps(work_order_id,step_order,department,step_status)values(wo,10,'final_qc','in_progress');
   update public.jobs set current_status='final_qc_pending',current_location_id=to_loc where id=p_job_id;update public.devices set current_status='final_qc_pending',current_location_id=to_loc where id=s.device_id;
   insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,moved_by)values(s.device_id,p_job_id,from_loc,to_loc,'Initial QC saved inspection - direct B-DEPT routing',actor);
   perform public.route_final_qc_pass_to_frame_v3(p_job_id,null,r.battery_health,'Initial QC saved inspection issued directly to B-DEPT',r.battery_health_unavailable);
  end if;
  update greenloop_private.qc_saved_issuance set state='issued',issued_at=now(),issued_by=actor,destination=dest,technician_id=p_technician_roster_id,work_order_id=wo,issue_request_id=request where job_id=p_job_id;
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(s.device_id,p_job_id,'initial_qc_issued','Saved Initial QC inspection issued',jsonb_build_object('inspection_id',s.inspection_id,'work_order_id',wo,'work_order_number',number,'destination',dest,'technician_id',t.id,'technician_name',t.full_name),actor);
  output:=jsonb_build_object('issued',true,'job_id',p_job_id,'inspection_id',s.inspection_id,'destination',dest,'work_order_id',wo,'work_order_number',number,'technician_name',case when dest='lab_glass'then upper(t.full_name)else 'B-DEPT'end);
 exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();return output;
end;$$;
create or replace function greenloop_private.qcis_stage(data jsonb,identifier text)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$select case when coalesce((data->>'found')::boolean,false)and exists(select 1 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance' and d.imei_1=coalesce(data->>'primary_imei',identifier))then data||jsonb_build_object('current_stage','Lab & Glass Issuance','inspection_saved',true)else data end;$$;
do $stage$declare ddl text;impl text;begin select split_part(implementation,'(',1)into impl from greenloop_private.office_routines where to_regprocedure(identity)='public.get_imei_duplicate_stage_v1(text)'::regprocedure;ddl:=pg_get_functiondef('public.get_imei_duplicate_stage_v1(text)'::regprocedure);if strpos(ddl,'qcis_stage')=0 then if strpos(ddl,'return '||impl||'($1);')=0 then raise exception 'Reviewed IMEI stage boundary differs.';end if;execute replace(ddl,'return '||impl||'($1);','return greenloop_private.qcis_stage('||impl||'($1),$1);');end if;end;$stage$;
-- Reports show identified requirements immediately. Issuance converts them to
-- normal Parts requests, so the pre-issuance projection then disappears.
do $raw$declare ddl text;begin
 ddl:=pg_get_functiondef('greenloop_private.rp_raw(date,date)'::regprocedure);
 if strpos(ddl,'qcis_report_parts')=0 then
  execute replace(ddl,'FUNCTION greenloop_private.rp_raw(','FUNCTION greenloop_private.qcis_report_original(');
 end if;
end;$raw$;
create or replace function greenloop_private.qcis_report_parts(data jsonb,f date,t date)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$select jsonb_set(data,'{parts_requests}',coalesce(data->'parts_requests','[]')||coalesce((select jsonb_agg(jsonb_build_object('requested_at',i.inspected_at,'imei',d.imei_1,'model',concat_ws(' ',d.brand,d.model),'job_number',j.job_number,'part_name',p.part_name,'requested',p.quantity_required,'issued',0,'installed',0,'returned',0,'status','identified','source','QC Saved - Awaiting Issuance')order by i.inspected_at desc,p.id)
 from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id join public.initial_qc_part_requirements p on p.inspection_id=i.id and p.status='identified'join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance'and(i.inspected_at at time zone 'Asia/Dubai')::date between f and t),'[]'));$$;
create or replace function greenloop_private.rp_raw(p_date_from date,p_date_to date)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin return greenloop_private.qcis_report_parts(greenloop_private.qcis_report_original(p_date_from,p_date_to),p_date_from,p_date_to);end;$$;
insert into greenloop_private.capability_rpc_rules values('get_initial_qc_work_tray_v1','{"page": "initial_qc", "capability": "view", "read": true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_initial_qc_work_item_v1','{"page": "initial_qc", "capability": "view", "read": true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_options_v1','{"page": "initial_qc", "capability": "view", "read": true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_rows_v1','{"page": "initial_qc", "capability": "view", "read": true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_initial_qc_inspection_v1','{"page": "initial_qc", "capability": "entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('issue_initial_qc_inspection_v1','{"page": "initial_qc", "capability": "entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_version','{"read": true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_initial_qc_work_tray_v1','get_initial_qc_work_item_v1','get_qc_issuance_options_v1','get_qc_issuance_rows_v1','save_initial_qc_inspection_v1','issue_initial_qc_inspection_v1')loop
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
 select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),case when f.provolatile='s'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;end;$wrap$;
do $seal$declare ids regprocedure[]:=array['public.get_imei_duplicate_stage_v1(text)'::regprocedure,'greenloop_private.rp_raw(date,date)'::regprocedure];t record;begin
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using ids;end loop;
end;$seal$;
create table if not exists greenloop_private.qc_issuance_installation(identity text primary key,hash text not null);alter table greenloop_private.qc_issuance_installation enable row level security;revoke all on greenloop_private.qc_issuance_installation from public,anon,authenticated;
create or replace function public.get_qc_issuance_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_report_section_access_version()='20261104-report-permissions-1'
 and(select count(*)=21 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_issuance_installation)
 and not exists(select 1 from unnest(array['qc_saved_issuance','qc_issuance_installation'])t join pg_class c on c.oid=('greenloop_private.'||t)::regclass where not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not exists(select 1 from greenloop_private.qc_issuance_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 then '20261104-qc-inspection-issuance-1'end;$$;
revoke all on function public.get_qc_issuance_version()from public;grant execute on function public.get_qc_issuance_version()to anon,authenticated;
do $save$declare f record;begin for f in select p.oid from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['qcis_require','qcis_revision','qcis_rows','qcis_stage','qcis_report_original','qcis_report_parts'])loop execute format('revoke all on function %s from public,anon,authenticated',f.oid::regprocedure);end loop;end;$save$;
insert into greenloop_private.qc_issuance_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['qcis_require','qcis_revision','qcis_rows','qcis_stage','qcis_report_original','qcis_report_parts','rp_raw'])or p.pronamespace='public'::regnamespace and p.proname=any(array['get_initial_qc_work_tray_v1','get_initial_qc_work_item_v1','get_qc_issuance_options_v1','get_qc_issuance_rows_v1','save_initial_qc_inspection_v1','issue_initial_qc_inspection_v1','get_qc_issuance_version','get_imei_duplicate_stage_v1'])or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_initial_qc_work_tray_v1()'::regprocedure,'public.get_initial_qc_work_item_v1(text)'::regprocedure,'public.get_qc_issuance_options_v1()'::regprocedure,'public.get_qc_issuance_rows_v1(text[],date,date,integer,integer)'::regprocedure,'public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure,'public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_qc_issuance_version()is distinct from '20261104-qc-inspection-issuance-1'then raise exception 'QC inspection / Issuance verification failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_issuance_version()as installed_qc_issuance_version;
