-- Most-used Parts/Services first. Saved phones count once per choice; quantities do not inflate popularity.
begin;
do $$begin if public.get_qc_dropdowns_version()is distinct from '20261028-qc-dropdowns-1'then raise exception 'Verified QC Dropdowns update is required.';end if;if to_regprocedure('public.get_work_option_usage_version()')is not null then if public.get_work_option_usage_version()is distinct from '20261028-work-option-usage-1'then raise exception 'Existing work option ranking needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.qc_work_usage_cache(singleton boolean primary key default true check(singleton),built_at timestamptz not null,counts jsonb not null);
alter table greenloop_private.qc_work_usage_cache enable row level security;revoke all on greenloop_private.qc_work_usage_cache from public,anon,authenticated;
create or replace function greenloop_private.qc_work_usage_v1()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare cached jsonb;built timestamptz;begin
 select counts,built_at into cached,built from greenloop_private.qc_work_usage_cache where singleton;
 if built>clock_timestamp()-interval '15 seconds'then return cached;end if;
 if not pg_try_advisory_xact_lock(hashtextextended('greenloop:qc-work-usage',0))then
  if cached is not null then return cached;end if;
  perform pg_advisory_xact_lock(hashtextextended('greenloop:qc-work-usage',0));
 end if;
 select counts,built_at into cached,built from greenloop_private.qc_work_usage_cache where singleton;
 if built>clock_timestamp()-interval '15 seconds'then return cached;end if;
 with uses(kind,name,job_id)as(
  select 'part',part_name,job_id from public.initial_qc_part_requirements where quantity_required>0 and status not in('not_required','unused_returned','cancelled')
  union all select 'part',part_name,job_id from public.job_part_requests where quantity_requested>0 and status::text<>'cancelled'
  union all select 'part',part_name,job_id from public.lab_manual_part_installations where quantity>0
  union all select 'service',f.check_item,q.job_id from public.initial_qc_findings f join public.initial_qc_inspections q on q.id=f.inspection_id where public.is_initial_qc_service(f.check_item)and not exists(select 1 from public.lab_service_reviews v where v.job_id=q.job_id and v.initial_finding_id=f.id and not v.is_required)
  union all select 'service',service_name,job_id from public.lab_service_reviews where is_required
  union all select 'service',n,job_id from greenloop_private.lab_only_services cross join lateral jsonb_array_elements_text(names)n
 ), distinct_phones as(
  select distinct u.kind,lower(regexp_replace(btrim(u.name),'\s+',' ','g'))name_key,j.device_id from uses u join public.jobs j on j.id=u.job_id join public.devices d on d.id=j.device_id where j.deleted_at is null and d.deleted_at is null and length(btrim(u.name))>0
 ), totals as(select kind,name_key,count(*)n from distinct_phones group by kind,name_key)
 select jsonb_build_object('part',coalesce((select jsonb_object_agg(name_key,n)from totals where kind='part'),'{}'),'service',coalesce((select jsonb_object_agg(name_key,n)from totals where kind='service'),'{}'))into cached;
 insert into greenloop_private.qc_work_usage_cache values(true,clock_timestamp(),cached)on conflict(singleton)do update set counts=excluded.counts,built_at=excluded.built_at;return cached;
end;$$;
create or replace function greenloop_private.rank_work_options(p_options jsonb,p_counts jsonb)returns jsonb language sql immutable set search_path=pg_catalog,public as $$select p_options||jsonb_build_object(
 'parts',coalesce((select jsonb_agg(o||jsonb_build_object('usage_count',coalesce((p_counts->'part'->>lower(regexp_replace(btrim(o->>'name'),'\s+',' ','g')))::bigint,0))order by coalesce((p_counts->'part'->>lower(regexp_replace(btrim(o->>'name'),'\s+',' ','g')))::bigint,0)desc,lower(o->>'name')collate "C",o->>'name',o->>'id')from jsonb_array_elements(p_options->'parts')o),'[]'),
 'services',coalesce((select jsonb_agg(o||jsonb_build_object('usage_count',coalesce((p_counts->'service'->>lower(regexp_replace(btrim(o->>'name'),'\s+',' ','g')))::bigint,0))order by coalesce((p_counts->'service'->>lower(regexp_replace(btrim(o->>'name'),'\s+',' ','g')))::bigint,0)desc,lower(o->>'name')collate "C",o->>'name',o->>'id')from jsonb_array_elements(p_options->'services')o),'[]'));
$$;
revoke all on function greenloop_private.qc_work_usage_v1(),greenloop_private.rank_work_options(jsonb,jsonb)from public,anon,authenticated;
create or replace function public.get_ranked_qc_dropdowns_v1()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare options jsonb;begin options:=public.get_qc_dropdowns_v1();return greenloop_private.rank_work_options(options,greenloop_private.qc_work_usage_v1());end;$$;
create or replace function public.get_ranked_lab_workbench_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare result jsonb;begin result:=public.get_lab_workbench_options_v1(p_employee_id,p_imei);return result||jsonb_build_object('work_options',greenloop_private.rank_work_options(result->'work_options',greenloop_private.qc_work_usage_v1()));end;$$;
-- These are reads of business data. Internal cache refreshes must not trigger UI workflow refresh loops.
insert into greenloop_private.capability_rpc_rules values('get_ranked_qc_dropdowns_v1','{"page":"initial_qc","capability":"view","read":true}'),('get_ranked_lab_workbench_v1','{"page":"lab_glass","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_ranked_qc_dropdowns_v1','get_ranked_lab_workbench_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;

-- Seed during installation so normal page reads never need a first-build wait.
do $$begin perform greenloop_private.qc_work_usage_v1();end;$$;
create table if not exists greenloop_private.work_option_usage_installation(identity text primary key,hash text not null);
alter table greenloop_private.work_option_usage_installation enable row level security;revoke all on greenloop_private.work_option_usage_installation from public,anon,authenticated;
insert into greenloop_private.work_option_usage_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where(p.pronamespace='public'::regnamespace and p.proname in('get_ranked_qc_dropdowns_v1','get_ranked_lab_workbench_v1'))or(p.pronamespace='greenloop_private'::regnamespace and p.proname in('qc_work_usage_v1','rank_work_options'))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_work_option_usage_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_qc_dropdowns_version()='20261028-qc-dropdowns-1'
 and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.work_option_usage_installation)
 and not exists(select 1 from unnest(array['qc_work_usage_cache','work_option_usage_installation'])t where not exists(select 1 from pg_class c where c.oid=to_regclass('greenloop_private.'||t)and c.relrowsecurity)or has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not has_function_privilege('authenticated','greenloop_private.qc_work_usage_v1()','EXECUTE')and not has_function_privilege('anon','greenloop_private.qc_work_usage_v1()','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rank_work_options(jsonb,jsonb)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rank_work_options(jsonb,jsonb)','EXECUTE')then '20261028-work-option-usage-1'end;$$;
revoke all on function public.get_work_option_usage_version()from public;grant execute on function public.get_work_option_usage_version()to anon,authenticated;
do $$begin if public.get_work_option_usage_version()is distinct from '20261028-work-option-usage-1'then raise exception 'Work option ranking verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_work_option_usage_version()as installed_work_option_usage_version;
