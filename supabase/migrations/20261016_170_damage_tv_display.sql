-- Per-account Damage TV display; no incident, price or payroll data is changed.
begin;
do $$ begin if public.get_damage_dual_price_version() is distinct from '20261016-damage-dual-price-1' then raise exception 'Install the verified Original / Copy Price update first.';end if;end; $$;
create table if not exists greenloop_private.damage_tv_settings(
 user_id uuid primary key references public.user_profiles(id) on delete cascade,
 tv_only boolean not null default false,
 show_parts boolean not null default true,
 show_original boolean not null default true,
 show_copy boolean not null default true,
 revision bigint generated always as identity,
 updated_by uuid, updated_at timestamptz not null default now(),
 check(not tv_only or show_parts or show_original or show_copy)
);
alter table greenloop_private.damage_tv_settings enable row level security;
revoke all on greenloop_private.damage_tv_settings from public,anon,authenticated;
create or replace function greenloop_private.damage_tv_only(p_user_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce((select tv_only from greenloop_private.damage_tv_settings where user_id=p_user_id),false);
$$;
create or replace function greenloop_private.damage_tv_access(p_edit boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false)
 and coalesce((select case when p_edit then p.access_level='edit' else p.access_level in ('view','edit') end from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key='damage_report'),public.has_role(array['owner','super_admin']::public.app_role_key[]),false);
$$;
-- Legacy unmasked report/export endpoints remain available to normal accounts.
-- The TV account can only use the new masked readers below.
create or replace function greenloop_private.damage_report_access(p_edit boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select not greenloop_private.damage_tv_only(auth.uid()) and greenloop_private.damage_tv_access(p_edit);
$$;
create or replace function public.get_my_damage_tv_settings_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare s greenloop_private.damage_tv_settings%rowtype;begin
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) then raise exception 'Active account required.' using errcode='42501';end if;
 select * into s from greenloop_private.damage_tv_settings where user_id=auth.uid();
 return jsonb_build_object('tv_only',coalesce(s.tv_only,false),'show_parts',case when s.tv_only then s.show_parts else true end,'show_original',case when s.tv_only then s.show_original else true end,'show_copy',case when s.tv_only then s.show_copy else true end,'revision',coalesce(s.revision,0)::text);
end; $$;
create or replace function public.get_user_damage_tv_settings_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not coalesce(public.is_active_staff() and public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then raise exception 'Administrator permission required.' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'tv_only',coalesce(s.tv_only,false),'show_parts',coalesce(s.show_parts,true),'show_original',coalesce(s.show_original,true),'show_copy',coalesce(s.show_copy,true),'revision',coalesce(s.revision,0)::text,
 'protected_account',exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text in ('owner','super_admin')))),'[]') from public.user_profiles u left join greenloop_private.damage_tv_settings s on s.user_id=u.id);
end; $$;
-- Prevent old account editors or direct role assignments from broadening a TV
-- account. Turning TV-only OFF through the atomic editor removes this restriction.
create or replace function greenloop_private.damage_tv_permission_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if greenloop_private.damage_tv_only(new.user_id) then
  if tg_table_name='user_roles' then raise exception 'Turn TV Display Only off before assigning roles.' using errcode='42501';end if;
  if new.page_key<>'damage_report' and new.access_level<>'none' then raise exception 'TV Display Only accounts can only view the damage wall.' using errcode='42501';end if;
  if new.page_key='damage_report' then new.access_level:='view';end if;
 end if;
 return new;
end; $$;
drop trigger if exists damage_tv_permission_guard on public.user_page_permissions;
create trigger damage_tv_permission_guard before insert or update on public.user_page_permissions for each row execute function greenloop_private.damage_tv_permission_guard();
drop trigger if exists damage_tv_role_guard on public.user_roles;
create trigger damage_tv_role_guard before insert or update on public.user_roles for each row execute function greenloop_private.damage_tv_permission_guard();
create or replace function public.save_user_access_with_damage_tv_v1(
 p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,
 p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_revision text;begin
 perform public.greenloop_require_entry(array['user_access']);
 if not coalesce(public.is_active_staff() and public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then raise exception 'Administrator permission required.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('damage-tv:'||p_user_id::text,0));
 if not exists(select 1 from public.user_profiles where id=p_user_id) then raise exception 'Account not found.' using errcode='22023';end if;
 select revision::text into v_revision from greenloop_private.damage_tv_settings where user_id=p_user_id;
 if p_expected_revision is distinct from coalesce(v_revision,'0') then raise exception 'This account changed. Refresh the account and retry.' using errcode='40001';end if;
 if p_tv_only is null or p_show_parts is null or p_show_original is null or p_show_copy is null or (p_tv_only and not (p_show_parts or p_show_original or p_show_copy)) then raise exception 'Choose at least one TV display option.' using errcode='22023';end if;
 if p_tv_only and (p_user_id=auth.uid() or exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_user_id and r.role_key::text in ('owner','super_admin'))) then raise exception 'Use a staff account for TV Display Only. Administrator accounts cannot be converted.' using errcode='22023';end if;
 insert into greenloop_private.damage_tv_settings(user_id,tv_only,show_parts,show_original,show_copy,updated_by) values(p_user_id,p_tv_only,p_show_parts,p_show_original,p_show_copy,auth.uid())
 on conflict(user_id) do update set tv_only=excluded.tv_only,show_parts=excluded.show_parts,show_original=excluded.show_original,show_copy=excluded.show_copy,revision=default,updated_by=auth.uid(),updated_at=now();
 perform public.save_user_access_complete(p_user_id,p_full_name,p_login_username,p_is_active,case when p_tv_only then '{"damage_report":"view"}'::jsonb else p_page_permissions end,case when p_tv_only then 'none' else p_partner_names_access end);
 return true;
end; $$;
-- Configure the existing requested username once. Replays preserve admin choices.
do $$ declare u record;begin
 for u in select * from public.user_profiles p where lower(btrim(p.login_username))='labdamage' and not exists(select 1 from greenloop_private.damage_tv_settings s where s.user_id=p.id) loop
  if exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text in ('owner','super_admin')) then raise exception 'labdamage is an administrator. Assign a staff TV account before installing.';end if;
  insert into greenloop_private.damage_tv_settings(user_id,tv_only,show_parts,show_original,show_copy) values(u.id,true,true,false,false);
  delete from public.user_roles where user_id=u.id;
  delete from public.user_page_permissions where user_id=u.id;
  insert into public.user_page_permissions(user_id,page_key,access_level) values(u.id,'damage_report','view');
 end loop;
end; $$;

do $clone$ declare signature text;definition text;begin
 foreach signature in array array['public.get_manual_damage_employee_rows_v2(uuid,integer,integer)','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','public.get_manual_damage_employee_rows_v4(uuid,integer,integer)','public.get_manual_damage_cards_v2(integer,integer,integer)','public.get_manual_damage_cards_v3(integer,integer,integer)','public.get_manual_damage_cards_v4(integer,integer,integer)','public.get_manual_damage_cards_v5(integer,integer,integer)','public.get_manual_damage_cards_v6(integer,integer,integer)','greenloop_private.damage_basis_summary(text,integer,integer,boolean)','public.get_damage_tv_summary_v2(text,integer,integer)'] loop
 definition:=pg_get_functiondef(to_regprocedure(signature));
 definition:=replace(definition,'public.get_manual_damage_employee_rows_v2(','greenloop_private.tv_read_get_manual_damage_employee_rows_v2(');
 definition:=replace(definition,'public.get_manual_damage_employee_rows_v3(','greenloop_private.tv_read_get_manual_damage_employee_rows_v3(');
 definition:=replace(definition,'public.get_manual_damage_employee_rows_v4(','greenloop_private.tv_read_get_manual_damage_employee_rows_v4(');
 definition:=replace(definition,'public.get_manual_damage_cards_v2(','greenloop_private.tv_read_get_manual_damage_cards_v2(');
 definition:=replace(definition,'public.get_manual_damage_cards_v3(','greenloop_private.tv_read_get_manual_damage_cards_v3(');
 definition:=replace(definition,'public.get_manual_damage_cards_v4(','greenloop_private.tv_read_get_manual_damage_cards_v4(');
 definition:=replace(definition,'public.get_manual_damage_cards_v5(','greenloop_private.tv_read_get_manual_damage_cards_v5(');
 definition:=replace(definition,'public.get_manual_damage_cards_v6(','greenloop_private.tv_read_get_manual_damage_cards_v6(');
 definition:=replace(definition,'greenloop_private.damage_basis_summary(','greenloop_private.tv_read_damage_basis_summary(');
 definition:=replace(definition,'public.get_damage_tv_summary_v2(','greenloop_private.tv_read_get_damage_tv_summary_v2(');
 definition:=replace(definition,'greenloop_private.damage_report_access(','greenloop_private.damage_tv_access(');
 execute definition;
 end loop;end; $clone$;

-- Explicit field allowlist. New fields stay private until deliberately classified.
create or replace function greenloop_private.damage_tv_mask(p_value jsonb,p_display jsonb)
returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$
declare k text;v jsonb;out_value jsonb:='{}';allowed text[]:=array['id','employee_id','employee_key','name','employee_name','damaged_by','employees','rows','activity','employee_count','record_count','result_count','has_more','offset','limit','version','scope','date_from','date_to','generated_at','has_damage'];begin
 if not (p_display->>'tv_only')::boolean then return p_value;end if;
 if jsonb_typeof(p_value)='array' then return coalesce((select jsonb_agg(greenloop_private.damage_tv_mask(value,p_display) order by ordinality) from jsonb_array_elements(p_value) with ordinality),'[]');end if;
 if jsonb_typeof(p_value)<>'object' then return p_value;end if;
 if p_value ? 'total_damage' then p_value:=p_value||jsonb_build_object('has_damage',(p_value->>'total_damage')::numeric>0);end if;
 if p_value ? 'quantity' and p_value ? 'price_amount' then p_value:=p_value||jsonb_build_object('entry_total',round((p_value->>'quantity')::numeric*(p_value->>'price_amount')::numeric,2),'copy_entry_total',round((p_value->>'quantity')::numeric*(p_value->>'copy_price_amount')::numeric,2));end if;
 if (p_display->>'show_parts')::boolean then allowed:=allowed||array['model','identifier','part_name','quantity','reason','part_source','reported_by','occurred_at','created_at','department','total_damage','today_count','month_count','total_count','lcd_quantity','waived_quantity'];end if;
 if (p_display->>'show_original')::boolean then allowed:=allowed||array['price_amount','entry_total','value_totals','unpriced_quantity','payable','confirmed_payable','pending_count','pending','lcd_average','waived_value'];end if;
 if (p_display->>'show_copy')::boolean then allowed:=allowed||array['copy_price_amount','copy_entry_total','copy_value_totals','copy_unpriced_quantity','copy_payable','copy_confirmed_payable','copy_pending_count','copy_pending','copy_lcd_average','copy_waived_value'];end if;
 if (p_display->>'show_original')::boolean or (p_display->>'show_copy')::boolean then allowed:=allowed||array['currency','amount','deduction'];end if;
 for k,v in select * from jsonb_each(p_value) loop
  if k=any(allowed) then out_value:=out_value||jsonb_build_object(k,greenloop_private.damage_tv_mask(v,p_display));end if;
 end loop;
 return out_value;
end; $$;
create or replace function public.get_damage_tv_cards_v1(p_offset integer default 0,p_limit integer default 100,p_row_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;r jsonb;begin
 if not greenloop_private.damage_tv_access() then raise exception 'Damage Report view permission required.' using errcode='42501';end if;
 d:=public.get_my_damage_tv_settings_v1();
 r:=greenloop_private.tv_read_get_manual_damage_cards_v6(p_offset,p_limit,p_row_limit);
 return greenloop_private.damage_tv_mask(r,d)||jsonb_build_object('tv_display',d);
end; $$;
create or replace function public.get_damage_tv_employee_v1(p_employee_id uuid,p_offset integer default 0,p_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;r jsonb;begin
 if not greenloop_private.damage_tv_access() then raise exception 'Damage Report view permission required.' using errcode='42501';end if;
 d:=public.get_my_damage_tv_settings_v1();
 r:=greenloop_private.tv_read_get_manual_damage_employee_rows_v4(p_employee_id,p_offset,p_limit);
 return greenloop_private.damage_tv_mask(r,d)||jsonb_build_object('tv_display',d);
end; $$;
create or replace function public.get_damage_tv_details_v1(p_scope text,p_offset integer default 0,p_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;r jsonb;begin
 if not greenloop_private.damage_tv_access() then raise exception 'Damage Report view permission required.' using errcode='42501';end if;
 d:=public.get_my_damage_tv_settings_v1();
 r:=greenloop_private.tv_read_get_damage_tv_summary_v2(p_scope,p_offset,p_limit);
 return greenloop_private.damage_tv_mask(r,d)||jsonb_build_object('tv_display',d);
end; $$;
update greenloop_private.tv_damage_access_installation set definition_hash=md5(pg_get_functiondef(to_regprocedure(object_identity))) where object_kind='function' and object_identity='greenloop_private.damage_report_access(boolean)';

do $acl$ declare f record;begin for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname=any(array['greenloop_private.damage_tv_only','greenloop_private.damage_tv_access','greenloop_private.damage_report_access','public.get_my_damage_tv_settings_v1','public.get_user_damage_tv_settings_v1','greenloop_private.damage_tv_permission_guard','public.save_user_access_with_damage_tv_v1','greenloop_private.damage_tv_mask','public.get_damage_tv_cards_v1','public.get_damage_tv_employee_v1','public.get_damage_tv_details_v1','greenloop_private.tv_read_get_manual_damage_employee_rows_v2','greenloop_private.tv_read_get_manual_damage_employee_rows_v3','greenloop_private.tv_read_get_manual_damage_employee_rows_v4','greenloop_private.tv_read_get_manual_damage_cards_v2','greenloop_private.tv_read_get_manual_damage_cards_v3','greenloop_private.tv_read_get_manual_damage_cards_v4','greenloop_private.tv_read_get_manual_damage_cards_v5','greenloop_private.tv_read_get_manual_damage_cards_v6','greenloop_private.tv_read_damage_basis_summary','greenloop_private.tv_read_get_damage_tv_summary_v2']) loop
execute format('revoke all on function %s from public,anon,authenticated',f.signature);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.signature);end if;end loop;end; $acl$;
create table if not exists greenloop_private.damage_tv_display_installation(identity text primary key,hash text not null);
alter table greenloop_private.damage_tv_display_installation enable row level security;
revoke all on greenloop_private.damage_tv_display_installation from public,anon,authenticated;
create or replace function greenloop_private.damage_tv_display_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select md5(jsonb_build_object('columns',(select jsonb_agg(jsonb_build_array(attname,atttypid::regtype::text,attnotnull) order by attnum) from pg_attribute where attrelid='greenloop_private.damage_tv_settings'::regclass and attnum>0),
 'constraints',(select jsonb_agg(pg_get_constraintdef(oid) order by conname) from pg_constraint where conrelid='greenloop_private.damage_tv_settings'::regclass),
 'triggers',(select jsonb_agg(pg_get_triggerdef(oid)||tgenabled::text order by tgname) from pg_trigger where tgname in ('damage_tv_permission_guard','damage_tv_role_guard')))::text);
$$;
revoke all on function greenloop_private.damage_tv_display_schema() from public,anon,authenticated;
insert into greenloop_private.damage_tv_display_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname=any(array['greenloop_private.damage_tv_only','greenloop_private.damage_tv_access','greenloop_private.damage_report_access','public.get_my_damage_tv_settings_v1','public.get_user_damage_tv_settings_v1','greenloop_private.damage_tv_permission_guard','public.save_user_access_with_damage_tv_v1','greenloop_private.damage_tv_mask','public.get_damage_tv_cards_v1','public.get_damage_tv_employee_v1','public.get_damage_tv_details_v1','greenloop_private.tv_read_get_manual_damage_employee_rows_v2','greenloop_private.tv_read_get_manual_damage_employee_rows_v3','greenloop_private.tv_read_get_manual_damage_employee_rows_v4','greenloop_private.tv_read_get_manual_damage_cards_v2','greenloop_private.tv_read_get_manual_damage_cards_v3','greenloop_private.tv_read_get_manual_damage_cards_v4','greenloop_private.tv_read_get_manual_damage_cards_v5','greenloop_private.tv_read_get_manual_damage_cards_v6','greenloop_private.tv_read_damage_basis_summary','greenloop_private.tv_read_get_damage_tv_summary_v2','greenloop_private.damage_tv_display_schema']) on conflict(identity) do update set hash=excluded.hash;
insert into greenloop_private.damage_tv_display_installation values('schema',greenloop_private.damage_tv_display_schema()) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_damage_tv_display_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_dual_price_version()='20261016-damage-dual-price-1'
 and (select count(*)=22 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.damage_tv_display_installation where identity<>'schema')
 and exists(select 1 from greenloop_private.damage_tv_display_installation where identity='schema' and hash=greenloop_private.damage_tv_display_schema())
 and not exists(select 1 from unnest(array['greenloop_private.damage_tv_settings','greenloop_private.damage_tv_display_installation']) t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or not (select relrowsecurity from pg_class where oid=t::regclass))
 then '20261016-damage-tv-display-1' end;
$$;
revoke all on function public.get_damage_tv_display_version() from public;
grant execute on function public.get_damage_tv_display_version() to anon,authenticated;
do $$ begin if public.get_damage_tv_display_version() is distinct from '20261016-damage-tv-display-1' then raise exception 'Damage TV Display verification failed. Nothing installed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_damage_tv_display_version() as installed_damage_tv_display_version;
