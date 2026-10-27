-- Reduce Lab / Glass network waterfalls and index common operational lookups.
begin;
do $$begin if public.get_iphone_entry_options_version()is distinct from '20261027-iphone-entry-options-1'then raise exception 'Verified iPhone Entry Options are required.';end if;if to_regprocedure('public.get_workbench_performance_version()')is not null then if public.get_workbench_performance_version()is distinct from '20261027-performance-1'then raise exception 'Existing performance update needs review.';end if;end if;end;$$;
create index if not exists gl_perf_lab_step_active_employee on public.job_work_order_steps(assigned_technician_roster_id,created_at,id) where step_status='in_progress'and department in('laboratory','glass');
create index if not exists gl_perf_lab_step_work_order on public.job_work_order_steps(work_order_id,step_status,department);
create index if not exists gl_perf_job_device_active on public.jobs(device_id,created_at) where deleted_at is null;
create index if not exists gl_perf_work_order_job on public.job_work_orders(job_id,created_at);
create index if not exists gl_perf_initial_parts_job on public.initial_qc_part_requirements(job_id,identified_at);
create index if not exists gl_perf_initial_findings_inspection on public.initial_qc_findings(inspection_id,created_at);
create index if not exists gl_perf_job_parts_job on public.job_part_requests(job_id,requested_at);
create index if not exists gl_perf_lab_services_step on public.lab_service_reviews(work_order_step_id,reviewed_at);
create index if not exists gl_perf_legacy_returns_part on public.lab_part_return_requests(part_request_id,status);
create index if not exists gl_perf_legacy_returns_step on public.lab_part_return_requests(work_order_step_id,status);
create index if not exists gl_perf_parts_returns_issue on greenloop_private.parts_flow_returns(issue_id,status);
create index if not exists gl_perf_device_secondary_active on public.devices(imei_2) where deleted_at is null and imei_2 is not null;
create index if not exists gl_perf_device_number_active on public.devices(lower(device_number)) where deleted_at is null;
create index if not exists gl_perf_device_serial_active on public.devices(lower(serial_number)) where deleted_at is null and serial_number is not null;
create or replace function public.get_lab_workbench_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare employee uuid:=p_employee_id;scan text:=nullif(btrim(p_imei),'');identity jsonb;selected_step uuid;raw jsonb;result jsonb;names boolean;emp_name text;
begin
 perform greenloop_private.pf_cap('lab_glass','view');
 if scan is not null then
  perform greenloop_private.pf_cap('lab_glass','search');
  if scan!~'^[0-9]{15}$'then raise exception 'Enter or scan a valid 15-digit IMEI.'using errcode='22023';end if;
  identity:=public.get_imei_duplicate_stage_v1(scan);
  if identity->>'matched_type'='secondary'then return jsonb_build_object('identity',identity,'rows','[]'::jsonb,'step_id',null);end if;
  select s.id,(select t.id from public.technician_roster t where t.is_active and greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,t.id,t.full_name)order by t.id limit 1)
  into selected_step,employee from public.devices d join public.jobs j on j.device_id=d.id and j.deleted_at is null join public.job_work_orders w on w.job_id=j.id join public.job_work_order_steps s on s.work_order_id=w.id
  where d.imei_1=scan and d.deleted_at is null and s.department in('laboratory','glass')and s.step_status='in_progress'and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')order by s.created_at desc,s.id desc limit 1;
  if selected_step is null then return jsonb_build_object('identity',identity,'rows','[]'::jsonb,'step_id',null);end if;
 end if;
 raw:=public.get_lab_employee_rows_v1(employee);
 names:=coalesce(public.get_my_partner_name_access(),false);
 with selected as materialized(select value row,ordinality seq from jsonb_array_elements(raw)with ordinality where selected_step is null or(value->>'step_id')::uuid=selected_step)
 select coalesce(jsonb_agg(row||jsonb_build_object(
 'supplier_name',case when names then row->'supplier_name'else 'null'::jsonb end,
 'device_number',d.device_number,'serial_number',d.serial_number,'job_number',j.job_number,
 'planned_quantity',b.planned_quantity,'invoice_number',b.invoice_number,'batch_number',b.batch_number,
 'pf_plan',greenloop_private.pp_plan((row->>'step_id')::uuid),
 'pending_part_returns',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'part_request_id',x.part_request_id,'status',x.status))from public.lab_part_return_requests x where x.work_order_step_id=(row->>'step_id')::uuid and x.status='pending'),'[]'::jsonb))order by seq),'[]'::jsonb)
 into result from selected join public.jobs j on j.id=(row->>'job_id')::uuid and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null left join public.receiving_batches b on b.id=j.receiving_batch_id;
 select full_name into emp_name from public.technician_roster where id=employee and is_active;
 return jsonb_build_object('employee_id',coalesce(employee,'00000000-0000-0000-0000-000000000000'::uuid),'employee_name',coalesce(emp_name,'Unassigned'),'unassigned',employee is null,'step_id',selected_step,'identity',identity,'rows',result);
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_lab_workbench_v1','{"page":"lab_glass","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.capability_rpc_rules set rule=rule||'{"read":true}'::jsonb where rpc_name in('get_parts_flow_counts_v1','get_parts_only_counts_v1');
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_lab_workbench_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.performance_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.performance_installation enable row level security;revoke all on greenloop_private.performance_installation from public,anon,authenticated;
insert into greenloop_private.performance_installation select 'function',p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_lab_workbench_v1'on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.performance_installation select 'index',c.oid::regclass::text,md5(pg_get_indexdef(c.oid))from pg_class c where c.relkind='i'and c.relname like 'gl_perf_%'on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_workbench_performance_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_iphone_entry_options_version()='20261027-iphone-entry-options-1'
 and(select count(*)=15 and bool_and(coalesce(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else md5(pg_get_indexdef(to_regclass(identity)))end,false))from greenloop_private.performance_installation)
 and not has_table_privilege('authenticated','greenloop_private.performance_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.performance_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261027-performance-1'end;$$;
revoke all on function public.get_workbench_performance_version()from public;grant execute on function public.get_workbench_performance_version()to anon,authenticated;
do $$begin if public.get_workbench_performance_version()is distinct from '20261027-performance-1'then raise exception 'Performance verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_workbench_performance_version()as installed_performance_version;
