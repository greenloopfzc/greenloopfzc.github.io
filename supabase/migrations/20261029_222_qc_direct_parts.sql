-- Initial QC publishes physical parts atomically to Lab and Parts.
-- Existing issues, return history, prices, services and permissions are preserved.
begin;
do $$begin if public.get_parts_report_filters_version()is distinct from '20261029-parts-report-filters-1'then raise exception 'Verified Parts Report Filters are required.';end if;if to_regprocedure('public.get_qc_direct_parts_version()')is not null then if public.get_qc_direct_parts_version()is distinct from '20261029-qc-direct-parts-1'then raise exception 'Existing QC direct Parts needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.qc_direct_parts_orders(order_id uuid primary key references greenloop_private.parts_flow_orders(id),job_id uuid not null,cycle integer not null,inspection_id uuid not null,created_at timestamptz not null default now(),created_by uuid,unique(job_id,cycle));
alter table greenloop_private.qc_direct_parts_orders enable row level security;revoke all on greenloop_private.qc_direct_parts_orders from public,anon,authenticated;
create or replace function greenloop_private.qdp_validate(p_parts jsonb)returns void language plpgsql immutable set search_path=pg_catalog,public as $$begin
 if jsonb_typeof(coalesce(p_parts,'[]'))is distinct from 'array'or jsonb_array_length(coalesce(p_parts,'[]'))>100 then raise exception 'Choose a valid parts list.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(p_parts,'[]'))x where jsonb_typeof(x)<>'object'or x->>'part_name'is null or length(regexp_replace(btrim(x->>'part_name'),'\s+',' ','g'))not between 1 and 120 or x->>'part_name'~'[[:cntrl:]]'or coalesce(x->>'quantity','')!~'^[0-9]{1,5}$'or(x->>'quantity')::integer not between 1 and 10000)then raise exception 'Each part needs a valid name and positive whole quantity.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(p_parts,'[]'))x group by greenloop_private.pp_key(x->>'part_name')having count(*)>1)then raise exception 'The same part is selected twice. Use one line and its required quantity.'using errcode='22023';end if;
end;$$;
create or replace function greenloop_private.qdp_publish(p_job uuid,p_inspection uuid)returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$declare dev uuid;st uuid;cy integer;ord uuid;req uuid;ids uuid[]:='{}';q record;begin
 perform pg_advisory_xact_lock(19920261026);
 select j.device_id into dev from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.id=p_job and j.deleted_at is null and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')for update of j;
 if dev is null then raise exception 'Initial QC parts require an active Lab / Glass phone.'using errcode='22023';end if;
 select s.id into st from public.job_work_orders w join public.job_work_order_steps s on s.work_order_id=w.id and s.department in('laboratory','glass')and s.step_status='in_progress'where w.job_id=p_job and w.initial_qc_inspection_id=p_inspection order by s.step_order,s.id limit 1;
 if st is null then raise exception 'The Initial QC Lab assignment could not be verified.'using errcode='22023';end if;
 cy:=greenloop_private.pf_cycle(p_job);select id into ord from greenloop_private.parts_flow_orders where job_id=p_job and cycle=cy for update;if ord is not null then return ord;end if;
 if not exists(select 1 from public.initial_qc_part_requirements where job_id=p_job and inspection_id=p_inspection and status='identified')then return null;end if;
 -- Do not merge unrelated historical/manual requests into a newly generated QC order.
 if exists(select 1 from public.job_part_requests where job_id=p_job and not exists(select 1 from greenloop_private.parts_flow_requests m where m.request_id=job_part_requests.id))then raise exception 'Existing unlinked parts require review before automatic QC publication.'using errcode='22023';end if;
 perform greenloop_private.pf_context(true);
 for q in select min(regexp_replace(btrim(part_name),'\s+',' ','g'))name,sum(quantity_required)::integer qty from public.initial_qc_part_requirements where job_id=p_job and inspection_id=p_inspection and status='identified'group by greenloop_private.pp_key(part_name)loop
  if q.name is null or length(q.name)not between 1 and 120 or q.qty not between 1 and 10000 then raise exception 'Initial QC contains an invalid part requirement.'using errcode='22023';end if;
  insert into public.job_part_requests(job_id,device_id,part_name,quantity_requested,request_source,requested_by)values(p_job,dev,q.name,q.qty,'initial_qc',auth.uid())returning id into req;ids:=array_append(ids,req);
 end loop;
 -- Resolve QC statuses before creating the protected order (also supports owner-run installation).
 update public.initial_qc_part_requirements set status='requested',reviewed_by=auth.uid(),reviewed_at=now()where job_id=p_job and inspection_id=p_inspection and status='identified';
 insert into greenloop_private.parts_flow_orders(job_id,device_id,step_id,cycle,submitted_by)values(p_job,dev,st,cy,auth.uid())returning id into ord;
 insert into greenloop_private.parts_flow_requests select x,ord from unnest(ids)x;
 insert into greenloop_private.qc_direct_parts_orders(order_id,job_id,cycle,inspection_id,created_by)values(ord,p_job,cy,p_inspection,auth.uid());
 insert into greenloop_private.parts_flow_audit(order_id,action,actor,details)values(ord,'initial_qc_parts_ordered',auth.uid(),jsonb_build_object('inspection_id',p_inspection,'requests',cardinality(ids)));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(dev,p_job,'initial_qc_parts_ordered','Initial QC sent required parts directly to Parts',jsonb_build_object('order_id',ord,'requests',cardinality(ids)),auth.uid());
 perform greenloop_private.pf_context(false);return ord;
end;$$;
create or replace function greenloop_private.qdp_state(p jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('additional_only',coalesce((p->>'submitted')::boolean,false),'qc_parts_sent',exists(select 1 from greenloop_private.qc_direct_parts_orders where order_id=nullif(p->>'order_id','')::uuid),'reorder_available',coalesce((select jsonb_agg(jsonb_build_object('name',x.name,'quantity',x.qty)order by x.name)from(
 select min(r.part_name)name,sum(greatest(0,ret.quantity-coalesce((select sum(src.quantity)from greenloop_private.parts_reorder_sources src join public.job_part_requests used on used.id=src.request_id where src.return_id=ret.id and used.status<>'cancelled'),0)))::integer qty from greenloop_private.parts_flow_returns ret join public.part_issue_transactions iss on iss.id=ret.issue_id join public.job_part_requests r on r.id=iss.part_request_id where ret.order_id=nullif(p->>'order_id','')::uuid and ret.status in('pending','approved')group by greenloop_private.pp_key(r.part_name)
 )x where x.qty>0),'[]'));
$$;
revoke all on function greenloop_private.qdp_validate(jsonb),greenloop_private.qdp_publish(uuid,uuid),greenloop_private.qdp_state(jsonb)from public,anon,authenticated;
-- Patch only verified implementation bodies; their public authentication and action guards stay in place.
do $patch$declare impl text;ddl text;needle text;replacement text;t text;f regprocedure;changed regprocedure[]:='{}';begin
 select implementation into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_initial_qc_lab_first(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed Initial QC implementation is missing.';end if;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-direct-parts-222')=0 then
  needle:='  -- Technician-only selection must still create a Laboratory step.';if strpos(ddl,needle)=0 then raise exception 'Initial QC source differs from the reviewed workflow.';end if;
  ddl:=replace(ddl,needle,E'  -- greenloop-qc-direct-parts-222\n  perform greenloop_private.qdp_validate(p_part_requests);\n'||needle);
  needle:='  insert into public.device_events (';if strpos(ddl,needle)=0 then raise exception 'Initial QC completion boundary is missing.';end if;ddl:=replace(ddl,needle,E'  perform greenloop_private.qdp_publish(p_job_id,v_result.inspection_id);\n\n'||needle);
  ddl:=replace(ddl,'''parts_queue_created'', false','''parts_queue_created'', v_identified_count > 0');ddl:=replace(ddl,'Parts are identified for Laboratory review and do not notify Parts yet.','Parts are identified below and published to Parts in this transaction.');
  needle:='  if not public.has_role(';if strpos(ddl,needle)=0 then raise exception 'Initial QC role guard is missing.';end if;ddl:=replace(ddl,needle,E'  perform greenloop_private.pf_cap(''initial_qc'',''entry'');\n  perform pg_advisory_xact_lock(19920261026);\n'||needle);execute ddl;
 end if;changed:=array_append(changed,to_regprocedure(impl));
 impl:='greenloop_private.ps_submit_original(uuid,integer,jsonb,jsonb)';ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-direct-parts-222')=0 then
  needle:='if p_revision is distinct from coalesce(o.revision,0)then';if strpos(ddl,needle)=0 then raise exception 'Reviewed initial Lab submission source is missing.';end if;
  replacement:=E'-- greenloop-qc-direct-parts-222\n if o.id is not null then raise exception ''Parts are already sent. Order additional parts or return issued parts before reordering.''using errcode=''22023'';end if;\n '||needle;execute replace(ddl,needle,replacement);
 end if;changed:=array_append(changed,to_regprocedure(impl));
 select implementation into impl from greenloop_private.office_routines where to_regprocedure(identity)='public.add_lab_parts_v1(uuid,integer,jsonb)'::regprocedure;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-direct-parts-222')=0 then
  needle:='if o.id is null or o.first_issued_at is null or o.completed_at is not null then';if strpos(ddl,needle)=0 then raise exception 'Reviewed additional parts source is missing.';end if;
  ddl:=replace(ddl,needle,E'-- greenloop-qc-direct-parts-222\n if o.id is null or o.completed_at is not null then');ddl:=replace(ddl,'Use the initial parts list before the first issue.','Send the first parts list before adding extra parts.');execute ddl;
 end if;changed:=array_append(changed,to_regprocedure(impl));
 impl:='greenloop_private.pp_plan(uuid)';ddl:=pg_get_functiondef(to_regprocedure(impl));
 if strpos(ddl,'greenloop-qc-direct-parts-222')=0 then
  needle:=$n$return p||jsonb_build_object('parts',parts,'part_history',p->'parts');$n$;if strpos(ddl,needle)=0 then raise exception 'Reviewed Lab parts plan source is missing.';end if;
  execute replace(ddl,needle,E'-- greenloop-qc-direct-parts-222\n '||$n$return p||jsonb_build_object('parts',parts,'part_history',p->'parts')||greenloop_private.qdp_state(p);$n$);
 end if;changed:=array_append(changed,to_regprocedure(impl));
 foreach f in array changed loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  foreach t in array array['parts_flow_installation','parts_services_installation','parts_simple_installation','full_imei_workflow_installation','qc_work_options_installation','qc_dropdowns_installation']loop
   if to_regclass('greenloop_private.'||t)is not null then execute format('update greenloop_private.%I set hash=md5(pg_get_functiondef($1))where to_regprocedure(identity)=$1',t)using f;end if;
  end loop;
 end loop;
end;$patch$;
-- Safe pending first-cycle QC lists only. Existing orders/manual requests are never rebuilt.
do $backfill$declare x record;begin
 for x in select distinct w.job_id,w.initial_qc_inspection_id iq from public.job_work_orders w join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=w.device_id and d.deleted_at is null where j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and exists(select 1 from public.job_work_order_steps s where s.work_order_id=w.id and s.department in('laboratory','glass')and s.step_status='in_progress')and greenloop_private.pf_cycle(w.job_id)<=1 and exists(select 1 from public.initial_qc_part_requirements q where q.job_id=w.job_id and q.inspection_id=w.initial_qc_inspection_id and q.status='identified')and not exists(select 1 from greenloop_private.parts_flow_orders o where o.job_id=w.job_id)and not exists(select 1 from public.job_part_requests r where r.job_id=w.job_id)and not exists(select 1 from public.lab_manual_part_installations m where m.job_id=w.job_id)loop
  perform greenloop_private.qdp_publish(x.job_id,x.iq);
 end loop;
end;$backfill$;
create table if not exists greenloop_private.qc_direct_parts_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_direct_parts_installation enable row level security;revoke all on greenloop_private.qc_direct_parts_installation from public,anon,authenticated;
create or replace function public.get_qc_direct_parts_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_report_filters_version()='20261029-parts-report-filters-1'
 and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_direct_parts_installation)
 and not exists(select 1 from unnest(array['qc_direct_parts_orders','qc_direct_parts_installation'])t where has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not exists(select 1 from greenloop_private.qc_direct_parts_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and(select count(*)=2 from pg_class where oid in('greenloop_private.qc_direct_parts_orders'::regclass,'greenloop_private.qc_direct_parts_installation'::regclass)and relrowsecurity)
 then '20261029-qc-direct-parts-1'end;$$;
revoke all on function public.get_qc_direct_parts_version()from public;grant execute on function public.get_qc_direct_parts_version()to anon,authenticated;
insert into greenloop_private.qc_direct_parts_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.qdp_validate(jsonb)'::regprocedure,'greenloop_private.qdp_publish(uuid,uuid)'::regprocedure,'greenloop_private.qdp_state(jsonb)'::regprocedure,'greenloop_private.ps_submit_original(uuid,integer,jsonb,jsonb)'::regprocedure,'greenloop_private.pp_plan(uuid)'::regprocedure,'public.get_qc_direct_parts_version()'::regprocedure)or p.oid in(select to_regprocedure(implementation)from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_initial_qc_lab_first(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure)or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.add_lab_parts_v1(uuid,integer,jsonb)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_qc_direct_parts_version()is distinct from '20261029-qc-direct-parts-1'then raise exception 'Initial QC direct Parts verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_direct_parts_version()as installed_qc_direct_parts_version;
