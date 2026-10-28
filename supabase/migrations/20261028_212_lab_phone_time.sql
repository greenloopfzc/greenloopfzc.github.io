-- Read-only per-phone Lab/Glass elapsed-time metadata on the existing combined workbench read.
begin;
do $$begin if public.get_receipt_return_count_version()is distinct from '20261028-receipt-return-count-1'then raise exception 'Verified Receipt Return Count update is required.';end if;if to_regprocedure('public.get_lab_phone_time_version()')is not null then if public.get_lab_phone_time_version()is distinct from '20261028-lab-phone-time-1'then raise exception 'Existing Lab Phone Time update needs review.';end if;end if;end;$$;
create index if not exists gl_lab_phone_time_movements on public.device_location_history(device_id,job_id,moved_at);
create or replace function public.get_lab_workbench_timing_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;timed_rows jsonb;
begin
 perform greenloop_private.pf_cap('lab_glass','view');
 -- Native API retains employee, IMEI2, search, pending-phone and partner-name boundaries.
 result:=public.get_lab_workbench_v1(p_employee_id,p_imei);
 select coalesce(jsonb_agg(r.value||jsonb_build_object('lab_entered_at',stay.entered_at,'technician_assigned_at',s.assigned_at,'line_created_at',s.created_at)order by r.ordinality),'[]'::jsonb)into timed_rows
 from jsonb_array_elements(result->'rows')with ordinality r
 join public.job_work_order_steps s on s.id=(r.value->>'step_id')::uuid
 join public.jobs j on j.id=(r.value->>'job_id')::uuid
 left join lateral(select t.entered_at from greenloop_private.lab_stays_v1(j.device_id)t where t.job_id=j.id and t.ongoing order by t.entered_at desc limit 1)stay on true;
 return result||jsonb_build_object('rows',timed_rows,'server_now',now());
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_lab_workbench_timing_v1','{"page":"lab_glass","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_lab_workbench_timing_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.lab_phone_time_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.lab_phone_time_installation enable row level security;revoke all on greenloop_private.lab_phone_time_installation from public,anon,authenticated;
insert into greenloop_private.lab_phone_time_installation select 'function',p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_lab_workbench_timing_v1'on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.lab_phone_time_installation values('index','public.gl_lab_phone_time_movements',md5(pg_get_indexdef('public.gl_lab_phone_time_movements'::regclass)))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_lab_phone_time_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_receipt_return_count_version()='20261028-receipt-return-count-1'
 and(select count(*)=2 and bool_and(coalesce(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else md5(pg_get_indexdef(to_regclass(identity)))end,false))from greenloop_private.lab_phone_time_installation)
 and not has_table_privilege('authenticated','greenloop_private.lab_phone_time_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.lab_phone_time_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261028-lab-phone-time-1'end;$$;
revoke all on function public.get_lab_phone_time_version()from public;grant execute on function public.get_lab_phone_time_version()to anon,authenticated;
do $$begin if public.get_lab_phone_time_version()is distinct from '20261028-lab-phone-time-1'then raise exception 'Lab Phone Time verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_lab_phone_time_version()as installed_lab_phone_time_version;
