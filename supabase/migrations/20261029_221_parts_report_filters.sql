-- Read-only parts report snapshot for combined per-column dropdown filters.
-- Opaque primary IDs let the browser count a phone once across multiple parts.
begin;
do $$begin if public.get_parts_picking_version()is distinct from '20261029-parts-picking-1'then raise exception 'Verified Parts Picking update is required.';end if;end;$$;
create or replace function public.get_parts_picking_report_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.pf_cap('parts','view');perform greenloop_private.pf_cap('parts','technician_report');
 with source as materialized(select *from greenloop_private.technician_parts_pending()),employees as materialized(
 select tr.id::text key,tr.full_name name from public.technician_roster tr where tr.is_active
 union select technician_key,technician_name from source
 union select 'unassigned','Unassigned'
 ),groups as(
 select technician_key,technician_name,model,color,part_name,sum(quantity)::bigint quantity,count(distinct device_id)::integer phones,jsonb_agg(distinct device_id order by device_id)phone_keys from source group by technician_key,technician_name,model,color,part_name
 )select jsonb_build_object('generated_at',statement_timestamp(),'technician_key','','technician_name','All Technicians',
 'technicians',coalesce((select jsonb_agg(jsonb_build_object('key',e.key,'name',e.name,'phones',(select count(distinct device_id)from source where technician_key=e.key))order by lower(e.name),e.key)from employees e),'[]'),
 'rows',coalesce((select jsonb_agg(to_jsonb(g)order by lower(technician_name),lower(model),lower(part_name),lower(color),technician_key)from groups g),'[]'),
 'phones',(select count(distinct device_id)from source),'quantity',coalesce((select sum(quantity)from source),0),'lines',(select count(*)from groups),'details','[]'::jsonb)into result;
 return result;
end;$$;
create or replace function public.export_parts_picking_report_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('parts','view');perform greenloop_private.pf_cap('parts','technician_report');perform greenloop_private.pf_cap('parts','technician_download');return public.get_parts_picking_report_v1();
end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_parts_picking_report_v1','{"all":[{"page":"parts","capability":"view"},{"page":"parts","capability":"technician_report"}],"read":true}'),
 ('export_parts_picking_report_v1','{"all":[{"page":"parts","capability":"view"},{"page":"parts","capability":"technician_report"},{"page":"parts","capability":"technician_download"}],"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_parts_picking_report_v1','export_parts_picking_report_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;

create table if not exists greenloop_private.parts_report_filters_installation(identity text primary key,hash text not null);
alter table greenloop_private.parts_report_filters_installation enable row level security;revoke all on greenloop_private.parts_report_filters_installation from public,anon,authenticated;
create or replace function public.get_parts_report_filters_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_picking_version()='20261029-parts-picking-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_report_filters_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.parts_report_filters_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.parts_report_filters_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.parts_report_filters_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.parts_report_filters_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261029-parts-report-filters-1'end;$$;
revoke all on function public.get_parts_report_filters_version()from public;grant execute on function public.get_parts_report_filters_version()to anon,authenticated;
insert into greenloop_private.parts_report_filters_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid='public.get_parts_report_filters_version()'::regprocedure or(p.pronamespace='public'::regnamespace and p.proname in('get_parts_picking_report_v1','export_parts_picking_report_v1'))or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_parts_picking_report_v1()'::regprocedure,'public.export_parts_picking_report_v1()'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_parts_report_filters_version()is distinct from '20261029-parts-report-filters-1'then raise exception 'Parts Report Filters verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_parts_report_filters_version()as installed_parts_report_filters_version;
