-- Per-TV-account employee visibility. No incident or payroll records change.
begin;
do $$ begin
 if public.get_settings_appearance_version() is distinct from '20261017-settings-appearance-1' then raise exception 'Install Settings / Appearance first.';end if;
end; $$;
create table if not exists greenloop_private.damage_tv_employees(
 user_id uuid primary key references public.user_profiles(id) on delete cascade,
 employee_keys text[] -- NULL: all, including future employees; empty: none.
);
alter table greenloop_private.damage_tv_employees enable row level security;
revoke all on greenloop_private.damage_tv_employees from public,anon,authenticated;
create or replace function greenloop_private.tv_employee_key(p_id uuid,p_name text)
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(p_id::text,(select id::text from public.manual_damage_options where kind='employee' and is_active and normalized_label=greenloop_private.manual_damage_normalized(p_name)), 'legacy:'||greenloop_private.manual_damage_normalized(p_name));
$$;
create or replace function greenloop_private.tv_employee_visible(p_key text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select not greenloop_private.damage_tv_only(auth.uid()) or coalesce((select employee_keys is null or coalesce(p_key=any(employee_keys),false) from greenloop_private.damage_tv_employees where user_id=auth.uid()),true);
$$;
create or replace view greenloop_private.tv_selected_damage as
 select r.* from greenloop_private.manual_damage_effective r where greenloop_private.tv_employee_visible(greenloop_private.tv_employee_key(r.employee_id,r.damaged_by));
create or replace view greenloop_private.tv_selected_options as
 select o.* from public.manual_damage_options o where kind<>'employee' or greenloop_private.tv_employee_visible(id::text);
revoke all on greenloop_private.tv_selected_damage,greenloop_private.tv_selected_options from public,anon,authenticated;
create or replace function greenloop_private.tv_employee_choices()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with choices as (
 select id::text key,label name,not is_active archived from public.manual_damage_options where kind='employee'
 union all select greenloop_private.tv_employee_key(employee_id,damaged_by),min(damaged_by),true from greenloop_private.manual_damage_effective
 where greenloop_private.tv_employee_key(employee_id,damaged_by) like 'legacy:%' group by 1
 ) select coalesce(jsonb_agg(to_jsonb(c) order by lower(name),key),'[]') from choices c;
$$;
create or replace function public.get_damage_tv_employee_access_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not coalesce(public.is_active_staff() and public.has_role(array['owner','super_admin']::public.app_role_key[]) and public.has_page_capability_v1('user_access','view'),false) then raise exception 'User Access view permission required.' using errcode='42501';end if;
 return jsonb_build_object('employees',greenloop_private.tv_employee_choices(),'accounts',(select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'employee_keys',s.employee_keys)),'[]') from public.user_profiles u left join greenloop_private.damage_tv_employees s on s.user_id=u.id));
end; $$;
create or replace function public.save_user_access_tv_employees_v1(
 p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,
 p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text,p_capabilities jsonb,p_employee_keys jsonb
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare keys text[];begin
 if not public.has_page_capability_v1('user_access','manage_access') then raise exception 'Manage User Access permission required.' using errcode='42501';end if;
 if p_employee_keys is not null and p_employee_keys<>'null'::jsonb then
  if jsonb_typeof(p_employee_keys)<>'array' or octet_length(p_employee_keys::text)>100000 then raise exception 'Choose valid TV employees.' using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_employee_keys) e where jsonb_typeof(e)<>'string' or not exists(select 1 from jsonb_array_elements(greenloop_private.tv_employee_choices()) c where c->>'key'=e#>>'{}')) then raise exception 'Employee choices changed. Refresh before saving.' using errcode='22023';end if;
  select coalesce(array_agg(distinct value order by value),'{}'::text[]) into keys from jsonb_array_elements_text(p_employee_keys);
 end if;
 -- Existing atomic editor supplies authorization, stale revision and account guards.
 perform public.save_user_access_capabilities_v1(p_user_id,p_full_name,p_login_username,p_is_active,p_page_permissions,p_partner_names_access,p_tv_only,p_show_parts,p_show_original,p_show_copy,p_expected_revision,p_capabilities);
 insert into greenloop_private.damage_tv_employees(user_id,employee_keys) values(p_user_id,keys) on conflict(user_id) do update set employee_keys=excluded.employee_keys;
 return true;
end; $$;
-- Scope the TV-only reader chain before aggregation/pagination. The ordinary
-- damage report and PDF readers retain their original sources and permissions.
do $scope$
declare f record;definition text;name text;begin
 for f in select p.oid,p.proname from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['damage_copy_rows','damage_copy_values','manual_damage_employee_value','damage_basis_rows']) loop
  name:='tv_selected_'||f.proname;
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,'greenloop_private.'||f.proname||'(','greenloop_private.'||name||'(');
  definition:=regexp_replace(definition,'(FROM|JOIN|from|join) greenloop_private\.manual_damage_effective',E'\\1 greenloop_private.tv_selected_damage','g');
  definition:=replace(definition,'public.manual_damage_options','greenloop_private.tv_selected_options');
  execute definition;
 end loop;
 for f in select p.oid from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'tv_read_%' loop
  definition:=pg_get_functiondef(f.oid);
  definition:=regexp_replace(definition,'(FROM|JOIN|from|join) greenloop_private\.manual_damage_effective',E'\\1 greenloop_private.tv_selected_damage','g');
  definition:=replace(definition,'public.manual_damage_options','greenloop_private.tv_selected_options');
  foreach name in array array['damage_copy_rows','damage_copy_values','manual_damage_employee_value','damage_basis_rows'] loop
   definition:=replace(definition,'greenloop_private.'||name||'(','greenloop_private.tv_selected_'||name||'(');
  end loop;
  execute definition;
 end loop;
end; $scope$;
-- Only re-seal the reviewed scoped reader definitions in the predecessor receipt.
update greenloop_private.damage_tv_display_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity like 'greenloop_private.tv_read_%';
do $acl$ declare f record;begin for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='greenloop_private' and p.proname=any(array['tv_employee_key','tv_employee_visible','tv_employee_choices','tv_selected_damage_copy_rows','tv_selected_damage_copy_values','tv_selected_manual_damage_employee_value','tv_selected_damage_basis_rows'])) or (n.nspname='public' and p.proname in ('get_damage_tv_employee_access_v1','save_user_access_tv_employees_v1')) loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.signature);end if;
end loop;end; $acl$;
create table if not exists greenloop_private.tv_employee_installation(identity text primary key,hash text not null);
alter table greenloop_private.tv_employee_installation enable row level security;
revoke all on greenloop_private.tv_employee_installation from public,anon,authenticated;
insert into greenloop_private.tv_employee_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='greenloop_private' and p.proname=any(array['tv_employee_key','tv_employee_visible','tv_employee_choices','tv_selected_damage_copy_rows','tv_selected_damage_copy_values','tv_selected_manual_damage_employee_value','tv_selected_damage_basis_rows'])) or (n.nspname='public' and p.proname in ('get_damage_tv_employee_access_v1','save_user_access_tv_employees_v1')) on conflict(identity) do update set hash=excluded.hash;
insert into greenloop_private.tv_employee_installation values('greenloop_private.tv_selected_damage',md5(pg_get_viewdef('greenloop_private.tv_selected_damage'::regclass,true))),('greenloop_private.tv_selected_options',md5(pg_get_viewdef('greenloop_private.tv_selected_options'::regclass,true))) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_damage_tv_employees_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_tv_display_version()='20261016-damage-tv-display-1' and public.get_settings_appearance_version()='20261017-settings-appearance-1'
 and (select count(*)=9 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.tv_employee_installation where identity not in ('greenloop_private.tv_selected_damage','greenloop_private.tv_selected_options'))
 and (select count(*)=2 and bool_and(hash=md5(pg_get_viewdef(identity::regclass,true))) from greenloop_private.tv_employee_installation where identity in ('greenloop_private.tv_selected_damage','greenloop_private.tv_selected_options'))
 and not exists(select 1 from unnest(array['greenloop_private.damage_tv_employees','greenloop_private.tv_employee_installation','greenloop_private.tv_selected_damage','greenloop_private.tv_selected_options']) t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and (select relrowsecurity from pg_class where oid='greenloop_private.damage_tv_employees'::regclass)
 then '20261021-damage-tv-employees-1' end;
$$;
revoke all on function public.get_damage_tv_employees_version() from public;
grant execute on function public.get_damage_tv_employees_version() to anon,authenticated;
do $$ begin if public.get_damage_tv_employees_version() is distinct from '20261021-damage-tv-employees-1' then raise exception 'TV employee selection verification failed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_damage_tv_employees_version() as installed_damage_tv_employees_version;
