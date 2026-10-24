-- Server-enforced office network access. Existing accounts default to Anywhere.
begin;
do $$begin if public.get_dual_imei_version() is distinct from '20261023-dual-imei-1' then raise exception 'Install verified Dual IMEI support first.';end if; if to_regprocedure('public.get_office_access_version()') is not null then if public.get_office_access_version() is distinct from '20261024-office-access-1' then raise exception 'Existing Office Access could not be verified; preserve and review it first.';end if;end if;end;$$;
create table if not exists greenloop_private.office_networks(id uuid primary key default gen_random_uuid(),name text not null,network cidr not null unique,is_active boolean not null default true,revision bigint not null default 1,changed_by uuid,changed_at timestamptz not null default now());
create table if not exists greenloop_private.office_user_access(user_id uuid primary key references public.user_profiles(id) on delete cascade,mode text not null check(mode in ('anywhere','office')),revision bigint not null default 1,changed_by uuid,changed_at timestamptz not null default now());
create table if not exists greenloop_private.office_access_audit(id bigint generated always as identity primary key,actor uuid,at timestamptz not null default now(),action text not null,subject text,details jsonb);
create table if not exists greenloop_private.office_routines(identity text primary key,implementation text not null,original_hash text not null,wrapped_hash text not null);
create table if not exists greenloop_private.office_views(identity text primary key,original_query text not null,original_hash text not null,wrapped_hash text not null);
create table if not exists greenloop_private.office_installation(identity text primary key,hash text not null);
create table if not exists greenloop_private.office_previous_hook(singleton boolean primary key default true check(singleton),identity text);
do $$declare t text;begin foreach t in array array['office_networks','office_user_access','office_access_audit','office_routines','office_installation','office_previous_hook','office_views'] loop execute format('alter table greenloop_private.%I enable row level security',t);execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);end loop;end;$$;
revoke all on sequence greenloop_private.office_access_audit_id_seq from public,anon,authenticated;
create or replace function greenloop_private.office_mode(p_user uuid) returns text language sql stable security definer set search_path=pg_catalog,public as $$select coalesce((select mode from greenloop_private.office_user_access where user_id=p_user),'anywhere');$$;
create or replace function greenloop_private.office_service() returns boolean language sql stable as $$select current_setting('role',true)='service_role' or coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')='service_role';$$;
create or replace function greenloop_private.office_request_ip() returns inet language plpgsql stable set search_path=pg_catalog as $$declare value text;begin
 -- Only Cloudflare's overwritten client address is used. No XFF/body/browser fallback.
 value:=nullif(current_setting('request.headers',true),'')::jsonb->>'cf-connecting-ip';
 if value is null or value<>btrim(value) or value ~ '[,/ %]' then return null;end if;
 begin return value::inet;exception when invalid_text_representation then return null;end;
end;$$;
create or replace function greenloop_private.office_ip_allowed(p_ip inet) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$select p_ip is not null and exists(select 1 from greenloop_private.office_networks where is_active and p_ip <<= network);$$;
create or replace function public.greenloop_network_allowed_v1() returns boolean language sql stable security definer set search_path=pg_catalog,public as $$select greenloop_private.office_service() or auth.uid() is null or greenloop_private.office_mode(auth.uid())='anywhere' or greenloop_private.office_ip_allowed(greenloop_private.office_request_ip());$$;
create or replace function greenloop_private.require_office_network() returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin if not public.greenloop_network_allowed_v1() then raise exception 'Office access only. Please connect to the office network.' using errcode='42501',detail='GREENLOOP_OFFICE_ONLY';end if;end;$$;
create or replace function greenloop_private.office_admin(p_cap text) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$select exists(select 1 from public.user_profiles u join public.user_roles ur on ur.user_id=u.id join public.roles r on r.id=ur.role_id where u.id=auth.uid() and u.is_active and r.role_key::text in ('owner','super_admin')) and coalesce((greenloop_private.user_capabilities(auth.uid())->'user_access')?p_cap,false);$$;
create or replace function public.get_my_office_access_v1() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare ip inet:=greenloop_private.office_request_ip();mode text;begin
 if auth.uid() is null or not exists(select 1 from public.user_profiles where id=auth.uid() and is_active) then raise exception 'Active account required.' using errcode='42501';end if;
 mode:=greenloop_private.office_mode(auth.uid());return jsonb_build_object('mode',mode,'allowed',mode='anywhere' or greenloop_private.office_ip_allowed(ip),'detected_ip',host(ip),'configured',exists(select 1 from greenloop_private.office_networks where is_active));end;$$;
create or replace function public.get_office_access_settings_v1() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();if not(greenloop_private.office_admin('view') or greenloop_private.office_admin('create_users') or greenloop_private.office_admin('manage_access')) then raise exception 'User Access permission required.' using errcode='42501';end if;
 return jsonb_build_object('detected_ip',host(greenloop_private.office_request_ip()),'configured',exists(select 1 from greenloop_private.office_networks where is_active),'networks',(select coalesce(jsonb_agg(to_jsonb(n) order by lower(name),id),'[]') from greenloop_private.office_networks n),'accounts',(select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'mode',coalesce(a.mode,'anywhere'),'revision',coalesce(a.revision,0)::text)),'[]') from public.user_profiles u left join greenloop_private.office_user_access a on a.user_id=u.id));end;$$;
create or replace function greenloop_private.set_office_user(p_user uuid,p_mode text,p_revision text,p_actor uuid) returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare rev bigint;begin
 perform pg_advisory_xact_lock(196,1);
 if p_mode is null or p_mode not in ('anywhere','office') then raise exception 'Choose Office Only or Anywhere.' using errcode='22023';end if;
 if not exists(select 1 from public.user_profiles where id=p_user) then raise exception 'Account not found.' using errcode='22023';end if;
 select revision into rev from greenloop_private.office_user_access where user_id=p_user;
 if coalesce(rev,0)::text is distinct from p_revision then raise exception 'Office access changed. Refresh before saving.' using errcode='40001';end if;
 if p_mode='office' then
  if not exists(select 1 from greenloop_private.office_networks where is_active) then raise exception 'Register and verify the office network before selecting Office Only.' using errcode='22023';end if;
  if p_user=p_actor and not greenloop_private.office_ip_allowed(greenloop_private.office_request_ip()) and not greenloop_private.office_service() then raise exception 'Connect to the office network before restricting your own account.' using errcode='42501';end if;
  if exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_user and r.role_key::text='super_admin') and not exists(select 1 from public.user_profiles u join public.user_roles ur on ur.user_id=u.id join public.roles r on r.id=ur.role_id where u.id<>p_user and u.is_active and r.role_key::text='super_admin' and greenloop_private.office_mode(u.id)='anywhere') then raise exception 'Keep at least one active Super Admin on Anywhere for recovery.' using errcode='42501';end if;
 end if;
 insert into greenloop_private.office_user_access values(p_user,p_mode,1,p_actor,now()) on conflict(user_id) do update set mode=excluded.mode,revision=office_user_access.revision+1,changed_by=excluded.changed_by,changed_at=now();
 if exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where r.role_key::text='super_admin') and not exists(select 1 from public.user_profiles u join public.user_roles ur on ur.user_id=u.id join public.roles r on r.id=ur.role_id where u.is_active and r.role_key::text='super_admin' and greenloop_private.office_mode(u.id)='anywhere') then raise exception 'Keep at least one active Super Admin on Anywhere for recovery.' using errcode='42501';end if;
 insert into greenloop_private.office_access_audit(actor,action,subject,details) values(p_actor,'user_network_access',p_user::text,jsonb_build_object('mode',p_mode));end;$$;
create or replace function public.save_office_network_v1(p_id uuid,p_name text,p_network text,p_is_active boolean,p_expected_revision text) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare net cidr;id uuid;rev bigint;begin
 perform greenloop_private.require_office_network();if not greenloop_private.office_admin('office_networks') then raise exception 'Manage office networks permission required.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(196,1);
 if p_is_active is null or length(btrim(p_name)) not between 2 and 70 then raise exception 'Enter the network name and active status.' using errcode='22023';end if;
 begin net:=p_network::cidr;exception when others then raise exception 'Enter a valid public IP address or office CIDR.' using errcode='22023';end;
 if net is null or (family(net)=4 and masklen(net)<24) or (family(net)=6 and masklen(net)<48) or net && '0.0.0.0/8'::cidr or net && '10.0.0.0/8'::cidr or net && '100.64.0.0/10'::cidr or net && '127.0.0.0/8'::cidr or net && '169.254.0.0/16'::cidr or net && '172.16.0.0/12'::cidr or net && '192.168.0.0/16'::cidr or net && '224.0.0.0/3'::cidr or (family(net)=6 and not net <<= '2000::/3'::cidr) then raise exception 'Use the office public address, not a router/LAN address or a broad internet range.' using errcode='22023';end if;
 if p_id is null then
  if p_expected_revision is distinct from '0' then raise exception 'Refresh office networks before adding.' using errcode='40001';end if;
  insert into greenloop_private.office_networks(name,network,is_active,changed_by) values(btrim(p_name),net,p_is_active,auth.uid()) returning office_networks.id into id;
 else
  select revision into rev from greenloop_private.office_networks where office_networks.id=p_id for update;
  if rev is null or rev::text is distinct from p_expected_revision then raise exception 'Office network changed. Refresh before saving.' using errcode='40001';end if;
  update greenloop_private.office_networks set name=btrim(p_name),network=net,is_active=p_is_active,revision=revision+1,changed_by=auth.uid(),changed_at=now() where office_networks.id=p_id;id:=p_id;
 end if;
 if not exists(select 1 from greenloop_private.office_networks where is_active) and exists(select 1 from greenloop_private.office_user_access a join public.user_profiles u on u.id=a.user_id where mode='office' and u.is_active) then raise exception 'Office Only accounts still exist. Keep an approved network active.' using errcode='22023';end if;
 if greenloop_private.office_mode(auth.uid())='office' and not greenloop_private.office_ip_allowed(greenloop_private.office_request_ip()) then raise exception 'This would block your own current office connection.' using errcode='42501';end if;
 insert into greenloop_private.office_access_audit(actor,action,subject,details) values(auth.uid(),'office_network',id::text,jsonb_build_object('name',btrim(p_name),'network',net,'active',p_is_active));return true;end;$$;
create or replace function public.save_user_access_office_v1(p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text,p_capabilities jsonb,p_employee_keys jsonb,p_network_mode text,p_network_revision text) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();if not greenloop_private.office_admin('manage_access') then raise exception 'Manage User Access permission required.' using errcode='42501';end if;
 perform public.save_user_access_tv_employees_v1(p_user_id,p_full_name,p_login_username,p_is_active,p_page_permissions,p_partner_names_access,p_tv_only,p_show_parts,p_show_original,p_show_copy,p_expected_revision,p_capabilities,p_employee_keys);
 perform greenloop_private.set_office_user(p_user_id,p_network_mode,p_network_revision,auth.uid());return true;end;$$;
create or replace function public.get_office_create_context_v1(p_actor uuid,p_client_ip text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare ip inet;super boolean;allowed boolean;begin
 if not greenloop_private.office_service() then raise exception 'Service role required.' using errcode='42501';end if;
 begin if p_client_ip is null or p_client_ip ~ '[,/ %]' then ip:=null;else ip:=p_client_ip::inet;end if;exception when others then ip:=null;end;
 allowed:=greenloop_private.office_mode(p_actor)='anywhere' or greenloop_private.office_ip_allowed(ip);
 select exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_actor and r.role_key::text='super_admin') into super;
 return jsonb_build_object('allowed',allowed,'is_super_admin',super,'can_create',allowed and exists(select 1 from public.user_profiles u join public.user_roles ur on ur.user_id=u.id join public.roles r on r.id=ur.role_id where u.id=p_actor and u.is_active and r.role_key::text in ('owner','super_admin')) and coalesce((greenloop_private.user_capabilities(p_actor)->'user_access')?'create_users',false));end;$$;
create or replace function public.initialize_user_office_access_v1(p_actor_user_id uuid,p_user_id uuid,p_full_name text,p_login_username text,p_page_permissions jsonb,p_capabilities jsonb,p_partner_names_access text,p_network_mode text,p_client_ip text) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare context jsonb;begin
 context:=public.get_office_create_context_v1(p_actor_user_id,p_client_ip);if context->>'can_create'<>'true' then raise exception 'Account creation is not allowed from this network.' using errcode='42501';end if;
 perform public.initialize_user_capabilities_v1(p_actor_user_id,p_user_id,p_full_name,p_login_username,p_page_permissions,p_capabilities,p_partner_names_access);
 perform greenloop_private.set_office_user(p_user_id,p_network_mode,'0',p_actor_user_id);return true;end;$$;

-- Public installation probe returns a nonce-bound digest, never company data or an allowlist.
create or replace function public.get_office_gateway_probe_v1(p_nonce text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if p_nonce is null or p_nonce!~'^[a-f0-9]{32}$' then raise exception 'Valid probe nonce required.' using errcode='22023';end if;
 return jsonb_build_object('nonce',p_nonce,'digest',md5(host(greenloop_private.office_request_ip())||p_nonce));end;$$;

update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"office_networks","label":"Manage office networks","write":true}]'::jsonb where page_key='user_access' and not capabilities @> '[{"key":"office_networks"}]'::jsonb;
do $initial_network_grant$begin if to_regprocedure('public.get_office_access_version()') is null then
insert into greenloop_private.user_page_capabilities(user_id,capabilities,updated_by,updated_at)
 select u.id,jsonb_set(greenloop_private.user_capabilities(u.id),'{user_access}',(greenloop_private.user_capabilities(u.id)->'user_access')||'"office_networks"'::jsonb),null,now()
 from public.user_profiles u where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text in ('owner','super_admin')) and (greenloop_private.user_capabilities(u.id)->'user_access')?'manage_access' and not (greenloop_private.user_capabilities(u.id)->'user_access')?'office_networks'
 on conflict(user_id) do update set capabilities=excluded.capabilities;
end if;end;$initial_network_grant$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
do $$declare previous text;begin
 select split_part(v,'=',2) into previous from pg_db_role_setting s cross join lateral unnest(s.setconfig)v where s.setrole='authenticator'::regrole and s.setdatabase=0 and v like 'pgrst.db_pre_request=%';
 if previous is not null and previous not in ('','public.greenloop_office_pre_request') and to_regprocedure(previous||'()') is null then raise exception 'Existing pre-request hook could not be verified.';end if;
 insert into greenloop_private.office_previous_hook values(true,nullif(previous,'')) on conflict(singleton) do nothing;end;$$;
create or replace function public.greenloop_office_pre_request() returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare previous text;path text:=regexp_replace(coalesce(current_setting('request.path',true),''),'^/','');begin
 select identity into previous from greenloop_private.office_previous_hook where singleton;
 if previous is not null and previous<>'public.greenloop_office_pre_request' then execute 'select '||to_regprocedure(previous||'()')::text;end if;
 if path not in ('rpc/get_my_office_access_v1','rpc/get_office_gateway_probe_v1') then perform greenloop_private.require_office_network();end if;end;$$;
alter role authenticator set pgrst.db_pre_request='public.greenloop_office_pre_request';
-- A restrictive policy supplements existing row permissions, never grants rows.
-- Realtime has no per-message client IP: Office Only uses authenticated polling.
do $policies$declare t record;old text;begin
 for t in select c.oid,n.nspname,c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and (n.nspname='public' or(n.nspname='storage' and c.relname='objects')) loop
  if not t.relrowsecurity and(has_table_privilege('authenticated',t.oid,'SELECT,INSERT,UPDATE,DELETE') or has_table_privilege('anon',t.oid,'SELECT,INSERT,UPDATE,DELETE')) then raise exception 'Exposed table without RLS needs review: %.%',t.nspname,t.relname;end if;
  if t.relrowsecurity then
   if t.nspname='public' and t.relname='workflow_notification_signal' then
    select pg_get_expr(polqual,polrelid) into old from pg_policy where polrelid=t.oid and polname='workflow_notification_signal_read';
    if old is not null and strpos(old,'greenloop_network_allowed_v1')=0 then execute format('alter policy workflow_notification_signal_read on public.workflow_notification_signal using ((%s) and (select public.greenloop_network_allowed_v1()))',old);end if;
    update greenloop_private.workflow_notification_installation set definition_hash=(select md5(pg_get_expr(polqual,polrelid)) from pg_policy where polrelid=t.oid and polname='workflow_notification_signal_read') where object_name='read_policy';
   else
    execute format('drop policy if exists greenloop_office_boundary on %I.%I',t.nspname,t.relname);
    execute format('create policy greenloop_office_boundary on %I.%I as restrictive for all to anon,authenticated using ((select public.greenloop_network_allowed_v1())) with check ((select public.greenloop_network_allowed_v1()))',t.nspname,t.relname);
   end if;
  end if;
 end loop;end;$policies$;
-- Readable views get their own predicate, including GraphQL view exposure.
do $views$declare v record;original text;begin
 for v in select c.oid,c.relname,c.relowner from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='v' and (has_table_privilege('anon',c.oid,'SELECT') or has_table_privilege('authenticated',c.oid,'SELECT')) loop
  if exists(select 1 from greenloop_private.office_views where to_regclass(identity)=v.oid) then continue;end if;
  if v.relowner<>current_user::regrole then raise exception 'View owner requires review: %',v.relname;end if;
  original:=pg_get_viewdef(v.oid,true);
  execute format('create or replace view public.%I as select * from (%s) office_view where public.greenloop_network_allowed_v1()',v.relname,regexp_replace(original,';[[:space:]]*$',''));
  insert into greenloop_private.office_views values(v.oid::regclass::text,original,md5(original),md5(pg_get_viewdef(v.oid,true)));
 end loop;end;$views$;
-- Guard callable application functions as well, including GraphQL exposure.
do $wrap$declare f record;impl text;ddl text;arguments text;body text;impl_identity text;begin
 for f in select p.*,pg_get_functiondef(p.oid) ddl,p.oid::regprocedure::text identity from pg_proc p join pg_language l on l.oid=p.prolang where p.pronamespace='public'::regnamespace and p.prokind='f' and p.prorettype<>'trigger'::regtype and l.lanname in ('sql','plpgsql') and(has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE')) and p.proname !~ '^get_.*_version$' and p.proname not in ('get_my_office_access_v1','greenloop_network_allowed_v1','greenloop_office_pre_request','get_office_gateway_probe_v1','get_my_partner_name_access','is_initial_qc_service','get_office_create_context_v1','initialize_user_office_access_v1') and p.oid is distinct from(select to_regprocedure(identity||'()')::oid from greenloop_private.office_previous_hook where singleton) and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e') loop
  if strpos(f.prosrc,'greenloop-office-wrapper-196')>0 then continue;end if;
  if f.proowner<>current_user::regrole then raise exception 'Routine owner requires review: %',f.identity;end if;
  if not f.prosecdef then raise exception 'Invoker routine requires review: %',f.identity;end if;
  if f.provariadic<>0 or(f.proargmodes is not null and 'b'::"char"=any(f.proargmodes)) then raise exception 'Unsupported public routine requires review: %',f.identity;end if;
  impl:='office_impl_'||f.oid;ddl:=regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');execute ddl;
  impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';
  execute format('revoke all on function %s from public,anon,authenticated',impl_identity);
  select coalesce(string_agg('$'||i,',' order by i),'') into arguments from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n '||case when f.proretset then 'return query select * from ' when f.prorettype='void'::regtype then 'perform ' else 'return ' end||'greenloop_private.'||impl||'('||arguments||E');\nend;';
  execute format('create or replace function public.%I(%s) returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 'i' then 'stable' when 's' then 'stable' else 'volatile' end,body);
  insert into greenloop_private.office_routines values(f.identity,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid))) on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;end;$wrap$;

do $receipts$
declare t record;idcol text;hashcol text;
begin
 for t in select c.oid,c.relname from pg_class c where c.relnamespace='greenloop_private'::regnamespace and c.relkind='r' and c.relname not like 'office_%' loop
  select case when exists(select 1 from pg_attribute where attrelid=t.oid and attname='object_identity') then 'object_identity' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='function_identity') then 'function_identity' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='identity') then 'identity' end into idcol;
  select case when exists(select 1 from pg_attribute where attrelid=t.oid and attname='definition_hash') then 'definition_hash' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='hash') then 'hash' end into hashcol;
  if idcol is not null and hashcol is not null then
   execute format('update greenloop_private.%I receipt set %I=md5(pg_get_functiondef(to_regprocedure(r.identity))) from greenloop_private.office_routines r where (case when receipt.%I like ''%%(%%'' then to_regprocedure(receipt.%I) else null end)=to_regprocedure(r.identity)',t.relname,hashcol,idcol,idcol);
  end if;
 end loop;
 update greenloop_private.capability_routines c set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(c.identity))) from greenloop_private.office_routines o where to_regprocedure(c.identity)=to_regprocedure(o.identity);
 update greenloop_private.login_activity_installation set definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['public.get_login_activity_access_v1()','public.touch_login_activity_v1(text,text,boolean)','public.get_login_activity_v1(text,date,date,integer,integer,bigint)']) signature);
 update greenloop_private.manual_damage_export_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_export_v1(date,date)'::regprocedure));
 update greenloop_private.damage_live_details_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v3(integer,integer,integer)'::regprocedure));
 update greenloop_private.damage_tv_polish_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v5(integer,integer,integer)'::regprocedure));
 update greenloop_private.damage_tv_summary_installation set definition_hash=md5(pg_get_functiondef('public.get_damage_tv_summary_v1(text,integer,integer)'::regprocedure));
 update greenloop_private.damage_employee_totals_installation set definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['greenloop_private.manual_damage_employee_value(uuid)','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','public.get_manual_damage_cards_v4(integer,integer,integer)']) signature);
end;
$receipts$;

-- These three schema fingerprints include the deliberately added damage RLS boundary.
update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema() where object_kind='schema' and object_identity='manual_damage_management_schema';
update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema() where object_kind='schema' and object_identity='manual_damage_price_schema';
update greenloop_private.manual_damage_quantity_installation set definition_hash=greenloop_private.manual_damage_quantity_schema() where object_kind='schema' and object_identity='manual_damage_quantity_schema';

-- New function ACLs and installation receipt.
do $$declare f record;begin for f in select p.oid::regprocedure signature,n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where(n.nspname='greenloop_private' and(p.proname like 'office_%' or p.proname in ('set_office_user','require_office_network'))) or(n.nspname='public' and p.proname in ('greenloop_network_allowed_v1','greenloop_office_pre_request','get_office_gateway_probe_v1','get_my_office_access_v1','get_office_access_settings_v1','save_office_network_v1','save_user_access_office_v1','get_office_create_context_v1','initialize_user_office_access_v1')) loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 if f.nspname='public' then execute format('grant execute on function %s to %s',f.signature,case when f.proname in ('get_office_create_context_v1','initialize_user_office_access_v1') then 'service_role' when f.proname in ('greenloop_network_allowed_v1','greenloop_office_pre_request','get_office_gateway_probe_v1') then 'anon,authenticated,service_role' else 'authenticated' end);end if;
end loop;end;$$;
insert into greenloop_private.office_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where(n.nspname='greenloop_private' and p.proname in ('office_mode','office_service','office_request_ip','office_ip_allowed','office_admin','set_office_user','require_office_network')) or(n.nspname='public' and p.proname in ('greenloop_network_allowed_v1','greenloop_office_pre_request','get_office_gateway_probe_v1','get_my_office_access_v1','get_office_access_settings_v1','save_office_network_v1','save_user_access_office_v1','get_office_create_context_v1','initialize_user_office_access_v1')) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_office_access_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_dual_imei_version()='20261023-dual-imei-1'
 and exists(select 1 from pg_db_role_setting s cross join lateral unnest(s.setconfig)v where s.setrole='authenticator'::regrole and s.setdatabase=0 and v='pgrst.db_pre_request=public.greenloop_office_pre_request')
 and(select count(*)=16 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.office_installation)
 and not exists(select 1 from greenloop_private.office_routines where wrapped_hash<>md5(pg_get_functiondef(to_regprocedure(identity))) or original_hash<>md5(pg_get_functiondef(to_regprocedure(implementation))) or has_function_privilege('authenticated',to_regprocedure(implementation),'EXECUTE') or has_function_privilege('anon',to_regprocedure(implementation),'EXECUTE'))

 and not exists(select 1 from pg_proc p join pg_language l on l.oid=p.prolang where p.pronamespace='public'::regnamespace and p.prokind='f' and p.prorettype<>'trigger'::regtype and l.lanname in ('sql','plpgsql') and(has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE')) and p.proname !~ '^get_.*_version$' and p.proname not in ('get_my_office_access_v1','greenloop_network_allowed_v1','greenloop_office_pre_request','get_office_gateway_probe_v1','get_my_partner_name_access','is_initial_qc_service') and p.oid is distinct from(select to_regprocedure(identity||'()')::oid from greenloop_private.office_previous_hook where singleton) and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e') and not exists(select 1 from greenloop_private.office_routines r where to_regprocedure(r.identity)=p.oid))
 and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and c.relrowsecurity and (n.nspname='public' or(n.nspname='storage' and c.relname='objects')) and c.relname<>'workflow_notification_signal' and not exists(select 1 from pg_policy p where p.polrelid=c.oid and p.polname='greenloop_office_boundary' and not p.polpermissive and p.polcmd='*' and strpos(pg_get_expr(p.polqual,p.polrelid),'greenloop_network_allowed_v1')>0 and strpos(pg_get_expr(p.polwithcheck,p.polrelid),'greenloop_network_allowed_v1')>0))
 and not exists(select 1 from greenloop_private.office_views where to_regclass(identity) is null or wrapped_hash<>md5(pg_get_viewdef(to_regclass(identity),true)) or original_hash<>md5(original_query))
 and not exists(select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='v' and (has_table_privilege('anon',c.oid,'SELECT') or has_table_privilege('authenticated',c.oid,'SELECT')) and not exists(select 1 from greenloop_private.office_views v where to_regclass(v.identity)=c.oid))
 then '20261024-office-access-1' end;$$;
revoke all on function public.get_office_access_version() from public;grant execute on function public.get_office_access_version() to anon,authenticated;
do $$begin if public.get_office_access_version() is distinct from '20261024-office-access-1' then raise exception 'Office access installation verification failed.';end if;end;$$;
notify pgrst,'reload config';notify pgrst,'reload schema';commit;
select public.get_office_access_version() as installed_office_access_version;
