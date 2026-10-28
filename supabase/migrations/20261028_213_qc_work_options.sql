-- Authorized shared Initial QC / Lab part and service names. No operational stock is changed.
begin;
do $$begin if public.get_lab_phone_time_version()is distinct from '20261028-lab-phone-time-1'then raise exception 'Verified Lab Phone Time update is required.';end if;if to_regprocedure('public.get_qc_work_options_version()')is not null then if public.get_qc_work_options_version()is distinct from '20261028-qc-work-options-1'then raise exception 'Existing QC Work Options update needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.qc_service_options(id uuid primary key default gen_random_uuid(),name text not null check(length(name)between 1 and 120),initial_qc boolean not null default true,created_by uuid,created_at timestamptz not null default now());
create unique index if not exists qc_service_options_name on greenloop_private.qc_service_options(lower(regexp_replace(btrim(name),'\s+',' ','g')));
create table if not exists greenloop_private.qc_work_option_audit(id uuid primary key default gen_random_uuid(),kind text not null check(kind in('part','service')),name text not null,action text not null,actor uuid not null,created_at timestamptz not null default now());
alter table greenloop_private.qc_service_options enable row level security;alter table greenloop_private.qc_work_option_audit enable row level security;
revoke all on greenloop_private.qc_service_options,greenloop_private.qc_work_option_audit from public,anon,authenticated;
insert into greenloop_private.qc_service_options(name,initial_qc)select n,n in('Polish','Cleaning','Software','Testing')from unnest(array['Polish','Cleaning','Software','Testing','Face ID calibration','Camera calibration','Housing repair','Glass work','Frame work'])n on conflict do nothing;
insert into public.entry_options(option_group,option_value,is_active)select 'part_name',n,true from unnest(array['Case','Glass','Touch panel','NFC flex','Vibrator','Speaker','Camera','Face ID flex','LCD display','Battery','Charging flex'])n where not exists(select 1 from public.entry_options e where e.option_group='part_name'and lower(regexp_replace(btrim(e.option_value),'\s+',' ','g'))=lower(n));
-- Approved custom services must survive Initial QC findings and Lab service filtering.
create or replace function public.is_initial_qc_service(p_name text)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$select lower(regexp_replace(btrim(coalesce(p_name,'')),'\s+',' ','g'))in('polish','cleaning','software','testing')or exists(select 1 from greenloop_private.qc_service_options s where s.initial_qc and lower(regexp_replace(btrim(s.name),'\s+',' ','g'))=lower(regexp_replace(btrim(coalesce(p_name,'')),'\s+',' ','g')));$$;
create or replace function public.get_qc_work_options_v1(p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 if p_page is null or p_page not in('initial_qc','lab_glass')then raise exception 'Choose an authorized work page.'using errcode='42501';end if;perform greenloop_private.pf_cap(p_page,'view');
 select jsonb_build_object('parts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',option_value)order by lower(option_value),id)from(select distinct on(lower(regexp_replace(btrim(e.option_value),'\s+',' ','g')))e.id,e.option_value from public.entry_options e where e.option_group='part_name'and e.is_active order by lower(regexp_replace(btrim(e.option_value),'\s+',' ','g')),e.created_at,e.id)p),'[]'),
 'services',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'initial_qc',s.initial_qc)order by lower(s.name),s.id)from greenloop_private.qc_service_options s where p_page='lab_glass'or s.initial_qc),'[]'))into result;return result;
end;$$;
create or replace function public.save_qc_work_option_v1(p_kind text,p_name text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare n text;key text;saved uuid;existing text;enabled boolean;action text;begin
 perform greenloop_private.pf_cap('initial_qc','manage_options');
 if p_kind is null or p_kind not in('part','service')or p_name is null or p_name~'[[:cntrl:]]'then raise exception 'Choose Part or Service and enter a valid name.'using errcode='22023';end if;
 n:=regexp_replace(btrim(p_name),'\s+',' ','g');if length(n)not between 1 and 120 then raise exception 'Enter a name from 1 to 120 characters.'using errcode='22023';end if;key:=lower(n);perform pg_advisory_xact_lock(hashtextextended('qc-work-option:'||key,0));
 if p_kind='part'then
  if exists(select 1 from greenloop_private.qc_service_options where lower(regexp_replace(btrim(name),'\s+',' ','g'))=key)then raise exception 'This name is already a service. Use a distinct part name.'using errcode='22023';end if;
  select id,option_value,is_active into saved,existing,enabled from public.entry_options where option_group='part_name'and lower(regexp_replace(btrim(option_value),'\s+',' ','g'))=key order by is_active desc,created_at,id limit 1 for update;
  if saved is null then insert into public.entry_options(option_group,option_value,is_active,created_by)values('part_name',n,true,auth.uid())returning id,option_value into saved,n;action:='created';
  elsif not enabled then update public.entry_options set is_active=true where id=saved;n:=existing;action:='reactivated';else n:=existing;end if;
 else
  if exists(select 1 from public.entry_options where option_group='part_name'and lower(regexp_replace(btrim(option_value),'\s+',' ','g'))=key)then raise exception 'This name is already a part. Use a distinct service name.'using errcode='22023';end if;
  select id,name,initial_qc into saved,existing,enabled from greenloop_private.qc_service_options where lower(regexp_replace(btrim(name),'\s+',' ','g'))=key for update;
  if saved is null then insert into greenloop_private.qc_service_options(name,initial_qc,created_by)values(n,true,auth.uid())returning id,name into saved,n;action:='created';
  elsif not enabled then update greenloop_private.qc_service_options set initial_qc=true where id=saved;n:=existing;action:='enabled_for_qc';else n:=existing;end if;
 end if;
 if action is not null then insert into greenloop_private.qc_work_option_audit(kind,name,action,actor)values(p_kind,n,action,auth.uid());end if;
 return jsonb_build_object('id',saved,'kind',p_kind,'name',n,'changed',action is not null,'action',action);
end;$$;
create or replace function public.get_lab_workbench_options_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.pf_cap('lab_glass','view');return public.get_lab_workbench_timing_v1(p_employee_id,p_imei)||jsonb_build_object('work_options',public.get_qc_work_options_v1('lab_glass'));end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_qc_work_options_v1','{"dynamic":"filter_source","parameter":"p_page","initial_qc":{"page":"initial_qc","capability":"view","read":true},"lab_glass":{"page":"lab_glass","capability":"view","read":true}}'),
 ('save_qc_work_option_v1','{"page":"initial_qc","capability":"manage_options"}'),
 ('get_lab_workbench_options_v1','{"page":"lab_glass","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_qc_work_options_v1','save_qc_work_option_v1','get_lab_workbench_options_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.qc_work_options_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_work_options_installation enable row level security;revoke all on greenloop_private.qc_work_options_installation from public,anon,authenticated;
insert into greenloop_private.qc_work_options_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_qc_work_options_v1','save_qc_work_option_v1','get_lab_workbench_options_v1','is_initial_qc_service')on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_qc_work_options_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_lab_phone_time_version()='20261028-lab-phone-time-1'
 and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_work_options_installation)
 and not exists(select 1 from unnest(array['qc_service_options','qc_work_option_audit','qc_work_options_installation'])t where not exists(select 1 from pg_class c where c.oid=to_regclass('greenloop_private.'||t)and c.relrowsecurity)or has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))then '20261028-qc-work-options-1'end;$$;
revoke all on function public.get_qc_work_options_version()from public;grant execute on function public.get_qc_work_options_version()to anon,authenticated;
do $$begin if public.get_qc_work_options_version()is distinct from '20261028-qc-work-options-1'then raise exception 'QC Work Options verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_work_options_version()as installed_qc_work_options_version;
