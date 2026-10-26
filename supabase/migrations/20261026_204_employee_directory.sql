-- Shared employee choices and visible unassigned Laboratory / Glass work.
begin;
do $$begin if public.get_parts_badges_version()is distinct from '20261026-parts-badges-1'then raise exception 'Verified Parts badges are required.';end if;if to_regprocedure('public.get_employee_directory_version()')is not null then if public.get_employee_directory_version()is distinct from '20261026-employees-1'then raise exception 'Existing employee directory needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.employee_links(roster_id uuid primary key,option_id uuid not null unique);
create table if not exists greenloop_private.employee_sync_context(pid integer not null,tx bigint not null,primary key(pid,tx));
alter table greenloop_private.employee_links enable row level security;alter table greenloop_private.employee_sync_context enable row level security;
revoke all on greenloop_private.employee_links,greenloop_private.employee_sync_context from public,anon,authenticated;
create or replace function greenloop_private.ed_key(p_name text)returns text language sql immutable set search_path=pg_catalog as $$select lower(btrim(regexp_replace(p_name,'[[:space:]]+',' ','g')));$$;
-- Merge active choices without replacing either table's existing IDs or history.
do $$declare o record;t record;oid uuid;begin perform pg_advisory_xact_lock(20420261026);insert into greenloop_private.employee_sync_context values(pg_backend_pid(),txid_current())on conflict do nothing;
 for o in select *from public.manual_damage_options where kind='employee'and is_active order by sort_order,id loop
 select r.*into t from public.technician_roster r left join greenloop_private.employee_links l on l.roster_id=r.id where l.option_id=o.id or greenloop_private.ed_key(r.full_name)=o.normalized_label order by(r.id=(select roster_id from greenloop_private.employee_links where option_id=o.id))desc nulls last,r.is_active desc,r.created_at,r.id limit 1;
 if t.id is null then insert into public.technician_roster(full_name,is_active)values(o.label,true)returning *into t;else update public.technician_roster set is_active=true where id=t.id;end if;
 update public.manual_damage_options set label=t.full_name,is_active=true where id=o.id;insert into greenloop_private.employee_links values(t.id,o.id)on conflict(roster_id)do update set option_id=excluded.option_id;
 end loop;
 for t in select *from public.technician_roster where is_active order by created_at,id loop
 select id into oid from public.manual_damage_options where kind='employee'and normalized_label=greenloop_private.ed_key(t.full_name);
 if oid is null then insert into public.manual_damage_options(kind,label,is_active,created_by)values('employee',t.full_name,true,auth.uid())returning id into oid;else update public.manual_damage_options set label=t.full_name,is_active=true,archived_at=null,archived_by=null where id=oid;end if;
 insert into greenloop_private.employee_links values(t.id,oid)on conflict(roster_id)do update set option_id=excluded.option_id;
 end loop;delete from greenloop_private.employee_sync_context where pid=pg_backend_pid()and tx=txid_current();end;$$;
create or replace function greenloop_private.ed_lock()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$begin perform pg_advisory_xact_lock(20420261026);return null;end;$$;
create or replace function greenloop_private.ed_guard()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$declare rid uuid;k text;begin
 if exists(select 1 from greenloop_private.employee_sync_context where pid=pg_backend_pid()and tx=txid_current())then return new;end if;
 if tg_table_name='manual_damage_options'and coalesce(case when tg_op='DELETE'then to_jsonb(old)->>'kind' else to_jsonb(new)->>'kind' end,'')<>'employee'and(tg_op='INSERT'or to_jsonb(old)->>'kind'<>'employee')then if tg_op='DELETE'then return old;else return new;end if;end if;
 if current_setting('role',true)in('authenticated','anon')and not exists(select 1 from greenloop_private.capability_scope where backend_pid=pg_backend_pid()and transaction_id=txid_current()and user_id=auth.uid())then raise exception 'Use the permitted employee name controls.'using errcode='42501';end if;
 if tg_op='DELETE'then raise exception 'Archive the employee name to preserve its history.'using errcode='22023';end if;
 if tg_table_name='manual_damage_options'and to_jsonb(new)->>'kind'<>'employee'then raise exception 'An employee choice cannot change its type.'using errcode='22023';end if;
 if tg_op='UPDATE'and old.is_active and not new.is_active then
 if tg_table_name='technician_roster'then rid:=old.id;k:=greenloop_private.ed_key(old.full_name);else select roster_id into rid from greenloop_private.employee_links where option_id=old.id;k:=old.normalized_label;end if;
 if exists(select 1 from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=w.device_id and d.deleted_at is null where s.step_status='in_progress'and(s.assigned_technician_roster_id=rid or s.assigned_technician_roster_id is null and greenloop_private.ed_key(s.assigned_technician_name)=k))then raise exception 'Complete or reassign this employee''s pending phones before removing the name.'using errcode='22023';end if;
 end if;return new;
end;$$;
create or replace function greenloop_private.ed_sync()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$declare rid uuid;oid uuid;t public.technician_roster%rowtype;begin
 if exists(select 1 from greenloop_private.employee_sync_context where pid=pg_backend_pid()and tx=txid_current())then return new;end if;if tg_table_name='manual_damage_options'and to_jsonb(new)->>'kind'<>'employee'then return new;end if;
 insert into greenloop_private.employee_sync_context values(pg_backend_pid(),txid_current());
 if tg_table_name='technician_roster'then
 rid:=new.id;select option_id into oid from greenloop_private.employee_links where roster_id=rid;if oid is null then select id into oid from public.manual_damage_options where kind='employee'and normalized_label=greenloop_private.ed_key(new.full_name);end if;
 if exists(select 1 from greenloop_private.employee_links where option_id=oid and roster_id<>rid)then raise exception 'This employee name already has a shared record.'using errcode='22023';end if;
 if oid is null then insert into public.manual_damage_options(kind,label,is_active,created_by)values('employee',new.full_name,new.is_active,auth.uid())returning id into oid;else update public.manual_damage_options set label=new.full_name,is_active=new.is_active,archived_at=case when new.is_active then null else coalesce(archived_at,now())end,archived_by=case when new.is_active then null else auth.uid()end where id=oid;end if;
 else
 oid:=new.id;select roster_id into rid from greenloop_private.employee_links where option_id=oid;if rid is null then select id into rid from public.technician_roster where greenloop_private.ed_key(full_name)=new.normalized_label order by is_active desc,created_at,id limit 1;end if;
 if exists(select 1 from greenloop_private.employee_links where roster_id=rid and option_id<>oid)then raise exception 'This employee name already has a shared record.'using errcode='22023';end if;
 if rid is null then insert into public.technician_roster(full_name,is_active)values(new.label,new.is_active)returning id into rid;else update public.technician_roster set full_name=new.label,is_active=new.is_active where id=rid;end if;
 end if;
 insert into greenloop_private.employee_links values(rid,oid)on conflict(roster_id)do update set option_id=excluded.option_id;
 delete from greenloop_private.employee_sync_context where pid=pg_backend_pid()and tx=txid_current();return new;
end;$$;
do $$declare t text;begin foreach t in array array['technician_roster','manual_damage_options']loop
 execute format('drop trigger if exists employee_directory_lock on public.%I',t);execute format('create trigger employee_directory_lock before insert or update or delete on public.%I for each statement execute function greenloop_private.ed_lock()',t);
 execute format('drop trigger if exists employee_directory_guard on public.%I',t);execute format('create trigger employee_directory_guard before insert or update or delete on public.%I for each row execute function greenloop_private.ed_guard()',t);
 execute format('drop trigger if exists employee_directory_sync on public.%I',t);execute format('create trigger employee_directory_sync after insert or update on public.%I for each row execute function greenloop_private.ed_sync()',t);
 execute format('drop trigger if exists employee_directory_signal on public.%I',t);execute format('create constraint trigger employee_directory_signal after insert or update or delete on public.%I deferrable initially deferred for each row execute function greenloop_private.signal_workflow_change()',t);
 end loop;end;$$;
create or replace function greenloop_private.ed_matches(p_id uuid,p_name text,p_roster uuid,p_full text)returns boolean language sql immutable set search_path=pg_catalog,public as $$select case when p_id is not null then p_id=p_roster else greenloop_private.ed_key(p_name)=greenloop_private.ed_key(p_full)end;$$;
create or replace function public.get_lab_employee_board_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;n integer;begin
 perform greenloop_private.pf_cap('lab_glass','view');
 select coalesce(jsonb_agg(to_jsonb(q)order by q.full_name),'[]')into result from(select t.id,t.full_name,count(distinct d.id)::integer pending_count,false unassigned from public.technician_roster t left join public.job_work_order_steps s on s.step_status='in_progress'and s.department in ('laboratory','glass')and greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,t.id,t.full_name)left join public.job_work_orders w on w.id=s.work_order_id left join public.jobs j on j.id=w.job_id and j.deleted_at is null and j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')left join public.devices d on d.id=j.device_id and d.deleted_at is null where t.is_active group by t.id,t.full_name)q;
 select count(distinct d.id)::integer into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=w.device_id and d.deleted_at is null where s.step_status='in_progress'and s.department in ('laboratory','glass')and j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and not exists(select 1 from public.technician_roster t where t.is_active and greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,t.id,t.full_name));
 if n>0 then result:=jsonb_build_array(jsonb_build_object('id','00000000-0000-0000-0000-000000000000','full_name','Unassigned','pending_count',n,'unassigned',true))||result;end if;return result;
end;$$;
create or replace function public.assign_lab_employee_v1(p_step_id uuid,p_employee_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare j uuid;t public.technician_roster%rowtype;previous text;begin
 perform greenloop_private.pf_cap('lab_glass','entry');perform pg_advisory_xact_lock(20420261026);j:=greenloop_private.pf_step(p_step_id);select *into t from public.technician_roster where id=p_employee_id and is_active for share;if t.id is null then raise exception 'Choose an active employee.'using errcode='22023';end if;
 select assigned_technician_name into previous from public.job_work_order_steps where id=p_step_id;
 if exists(select 1 from public.job_work_order_steps s join public.technician_roster r on r.is_active and greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,r.id,r.full_name)where s.id=p_step_id)then raise exception 'This phone is already assigned. Refresh the workbench.'using errcode='40001';end if;
 update public.job_work_order_steps set assigned_technician_roster_id=t.id,assigned_technician_name=t.full_name,assigned_at=now()where id=p_step_id;
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)select device_id,j,'lab_employee_assigned','Lab / Glass assigned its pending phone',jsonb_build_object('employee',t.full_name,'previous_employee',previous),auth.uid()from public.jobs where id=j;return jsonb_build_object('employee_id',t.id,'employee_name',t.full_name);
end;$$;

create or replace function greenloop_private.ed_unassigned_rows(p_technician_id uuid)
returns table(
  step_id uuid,
  department public.work_department,
  rework_count integer,
  job_id uuid,
  job_number text,
  imei text,
  supplier_code text,
  supplier_name text,
  model text,
  storage_gb integer,
  color text,
  battery_health integer,
  technician_name text,
  initial_parts jsonb,
  initial_services jsonb,
  lab_part_requests jsonb,
  lab_services jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_active_staff() then
    raise exception 'Active staff access is required.' using errcode = '42501';
  end if;

  return query
  select
    work_step.id,
    work_step.department,
    work_step.rework_count,
    job.id,
    job.job_number,
    device.imei_1::text,
    supplier.supplier_code,
    supplier.company_name,
    device.model,
    device.storage_gb,
    device.color,
    device.battery_health::integer,
    coalesce(nullif(btrim(work_step.assigned_technician_name), ''), technician.full_name),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', requirement.id,
          'name', requirement.part_name,
          'quantity', requirement.quantity_required,
          'status', requirement.status,
          'notes', requirement.notes,
          'part_request_id', requirement.part_request_id
        ) order by requirement.identified_at
      )
      from public.initial_qc_part_requirements as requirement
      where requirement.job_id = job.id
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', finding.id,
          'name', finding.check_item,
          'action', finding.action_required,
          'priority', finding.priority,
          'notes', finding.notes,
          'lab_decision', case
            when service_review.id is null then 'pending_review'
            when service_review.is_required then 'required'
            else 'not_required'
          end,
          'lab_notes', service_review.notes
        ) order by finding.created_at
      )
      from public.initial_qc_findings as finding
      left join public.lab_service_reviews as service_review
        on service_review.work_order_step_id = work_step.id
       and service_review.initial_finding_id = finding.id
      where finding.inspection_id = work_order.initial_qc_inspection_id
        and finding.department in ('laboratory', 'glass', 'frame')
        and public.is_initial_qc_service(finding.check_item)
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', part_request.id,
          'name', part_request.part_name,
          'quantity', part_request.quantity_requested,
          'issued', part_request.quantity_issued,
          'installed', part_request.quantity_installed,
          'returned', part_request.quantity_returned,
          'status', part_request.status,
          'source', part_request.request_source,
          'notes', part_request.notes
        ) order by part_request.requested_at
      )
      from public.job_part_requests as part_request
      where part_request.job_id = job.id
        and part_request.status <> 'cancelled'
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', service_review.id,
          'name', service_review.service_name,
          'source', service_review.source,
          'required', service_review.is_required,
          'notes', service_review.notes,
          'reviewed_at', service_review.reviewed_at
        ) order by service_review.reviewed_at
      )
      from public.lab_service_reviews as service_review
      where service_review.work_order_step_id = work_step.id
        and (
          service_review.source = 'laboratory'
          or public.is_initial_qc_service(service_review.service_name)
        )
    ), '[]'::jsonb)
  from public.job_work_order_steps as work_step
  join public.job_work_orders as work_order
    on work_order.id = work_step.work_order_id
  join public.jobs as job
    on job.id = work_order.job_id
   and job.deleted_at is null
  join public.devices as device
    on device.id = work_order.device_id
   and device.deleted_at is null
  left join public.suppliers as supplier
    on supplier.id = job.supplier_id
  left join public.technician_roster as technician
    on technician.id = p_technician_id
  where work_step.department in ('laboratory', 'glass', 'frame')
    and work_step.step_status = 'in_progress'
    and work_step.department in ('laboratory','glass')
    and job.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
    and not exists(select 1 from public.technician_roster t where t.is_active and greenloop_private.ed_matches(work_step.assigned_technician_roster_id,work_step.assigned_technician_name,t.id,t.full_name))
  order by work_step.created_at, job.received_at;
end;
$$;
create or replace function public.get_lab_employee_rows_v1(p_employee_id uuid default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.pf_cap('lab_glass','view');if p_employee_id is not null then if not exists(select 1 from public.technician_roster where id=p_employee_id and is_active)then raise exception 'Choose an active employee.'using errcode='22023';end if;select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('unassigned',false)),'[]')into result from public.get_lab_technician_rows_v2(p_employee_id)r;
 else select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('technician_name','Unassigned','unassigned',true,'manual_parts',coalesce((select jsonb_agg(jsonb_build_object('name',m.part_name,'quantity',m.quantity))from public.lab_manual_part_installations m where m.work_order_step_id=r.step_id),'[]'))),'[]')into result from greenloop_private.ed_unassigned_rows(null)r;end if;return result;
end;$$;
create or replace function public.get_shared_employees_v1(p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 if p_page is null or p_page not in ('initial_qc','lab_glass','ready_stock','tv_manual_entry')then raise exception 'Choose a valid employee page.'using errcode='22023';end if;perform greenloop_private.pf_cap(p_page,'view');select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'full_name',t.full_name,'damage_id',o.id,'label',o.label)order by t.full_name,t.id),'[]')into result from public.technician_roster t join greenloop_private.employee_links l on l.roster_id=t.id join public.manual_damage_options o on o.id=l.option_id and o.kind='employee'and o.is_active where t.is_active;return result;
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_lab_employee_board_v1','{"page":"lab_glass","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_lab_employee_rows_v1','{"page":"lab_glass","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('assign_lab_employee_v1','{"page":"lab_glass","capability":"entry"}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_shared_employees_v1','{"any":[{"page":"initial_qc","capability":"view","read":true},{"page":"lab_glass","capability":"view","read":true},{"page":"ready_stock","capability":"view","read":true},{"page":"tv_manual_entry","capability":"view","read":true}],"read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_lab_employee_board_v1','get_lab_employee_rows_v1','assign_lab_employee_v1','get_shared_employees_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;for f in select p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'ed_%'loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);end loop;
end;$wrap$;
-- The reviewed employee triggers extend only the managed-choice schema.
update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema()where object_kind='schema'and object_identity='manual_damage_price_schema';
create table if not exists greenloop_private.employee_directory_installation(identity text primary key,hash text not null);
alter table greenloop_private.employee_directory_installation enable row level security;revoke all on greenloop_private.employee_directory_installation from public,anon,authenticated;
insert into greenloop_private.employee_directory_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where(p.pronamespace='public'::regnamespace and p.proname in ('get_lab_employee_board_v1','get_lab_employee_rows_v1','assign_lab_employee_v1','get_shared_employees_v1'))or(p.pronamespace='greenloop_private'::regnamespace and p.proname like 'ed_%')on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_employee_directory_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_badges_version()='20261026-parts-badges-1'
 and(select count(*)=10 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.employee_directory_installation)
 and(select count(*)=8 from pg_trigger where tgrelid in ('public.technician_roster'::regclass,'public.manual_damage_options'::regclass)and tgenabled='O'and((tgname='employee_directory_lock'and tgfoid='greenloop_private.ed_lock()'::regprocedure)or(tgname='employee_directory_guard'and tgfoid='greenloop_private.ed_guard()'::regprocedure)or(tgname='employee_directory_sync'and tgfoid='greenloop_private.ed_sync()'::regprocedure)or(tgname='employee_directory_signal'and tgfoid='greenloop_private.signal_workflow_change()'::regprocedure and tgdeferrable and tginitdeferred)))
 and not exists(select 1 from unnest(array['employee_directory_installation','employee_links','employee_sync_context'])t where has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not exists(select 1 from greenloop_private.employee_directory_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261026-employees-1'end;$$;
revoke all on function public.get_employee_directory_version()from public;grant execute on function public.get_employee_directory_version()to anon,authenticated;
do $$begin if public.get_employee_directory_version()is distinct from '20261026-employees-1'then raise exception 'Employee directory verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_employee_directory_version()as installed_employee_directory_version;
