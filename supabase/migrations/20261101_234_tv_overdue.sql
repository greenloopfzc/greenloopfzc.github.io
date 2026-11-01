-- Read-only overdue Lab cards on the existing TV wall, with account-specific rotation.
begin;
do $$begin if public.get_b_dept_report_version()is distinct from '20261101-b-dept-report-1'then raise exception 'Install the verified B-DEPT Report update first.';end if;
 if to_regprocedure('public.get_tv_overdue_version()')is not null then if public.get_tv_overdue_version()is distinct from '20261101-tv-overdue-1'then raise exception 'Existing TV overdue installation needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.tv_rotation_settings(user_id uuid primary key references public.user_profiles(id)on delete cascade,show_damage boolean not null default true,show_overdue boolean not null default false,damage_seconds integer not null default 10 check(damage_seconds between 5 and 3600),pending_seconds integer not null default 10 check(pending_seconds between 5 and 3600),overdue_days integer not null default 2 check(overdue_days between 1 and 365),damage_parts boolean not null default true,damage_original boolean not null default true,damage_copy boolean not null default true,revision bigint not null default 1,updated_at timestamptz not null default now(),updated_by uuid,check(show_damage or show_overdue));
create table if not exists greenloop_private.tv_rotation_audit(id bigint generated always as identity primary key,user_id uuid not null,changed_by uuid not null,changed_at timestamptz not null default now(),before_settings jsonb not null,after_settings jsonb not null);
do $$declare t text;begin foreach t in array array['tv_rotation_settings','tv_rotation_audit']loop execute format('alter table greenloop_private.%I enable row level security',t);execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);end loop;end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='damage_report'and capabilities @> '[{"key":"overdue_pending"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"overdue_pending","label":"TV: overdue Lab cards and phone details","write":false}]'where page_key='damage_report';
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create or replace function greenloop_private.tvr_settings(p_user uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('show_damage',coalesce(s.show_damage,true),'show_overdue',coalesce(s.show_overdue,false),'damage_seconds',coalesce(s.damage_seconds,10),'pending_seconds',coalesce(s.pending_seconds,10),'overdue_days',coalesce(s.overdue_days,2),'damage_parts',coalesce(s.damage_parts,d.show_parts,true),'damage_original',coalesce(s.damage_original,d.show_original,true),'damage_copy',coalesce(s.damage_copy,d.show_copy,true),'revision',coalesce(s.revision,0)::text,'access_revision',coalesce(d.revision,0)::text)
 from(select p_user id)x left join greenloop_private.tv_rotation_settings s on s.user_id=x.id left join greenloop_private.damage_tv_settings d on d.user_id=x.id;
$$;
create or replace function greenloop_private.tvr_wall_access(p_overdue boolean)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if not coalesce(public.has_page_capability_v1('damage_report','view'),false)then raise exception 'TV display access required.'using errcode='42501';end if;
 if p_overdue then
  if not coalesce(public.has_page_capability_v1('damage_report','overdue_pending'),false)or not(greenloop_private.tvr_settings(auth.uid())->>'show_overdue')::boolean then raise exception 'This TV view is no longer enabled. Refresh display settings.'using errcode='22023';end if;
 elsif not(greenloop_private.tvr_settings(auth.uid())->>'show_damage')::boolean then raise exception 'This TV view is no longer enabled. Refresh display settings.'using errcode='22023';end if;
end;$$;
create or replace function public.get_my_tv_rotation_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare s jsonb;begin
 perform greenloop_private.require_office_network();if not coalesce(public.has_page_capability_v1('damage_report','view'),false)then raise exception 'TV display access required.'using errcode='42501';end if;
 s:=greenloop_private.tvr_settings(auth.uid());return s||jsonb_build_object('show_overdue',(s->>'show_overdue')::boolean and coalesce(public.has_page_capability_v1('damage_report','overdue_pending'),false));
end;$$;
create or replace function public.get_user_tv_rotation_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('user_access','view');return(select coalesce(jsonb_agg(greenloop_private.tvr_settings(u.id)||jsonb_build_object('user_id',u.id)order by u.id),'[]')from public.user_profiles u);
end;$$;
create or replace function public.save_user_access_tv_rotation_v1(
 p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,
 p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text,p_capabilities jsonb,p_employee_keys jsonb,p_network_mode text,p_network_revision text,p_rotation jsonb,p_rotation_revision text
)returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare old_settings jsonb;damage boolean;overdue boolean;ds integer;ps integer;days integer;caps jsonb;begin
 perform greenloop_private.pf_cap('user_access','manage_access');
 if p_user_id is null or not exists(select 1 from public.user_profiles where id=p_user_id)then raise exception 'Account not found.'using errcode='22023';end if;
 if jsonb_typeof(p_rotation)is distinct from 'object'or not(p_rotation?&array['show_damage','show_overdue','damage_seconds','pending_seconds','overdue_days'])or exists(select 1 from jsonb_object_keys(p_rotation)k where k not in('show_damage','show_overdue','damage_seconds','pending_seconds','overdue_days'))or jsonb_typeof(p_rotation->'show_damage')<>'boolean'or jsonb_typeof(p_rotation->'show_overdue')<>'boolean'or exists(select 1 from unnest(array['damage_seconds','pending_seconds','overdue_days'])k where jsonb_typeof(p_rotation->k)<>'number'or(p_rotation->>k)!~'^[0-9]{1,4}$')then raise exception 'Choose valid TV windows, whole days and switching seconds.'using errcode='22023';end if;
 damage:=(p_rotation->>'show_damage')::boolean;overdue:=(p_rotation->>'show_overdue')::boolean;ds:=(p_rotation->>'damage_seconds')::integer;ps:=(p_rotation->>'pending_seconds')::integer;days:=(p_rotation->>'overdue_days')::integer;
 if not(damage or overdue)or ds not between 5 and 3600 or ps not between 5 and 3600 or days not between 1 and 365 then raise exception 'Enable at least one TV window. Seconds: 5-3600. Whole days: 1-365.'using errcode='22023';end if;
 if damage and p_tv_only and not coalesce(p_show_parts or p_show_original or p_show_copy,false)then raise exception 'Choose at least one damage display option.'using errcode='22023';end if;
 if overdue and not coalesce((p_capabilities->'damage_report')?'overdue_pending',false)then raise exception 'Enable overdue TV phone-details permission for this account.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('tv-rotation:'||p_user_id::text,0));old_settings:=greenloop_private.tvr_settings(p_user_id);
 if p_rotation_revision is distinct from old_settings->>'revision'then raise exception 'TV rotation settings changed. Refresh the account before saving.'using errcode='40001';end if;
 insert into greenloop_private.tv_rotation_settings(user_id,show_damage,show_overdue,damage_seconds,pending_seconds,overdue_days,damage_parts,damage_original,damage_copy,updated_by)values(p_user_id,damage,overdue,ds,ps,days,p_show_parts,p_show_original,p_show_copy,auth.uid())on conflict(user_id)do update set show_damage=excluded.show_damage,show_overdue=excluded.show_overdue,damage_seconds=excluded.damage_seconds,pending_seconds=excluded.pending_seconds,overdue_days=excluded.overdue_days,damage_parts=excluded.damage_parts,damage_original=excluded.damage_original,damage_copy=excluded.damage_copy,revision=tv_rotation_settings.revision+1,updated_at=now(),updated_by=auth.uid();
 -- Preserve the legacy table's visible-field constraint without granting a damage field.
 -- For pending-only accounts its compatibility flag is masked by the exact capabilities below;
 -- all three damage TV endpoints are separately denied by tvr_wall_access(false).
 perform public.save_user_access_office_v1(p_user_id,p_full_name,p_login_username,p_is_active,p_page_permissions,p_partner_names_access,p_tv_only,p_show_parts or(p_tv_only and not damage and not(p_show_original or p_show_copy)),p_show_original,p_show_copy,p_expected_revision,p_capabilities,p_employee_keys,p_network_mode,p_network_revision);
 select capabilities into caps from greenloop_private.user_page_capabilities where user_id=p_user_id;
 caps:=jsonb_set(caps,'{damage_report}',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct v from jsonb_array_elements_text(coalesce(caps->'damage_report','[]'))e(v)where v<>'overdue_pending'union select 'overdue_pending'where overdue)x));
 if p_tv_only then caps:=jsonb_set(caps,'{damage_report}',to_jsonb(array_remove(array['view',case when p_show_parts then 'parts_details'end,case when p_show_original then 'original_prices'end,case when p_show_copy then 'copy_prices'end,case when p_show_original or p_show_copy then 'payable'end,case when overdue then 'overdue_pending'end],null)));end if;
 update greenloop_private.user_page_capabilities set capabilities=caps,updated_by=auth.uid(),updated_at=now()where user_id=p_user_id;
 insert into greenloop_private.tv_rotation_audit(user_id,changed_by,before_settings,after_settings)values(p_user_id,auth.uid(),old_settings,greenloop_private.tvr_settings(p_user_id));return true;
end;$$;
-- Gate damage TV endpoints as well as the visible window; legacy validation stays intact.
do $patch$declare f regprocedure;ddl text;needle text;begin
 for f in select to_regprocedure(r.implementation)from greenloop_private.office_routines r join pg_proc p on p.oid=to_regprocedure(r.identity)where p.proname in('get_damage_tv_cards_v1','get_damage_tv_employee_v1','get_damage_tv_details_v1')loop
  ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));if strpos(ddl,'greenloop-tv-overdue-234')=0 then
   if strpos(ddl,'begin')=0 then raise exception 'Reviewed damage TV reader differs.';end if;
   execute replace(ddl,'begin',E'begin\n -- greenloop-tv-overdue-234\n perform greenloop_private.tvr_wall_access(false);');
  end if;
 end loop;
end;$patch$;
create or replace function greenloop_private.tvr_rows()returns table(employee_key text,employee_name text,device_id uuid,job_id uuid,imei text,model text,storage_gb integer,color text,battery_health integer,supplier_code text,department text,entered_at timestamptz,elapsed_seconds numeric)language sql stable security definer set search_path=pg_catalog,public as $$
 select distinct on(st.device_id)coalesce(l.option_id::text,'legacy:'||greenloop_private.ed_key(coalesce(t.full_name,s.assigned_technician_name))),upper(btrim(coalesce(t.full_name,s.assigned_technician_name))),d.id,j.id,d.imei_1,d.model,d.storage_gb,d.color,d.battery_health::integer,sp.supplier_code,
 case when j.current_status in('glass_pending','glass_in_progress')then 'Glass'else 'Laboratory'end,st.entered_at,st.elapsed_seconds
 from greenloop_private.lab_stays_v1(null)st join public.jobs j on j.id=st.job_id join public.devices d on d.id=st.device_id
 join lateral(select step.*from public.job_work_orders w join public.job_work_order_steps step on step.work_order_id=w.id where w.job_id=j.id and step.department=case when j.current_status in('glass_pending','glass_in_progress')then 'glass'::public.work_department else 'laboratory'::public.work_department end and step.step_status in('pending','in_progress')and(step.assigned_technician_roster_id is not null or nullif(btrim(step.assigned_technician_name),'')is not null)order by(step.step_status='in_progress')desc,step.assigned_at desc nulls last,step.created_at desc,step.id limit 1)s on true
 left join lateral(select r.*from public.technician_roster r where greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,r.id,r.full_name)order by r.is_active desc,r.created_at,r.id limit 1)t on true
 left join greenloop_private.employee_links l on l.roster_id=t.id left join public.suppliers sp on sp.id=j.supplier_id
 where st.ongoing and st.elapsed_seconds>((greenloop_private.tvr_settings(auth.uid())->>'overdue_days')::integer*86400)
 and nullif(btrim(coalesce(t.full_name,s.assigned_technician_name)),'')is not null
 and coalesce((select e.employee_keys is null or coalesce(coalesce(l.option_id::text,'legacy:'||greenloop_private.ed_key(coalesce(t.full_name,s.assigned_technician_name)))=any(e.employee_keys),false)from greenloop_private.damage_tv_employees e where e.user_id=auth.uid()),true)
 order by st.device_id,st.entered_at desc,st.job_id;
$$;
create or replace function public.get_tv_overdue_cards_v1(p_offset integer default 0,p_limit integer default 100)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r jsonb;begin
 perform greenloop_private.tvr_wall_access(true);if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Choose a valid employee page.'using errcode='22023';end if;
 with phones as materialized(select *from greenloop_private.tvr_rows()),employees as materialized(select employee_key,min(employee_name)employee_name,count(*)phone_count,max(elapsed_seconds)oldest_seconds from phones group by employee_key),page as(select *from employees order by oldest_seconds desc,employee_name,employee_key offset p_offset limit p_limit)
 select jsonb_build_object('settings',public.get_my_tv_rotation_v1(),'server_now',now(),'employee_count',(select count(*)from employees),'phone_count',(select count(*)from phones),'offset',p_offset,'has_more',p_offset+p_limit<(select count(*)from employees),'employees',coalesce((select jsonb_agg(to_jsonb(p)order by p.oldest_seconds desc,p.employee_name,p.employee_key)from page p),'[]'))into r;return r;
end;$$;
create or replace function public.get_tv_overdue_phones_v1(p_employee_key text,p_offset integer default 0,p_limit integer default 20)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r jsonb;begin
 perform greenloop_private.tvr_wall_access(true);if p_employee_key is null or length(p_employee_key)not between 1 and 200 or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Choose a valid employee phone page.'using errcode='22023';end if;
 with q as materialized(select *from greenloop_private.tvr_rows()where employee_key=p_employee_key),page as(select *from q order by elapsed_seconds desc,device_id offset p_offset limit p_limit)
 select jsonb_build_object('settings',public.get_my_tv_rotation_v1(),'server_now',now(),'employee_key',p_employee_key,'employee_name',(select min(employee_name)from q),'phone_count',(select count(*)from q),'offset',p_offset,'has_more',p_offset+p_limit<(select count(*)from q),'rows',coalesce((select jsonb_agg(to_jsonb(p)order by p.elapsed_seconds desc,p.device_id)from page p),'[]'))into r;return r;
end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_my_tv_rotation_v1','{"page":"damage_report","capability":"view","read":true}'),('get_user_tv_rotation_v1','{"page":"user_access","capability":"view","read":true}'),('save_user_access_tv_rotation_v1','{"page":"user_access","capability":"manage_access"}'),
 ('get_tv_overdue_cards_v1','{"page":"damage_report","capability":"overdue_pending","read":true}'),('get_tv_overdue_phones_v1','{"page":"damage_report","capability":"overdue_pending","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
-- Re-seal only reviewed changed functions, retaining all predecessor guards.
do $seal$declare f regprocedure;t record;begin
 for f in select p.oid from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and strpos(p.prosrc,'greenloop-tv-overdue-234')>0 loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  for t in select c.table_name,c.column_name,h.column_name hash_col from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name in('hash','definition_hash')where c.table_schema='greenloop_private'and c.column_name in('identity','object_identity')and right(c.table_name,13)='_installation'loop execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where %I=$1::text',t.table_name,t.hash_col,t.column_name)using f;end loop;
 end loop;
end;$seal$;
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_my_tv_rotation_v1','get_user_tv_rotation_v1','save_user_access_tv_rotation_v1','get_tv_overdue_cards_v1','get_tv_overdue_phones_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
revoke all on function greenloop_private.tvr_settings(uuid),greenloop_private.tvr_wall_access(boolean),greenloop_private.tvr_rows()from public,anon,authenticated;
create table if not exists greenloop_private.tv_overdue_installation(identity text primary key,hash text not null);
alter table greenloop_private.tv_overdue_installation enable row level security;revoke all on greenloop_private.tv_overdue_installation from public,anon,authenticated;
create or replace function public.get_tv_overdue_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_b_dept_report_version()='20261101-b-dept-report-1'
 and(select count(*)=17 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.tv_overdue_installation)
 and not exists(select 1 from greenloop_private.tv_overdue_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from unnest(array['tv_rotation_settings','tv_rotation_audit','tv_overdue_installation'])t where has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or not(select relrowsecurity from pg_class where oid=('greenloop_private.'||t)::regclass))
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='damage_report'and capabilities @> '[{"key":"overdue_pending","write":false}]')
 then '20261101-tv-overdue-1'end;
$$;
revoke all on function public.get_tv_overdue_version()from public;grant execute on function public.get_tv_overdue_version()to anon,authenticated;
insert into greenloop_private.tv_overdue_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and(p.proname in('tvr_settings','tvr_wall_access','tvr_rows')or strpos(p.prosrc,'greenloop-tv-overdue-234')>0)or p.pronamespace='public'::regnamespace and p.proname in('get_my_tv_rotation_v1','get_user_tv_rotation_v1','save_user_access_tv_rotation_v1','get_tv_overdue_cards_v1','get_tv_overdue_phones_v1','get_tv_overdue_version')or p.oid in(select to_regprocedure(r.implementation)from greenloop_private.office_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)where src.proname in('get_my_tv_rotation_v1','get_user_tv_rotation_v1','save_user_access_tv_rotation_v1','get_tv_overdue_cards_v1','get_tv_overdue_phones_v1'))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_tv_overdue_version()is distinct from '20261101-tv-overdue-1'then raise exception 'TV overdue installation verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_tv_overdue_version()as installed_tv_overdue_version;
