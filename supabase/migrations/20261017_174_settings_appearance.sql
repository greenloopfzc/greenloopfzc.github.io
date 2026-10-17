-- Independent Settings / Appearance actions. No operational records are changed.
begin;
do $$ begin
 if public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1' then
  raise exception 'Install the verified Page Permissions update first.';
 end if;
end; $$;
create table if not exists greenloop_private.settings_appearance_installation(identity text primary key,hash text not null);
create table if not exists greenloop_private.settings_appearance_function_backup(identity text primary key,definition text not null,hash text not null);
alter table greenloop_private.settings_appearance_installation enable row level security;
alter table greenloop_private.settings_appearance_function_backup enable row level security;
revoke all on greenloop_private.settings_appearance_installation,greenloop_private.settings_appearance_function_backup from public,anon,authenticated;
insert into greenloop_private.settings_appearance_function_backup
 select p.oid::regprocedure::text,pg_get_functiondef(p.oid),md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid=any(array[
 'greenloop_private.user_capabilities(uuid)'::regprocedure,
 'greenloop_private.normalize_capabilities(jsonb)'::regprocedure,
 'public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)'::regprocedure])
 on conflict(identity) do nothing;
-- Preserve existing appearance access once. Explicit selections made after this
-- installation (including revocations) are never reset by rerunning the script.
do $backfill$
begin
 if not exists(select 1 from greenloop_private.settings_appearance_installation where identity='backfill') then
  -- Serialize the one-time snapshot with account-permission saves.
  lock table public.user_page_permissions,greenloop_private.user_page_capabilities in share row exclusive mode;
  insert into greenloop_private.user_page_capabilities(user_id,capabilities,updated_by,updated_at)
   select u.id,c.caps||jsonb_build_object('appearance',case when exists(
    select 1 from greenloop_private.page_capability_catalog p cross join lateral jsonb_array_elements(p.capabilities) a
    where coalesce((a->>'write')::boolean,false) and coalesce(c.caps->p.page_key,'[]'::jsonb)?(a->>'key')
   ) then '["view","theme","display_mode"]'::jsonb else '[]'::jsonb end),null,now()
   from public.user_profiles u cross join lateral(select greenloop_private.user_capabilities(u.id) caps) c
   on conflict(user_id) do update set capabilities=excluded.capabilities;
  insert into greenloop_private.settings_appearance_installation values('backfill','20261017-settings-appearance-1');
 end if;
end;
$backfill$;
insert into greenloop_private.page_capability_catalog values('appearance','[{"key":"view","label":"Settings access","write":false},{"key":"theme","label":"Change Theme","write":false},{"key":"display_mode","label":"Change Display Mode (Light/Dark)","write":false}]'::jsonb)
 on conflict(page_key) do update set capabilities=excluded.capabilities;

create or replace function greenloop_private.user_capabilities(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare configured jsonb;result jsonb:='{}';p record;level text;is_owner boolean;
begin
 if not exists(select 1 from public.user_profiles where id=p_user_id) then return (select jsonb_object_agg(page_key,'[]'::jsonb) from greenloop_private.page_capability_catalog);end if;
 select capabilities into configured from greenloop_private.user_page_capabilities where user_id=p_user_id;
 select exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_user_id and r.role_key::text in ('owner','super_admin')) into is_owner;
 for p in select * from greenloop_private.page_capability_catalog loop
  -- Appearance is a preference permission, never a routed page or entry grant.
  if p.page_key='appearance' then
   result:=result||jsonb_build_object('appearance',coalesce(configured->'appearance','[]'::jsonb));
   continue;
  end if;
  select access_level into level from public.user_page_permissions where user_id=p_user_id and page_key=p.page_key;
  level:=coalesce(level,case when is_owner and p.page_key=any(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported']) then 'edit' else 'none' end);
  if level='none' then result:=result||jsonb_build_object(p.page_key,'[]'::jsonb);
  elsif configured is not null then result:=result||jsonb_build_object(p.page_key,coalesce(configured->p.page_key,'[]'::jsonb));
  else result:=result||jsonb_build_object(p.page_key,(select coalesce(jsonb_agg(c->>'key'),'[]') from jsonb_array_elements(p.capabilities) c where level='edit' or c->>'key'='view' or (p.page_key='damage_report' and c->>'key'=any(array['parts_details','original_prices','copy_prices','payable']))));end if;
 end loop;
 return result;
end; $$;
create or replace function greenloop_private.normalize_capabilities(p_caps jsonb)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare p record;c jsonb;normalized jsonb:='{}';permissions jsonb:='{}';selected jsonb;writable boolean;
begin
 if jsonb_typeof(p_caps) is distinct from 'object' then raise exception 'Page capabilities must be an object.' using errcode='22023';end if;
 if exists(select 1 from jsonb_object_keys(p_caps) k where not exists(select 1 from greenloop_private.page_capability_catalog where page_key=k)) then raise exception 'Unknown capability page.' using errcode='22023';end if;
 for p in select * from greenloop_private.page_capability_catalog loop
  selected:=coalesce(p_caps->p.page_key,'[]');
  if jsonb_typeof(selected)<>'array' or exists(select 1 from jsonb_array_elements(selected) v where jsonb_typeof(v)<>'string') then raise exception 'Select valid capability checkboxes for %.',p.page_key using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements_text(selected) v where not exists(select 1 from jsonb_array_elements(p.capabilities) a where a->>'key'=v)) then raise exception 'Unknown capability for %.',p.page_key using errcode='22023';end if;
  select coalesce(jsonb_agg(v order by v),'[]') into selected from(select distinct value v from jsonb_array_elements_text(selected)) d;
  if p.page_key='appearance' then
   -- The two user-facing ticks imply their virtual View capability. A standalone
   -- virtual View tick is not a real page and grants no appearance actions.
   if selected?'theme' or selected?'display_mode' then
    select jsonb_agg(v order by v) into selected from (select distinct value v from jsonb_array_elements_text(selected||'["view"]'::jsonb)) d;
   else selected:='[]'::jsonb;end if;
   normalized:=normalized||jsonb_build_object(p.page_key,selected);
   continue;
  end if;
  if jsonb_array_length(selected)>0 and not selected?'view' then raise exception 'View page must be selected for %.',p.page_key using errcode='22023';end if;
  if p.page_key='damage_report' and selected?'payable' and not(selected?'original_prices' or selected?'copy_prices') then raise exception 'Select Original Price or Copy Price before Payable.' using errcode='22023';end if;
  normalized:=normalized||jsonb_build_object(p.page_key,selected);
  select exists(select 1 from jsonb_array_elements(p.capabilities) a where (a->>'write')::boolean and selected?(a->>'key')) into writable;
  if selected?'view' then permissions:=permissions||jsonb_build_object(p.page_key,case when writable then 'edit' else 'view' end);
  elsif p.page_key=any(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported']) then permissions:=permissions||jsonb_build_object(p.page_key,'none');end if;
 end loop;
 if not exists(select 1 from jsonb_each_text(permissions) e where e.value in ('view','edit')) then raise exception 'Select at least one page.' using errcode='22023';end if;
 return jsonb_build_object('capabilities',normalized,'permissions',permissions);
end; $$;
create or replace function public.save_user_access_capabilities_v1(
 p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,
 p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text,p_capabilities jsonb
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare n jsonb;caps jsonb;existing_access jsonb;
begin
 if not public.has_page_capability_v1('user_access','manage_access') then raise exception 'Manage User Access permission required.' using errcode='42501';end if;
 caps:=p_capabilities;
 if p_tv_only then
  caps:=jsonb_build_object('damage_report',to_jsonb(array_remove(array['view',case when p_show_parts then 'parts_details' end,case when p_show_original then 'original_prices' end,case when p_show_copy then 'copy_prices' end,case when p_show_original or p_show_copy then 'payable' end],null)),'appearance',coalesce(p_capabilities->'appearance','[]'::jsonb));
 end if;
 n:=greenloop_private.normalize_capabilities(caps);
 existing_access:=coalesce(greenloop_private.user_capabilities(p_user_id)->'user_access','[]');
 if not public.has_role(array['super_admin']::public.app_role_key[]) and not(existing_access @> (n->'capabilities'->'user_access') and existing_access <@ (n->'capabilities'->'user_access')) then raise exception 'Only Super Admin can change User Access permissions.' using errcode='42501';end if;
 if p_user_id=auth.uid() and not (n->'capabilities'->'user_access')?'manage_access' then raise exception 'You cannot remove your own permission-management access.' using errcode='42501';end if;
 perform public.save_user_access_with_damage_tv_v1(p_user_id,p_full_name,p_login_username,p_is_active,n->'permissions',p_partner_names_access,p_tv_only,p_show_parts,p_show_original,p_show_copy,p_expected_revision);
 insert into greenloop_private.user_page_capabilities values(p_user_id,n->'capabilities',auth.uid(),now()) on conflict(user_id) do update set capabilities=excluded.capabilities,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 return true;
end; $$;

-- Retain the previous installation receipt by resealing only these three
-- reviewed definitions and the catalog row added by this migration.
update greenloop_private.page_capability_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity)))
 where identity in (
 'greenloop_private.user_capabilities(uuid)',
 'greenloop_private.normalize_capabilities(jsonb)',
 'save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)',
 'public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)');
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
revoke all on function greenloop_private.user_capabilities(uuid),greenloop_private.normalize_capabilities(jsonb) from public,anon,authenticated;
revoke all on function public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb) from public,anon;
grant execute on function public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb) to authenticated;
insert into greenloop_private.settings_appearance_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid=any(array[
 'greenloop_private.user_capabilities(uuid)'::regprocedure,
 'greenloop_private.normalize_capabilities(jsonb)'::regprocedure,
 'public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)'::regprocedure])
 on conflict(identity) do update set hash=excluded.hash;
insert into greenloop_private.settings_appearance_installation values('appearance_catalog',(select md5(capabilities::text) from greenloop_private.page_capability_catalog where page_key='appearance'))
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_settings_appearance_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_page_capabilities_version()='20261016-page-capabilities-1'
 and (select count(*)=3 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.settings_appearance_installation where identity not in ('backfill','appearance_catalog'))
 and exists(select 1 from greenloop_private.settings_appearance_installation where identity='backfill' and hash='20261017-settings-appearance-1')
 and exists(select 1 from greenloop_private.settings_appearance_installation where identity='appearance_catalog' and hash=(select md5(capabilities::text) from greenloop_private.page_capability_catalog where page_key='appearance'))
 and not exists(select 1 from unnest(array['settings_appearance_installation','settings_appearance_function_backup']) t join pg_class c on c.oid=('greenloop_private.'||t)::regclass where not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 then '20261017-settings-appearance-1' end;
$$;
revoke all on function public.get_settings_appearance_version() from public;
grant execute on function public.get_settings_appearance_version() to anon,authenticated;
do $$ begin
 if public.get_settings_appearance_version() is distinct from '20261017-settings-appearance-1' then
  raise exception 'Settings / Appearance verification failed. Nothing installed.';
 end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_settings_appearance_version() as installed_settings_appearance_version;
