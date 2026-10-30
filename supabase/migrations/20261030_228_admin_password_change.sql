-- Passwords stay in Supabase Auth. This ledger stores actor/target/outcome only,
-- plus a service-keyed request fingerprint, never a password or password hash.
begin;
do $$begin if public.get_stock_parts_cost_version()is distinct from '20261030-stock-parts-cost-1'then raise exception 'Install verified Stock Parts Cost first.';end if;end;$$;
create table if not exists greenloop_private.admin_password_requests(actor uuid not null,request_id uuid not null,target uuid not null,username text not null,fingerprint text not null check(fingerprint~'^[a-f0-9]{64}$'),status text not null check(status in('pending','confirmed','failed')),created_at timestamptz not null default now(),finished_at timestamptz,error_code text,primary key(actor,request_id));
create index if not exists admin_password_requests_actor_time on greenloop_private.admin_password_requests(actor,created_at desc);
create index if not exists admin_password_requests_target_time on greenloop_private.admin_password_requests(target,created_at desc);
create table if not exists greenloop_private.admin_password_audit(id uuid primary key default gen_random_uuid(),actor uuid not null,target uuid not null,request_id uuid not null,username text not null,outcome text not null check(outcome in('requested','confirmed','failed','reveal_requested','created_password_saved')),occurred_at timestamptz not null default now(),error_code text);
create table if not exists greenloop_private.admin_password_vault(user_id uuid primary key,actor uuid not null,request_id uuid not null,username text not null,ciphertext text not null,nonce text not null,key_id text not null,auth_password_fingerprint text not null,recorded_at timestamptz not null default now());
alter table greenloop_private.admin_password_vault enable row level security;revoke all on greenloop_private.admin_password_vault from public,anon,authenticated,service_role;
alter table greenloop_private.admin_password_requests enable row level security;alter table greenloop_private.admin_password_audit enable row level security;revoke all on greenloop_private.admin_password_requests,greenloop_private.admin_password_audit from public,anon,authenticated,service_role;
create or replace function greenloop_private.apw_immutable()returns trigger language plpgsql set search_path=pg_catalog as $$begin raise exception 'Password change audit is permanent.'using errcode='55000';end;$$;
drop trigger if exists admin_password_audit_immutable on greenloop_private.admin_password_audit;create trigger admin_password_audit_immutable before update or delete on greenloop_private.admin_password_audit for each row execute function greenloop_private.apw_immutable();
create or replace function greenloop_private.apw_guard(p_actor uuid,p_target uuid,p_expected_username text,p_client_ip text)returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$declare ip inet;caps jsonb;is_super boolean;username text;begin
 if not greenloop_private.office_service()then raise exception 'Service role required.'using errcode='42501';end if;
 if p_actor is null or p_target is null then raise exception 'Choose a valid account.'using errcode='22023';end if;
 begin if p_client_ip is null or p_client_ip~'[,/ %]'then ip:=null;else ip:=p_client_ip::inet;end if;exception when others then ip:=null;end;
 caps:=greenloop_private.user_capabilities(p_actor);
 if not exists(select 1 from public.user_profiles where id=p_actor and is_active)or greenloop_private.damage_tv_only(p_actor)or not exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_actor and r.role_key::text in('owner','super_admin'))or not exists(select 1 from public.user_page_permissions where user_id=p_actor and page_key='user_access'and access_level='edit')or not coalesce(caps->'user_access'?'view',false)or not coalesce(caps->'user_access'?'manage_access',false)then raise exception 'Administrator role and Edit users & permissions access are required.'using errcode='42501';end if;
 if greenloop_private.office_mode(p_actor)='office'and not greenloop_private.office_ip_allowed(ip)then raise exception 'Office access only. Connect to the approved office network.'using errcode='42501';end if;
 select exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_actor and r.role_key::text='super_admin')into is_super;
 if not is_super and p_target<>p_actor and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_target and r.role_key::text in('owner','super_admin'))then raise exception 'Only Super Admin can change another administrator password.'using errcode='42501';end if;
 select coalesce(login_username,'')into username from public.user_profiles where id=p_target;
 if not found then raise exception 'The selected account no longer exists. Refresh the users list.'using errcode='22023';end if;
 if p_expected_username is not null and p_expected_username is distinct from username then raise exception 'This username changed. Refresh the users list before changing its password.'using errcode='40001';end if;
 return username;
end;$$;
create or replace function public.reserve_admin_password_change_v1(p_actor uuid,p_target uuid,p_expected_username text,p_client_ip text,p_request_id uuid,p_fingerprint text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare username text;r greenloop_private.admin_password_requests%rowtype;begin
 username:=greenloop_private.apw_guard(p_actor,p_target,p_expected_username,p_client_ip);
 if p_request_id is null or p_expected_username is null or p_fingerprint is null or p_fingerprint!~'^[a-f0-9]{64}$'then raise exception 'Valid password request required.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-password-actor:'||p_actor::text,0));perform pg_advisory_xact_lock(hashtextextended('admin-password-target:'||p_target::text,0));
 select *into r from greenloop_private.admin_password_requests where actor=p_actor and request_id=p_request_id;
 if found then if r.target<>p_target or r.fingerprint<>p_fingerprint or r.username<>p_expected_username then raise exception 'This request belongs to a different password change.'using errcode='22023';end if;return jsonb_build_object('status',r.status,'request_id',r.request_id,'user_id',r.target,'username',r.username);end if;
 if exists(select 1 from greenloop_private.admin_password_requests where target=p_target and status='pending'and created_at>now()-interval '5 minutes')then raise exception 'A password change for this account is still pending. Check its status before trying again.'using errcode='55000';end if;
 if(select count(*)from greenloop_private.admin_password_requests where actor=p_actor and created_at>now()-interval '10 minutes')>=10 or(select count(*)from greenloop_private.admin_password_requests where target=p_target and created_at>now()-interval '10 minutes')>=5 then raise exception 'Too many password changes. Try again later.'using errcode='53300';end if;
 insert into greenloop_private.admin_password_requests(actor,request_id,target,username,fingerprint,status)values(p_actor,p_request_id,p_target,username,p_fingerprint,'pending');
 insert into greenloop_private.admin_password_audit(actor,target,request_id,username,outcome)values(p_actor,p_target,p_request_id,username,'requested');
 return jsonb_build_object('status','apply','request_id',p_request_id,'user_id',p_target,'username',username);
end;$$;
create or replace function public.finish_admin_password_change_v1(p_actor uuid,p_target uuid,p_request_id uuid,p_fingerprint text,p_status text,p_error_code text default null,p_ciphertext text default null,p_nonce text default null,p_key_id text default null,p_auth_updated_at timestamptz default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare r greenloop_private.admin_password_requests%rowtype;auth_fingerprint text;begin
 if not greenloop_private.office_service()then raise exception 'Service role required.'using errcode='42501';end if;
 if p_status is null or p_status not in('confirmed','failed')or p_error_code is not null and p_error_code not in('auth_rejected','unexpected_result')then raise exception 'Valid password outcome required.'using errcode='22023';end if;
 select *into r from greenloop_private.admin_password_requests where actor=p_actor and request_id=p_request_id for update;
 if not found or r.target is distinct from p_target or r.fingerprint is distinct from p_fingerprint then raise exception 'Password request could not be verified.'using errcode='22023';end if;
 if r.status<>'pending'and r.status<>p_status then raise exception 'This password request already has a different outcome.'using errcode='55000';end if;
 if r.status='pending'then
 if p_status='confirmed'then
  if p_ciphertext is null or length(p_ciphertext)not between 24 and 160 or p_ciphertext!~'^[A-Za-z0-9+/]+={0,2}$'or p_nonce is null or p_nonce!~'^[A-Za-z0-9+/]{16}$'or p_key_id is null or p_key_id!~'^[a-f0-9]{16}$'or p_auth_updated_at is null then raise exception 'Encrypted password confirmation is required.'using errcode='22023';end if;
  select md5(encrypted_password)into auth_fingerprint from auth.users where id=p_target and updated_at=p_auth_updated_at and nullif(encrypted_password,'')is not null;
  if auth_fingerprint is null then raise exception 'The Auth password changed before confirmation. Refresh and check status.'using errcode='40001';end if;
  insert into greenloop_private.admin_password_vault(user_id,actor,request_id,username,ciphertext,nonce,key_id,auth_password_fingerprint)values(p_target,p_actor,p_request_id,r.username,p_ciphertext,p_nonce,p_key_id,auth_fingerprint)on conflict(user_id)do update set actor=excluded.actor,request_id=excluded.request_id,username=excluded.username,ciphertext=excluded.ciphertext,nonce=excluded.nonce,key_id=excluded.key_id,auth_password_fingerprint=excluded.auth_password_fingerprint,recorded_at=now();
 elsif p_ciphertext is not null or p_nonce is not null or p_key_id is not null or p_auth_updated_at is not null then raise exception 'Failed requests cannot replace a saved password.'using errcode='22023';end if;
 update greenloop_private.admin_password_requests set status=p_status,finished_at=now(),error_code=p_error_code where actor=p_actor and request_id=p_request_id;
 insert into greenloop_private.admin_password_audit(actor,target,request_id,username,outcome,error_code)values(p_actor,p_target,p_request_id,r.username,p_status,p_error_code);
 end if;
 return jsonb_build_object('status',p_status,'request_id',p_request_id,'user_id',p_target,'username',r.username);
end;$$;
create or replace function public.get_admin_password_change_status_v1(p_actor uuid,p_target uuid,p_request_id uuid,p_client_ip text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r greenloop_private.admin_password_requests%rowtype;begin
 perform greenloop_private.apw_guard(p_actor,p_target,null,p_client_ip);
 select *into r from greenloop_private.admin_password_requests where actor=p_actor and target=p_target and request_id=p_request_id;
 if not found then return jsonb_build_object('status','not_started','request_id',p_request_id,'user_id',p_target);end if;
 return jsonb_build_object('status',r.status,'request_id',r.request_id,'user_id',r.target,'username',r.username);
end;$$;
create or replace function public.get_admin_password_visibility_v1(p_actor uuid,p_target uuid,p_client_ip text,p_reveal boolean default false,p_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare username text;v greenloop_private.admin_password_vault%rowtype;available boolean;begin
 username:=greenloop_private.apw_guard(p_actor,p_target,null,p_client_ip);
 select *into v from greenloop_private.admin_password_vault where user_id=p_target;
 available:=v.user_id is not null and v.auth_password_fingerprint=(select md5(encrypted_password)from auth.users where id=p_target);
 if not coalesce(available,false)then return jsonb_build_object('user_id',p_target,'username',username,'available',false,'reason',case when v.user_id is null then 'not_recorded'else 'changed_elsewhere'end);end if;
 if p_reveal is true then
  if p_request_id is null then raise exception 'Valid password view request required.'using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('password-reveal:'||p_actor::text,0));
  if(select count(*)from greenloop_private.admin_password_audit where actor=p_actor and outcome='reveal_requested'and occurred_at>now()-interval '10 minutes')>=20 then raise exception 'Too many password views. Try again later.'using errcode='53300';end if;
  insert into greenloop_private.admin_password_audit(actor,target,request_id,username,outcome)values(p_actor,p_target,p_request_id,username,'reveal_requested');
  return jsonb_build_object('user_id',p_target,'username',username,'available',true,'ciphertext',v.ciphertext,'nonce',v.nonce,'key_id',v.key_id,'vault_request_id',v.request_id,'recorded_at',v.recorded_at);
 end if;
 return jsonb_build_object('user_id',p_target,'username',username,'available',true,'key_id',v.key_id,'recorded_at',v.recorded_at);
end;$$;
create or replace function public.register_created_password_v1(p_actor uuid,p_target uuid,p_username text,p_client_ip text,p_request_id uuid,p_ciphertext text,p_nonce text,p_key_id text,p_auth_updated_at timestamptz)returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare context jsonb;auth_fingerprint text;v greenloop_private.admin_password_vault%rowtype;begin
 context:=public.get_office_create_context_v1(p_actor,p_client_ip);
 if context->>'can_create'is distinct from 'true'or p_actor=p_target or not exists(select 1 from public.user_profiles where id=p_target and login_username=p_username and created_at>now()-interval '15 minutes')or not exists(select 1 from greenloop_private.user_page_capabilities where user_id=p_target and updated_by=p_actor and updated_at>now()-interval '15 minutes')then raise exception 'Only this administrator newly initialized account can receive an initial saved password.'using errcode='42501';end if;
 if p_request_id is null or p_ciphertext is null or length(p_ciphertext)not between 24 and 160 or p_ciphertext!~'^[A-Za-z0-9+/]+={0,2}$'or p_nonce is null or p_nonce!~'^[A-Za-z0-9+/]{16}$'or p_key_id is null or p_key_id!~'^[a-f0-9]{16}$'or p_auth_updated_at is null then raise exception 'Valid encrypted password required.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-password-target:'||p_target::text,0));
 select *into v from greenloop_private.admin_password_vault where user_id=p_target;
 if found then if v.actor=p_actor and v.request_id=p_request_id and v.ciphertext=p_ciphertext and v.nonce=p_nonce and v.key_id=p_key_id then return true;end if;raise exception 'This account already has a saved password.'using errcode='55000';end if;
 select md5(encrypted_password)into auth_fingerprint from auth.users where id=p_target and updated_at=p_auth_updated_at and nullif(encrypted_password,'')is not null;
 if auth_fingerprint is null then raise exception 'The Auth password changed before confirmation.'using errcode='40001';end if;
 insert into greenloop_private.admin_password_vault(user_id,actor,request_id,username,ciphertext,nonce,key_id,auth_password_fingerprint)values(p_target,p_actor,p_request_id,p_username,p_ciphertext,p_nonce,p_key_id,auth_fingerprint);
 insert into greenloop_private.admin_password_audit(actor,target,request_id,username,outcome)values(p_actor,p_target,p_request_id,p_username,'created_password_saved');return true;
end;$$;
revoke all on function greenloop_private.apw_guard(uuid,uuid,text,text),greenloop_private.apw_immutable(),public.reserve_admin_password_change_v1(uuid,uuid,text,text,uuid,text),public.finish_admin_password_change_v1(uuid,uuid,uuid,text,text,text,text,text,text,timestamptz),public.get_admin_password_change_status_v1(uuid,uuid,uuid,text),public.get_admin_password_visibility_v1(uuid,uuid,text,boolean,uuid),public.register_created_password_v1(uuid,uuid,text,text,uuid,text,text,text,timestamptz)from public,anon,authenticated,service_role;
grant execute on function public.reserve_admin_password_change_v1(uuid,uuid,text,text,uuid,text),public.finish_admin_password_change_v1(uuid,uuid,uuid,text,text,text,text,text,text,timestamptz),public.get_admin_password_change_status_v1(uuid,uuid,uuid,text),public.get_admin_password_visibility_v1(uuid,uuid,text,boolean,uuid),public.register_created_password_v1(uuid,uuid,text,text,uuid,text,text,text,timestamptz)to service_role;
create table if not exists greenloop_private.admin_password_installation(identity text primary key,hash text not null);alter table greenloop_private.admin_password_installation enable row level security;revoke all on greenloop_private.admin_password_installation from public,anon,authenticated,service_role;
create or replace function public.get_admin_password_change_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_stock_parts_cost_version()='20261030-stock-parts-cost-1'
 and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.admin_password_installation)
 and not exists(select 1 from unnest(array['public.reserve_admin_password_change_v1(uuid,uuid,text,text,uuid,text)','public.finish_admin_password_change_v1(uuid,uuid,uuid,text,text,text,text,text,text,timestamptz)','public.get_admin_password_change_status_v1(uuid,uuid,uuid,text)','public.get_admin_password_visibility_v1(uuid,uuid,text,boolean,uuid)','public.register_created_password_v1(uuid,uuid,text,text,uuid,text,text,text,timestamptz)'])f where has_function_privilege('anon',to_regprocedure(f),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(f),'EXECUTE')or not has_function_privilege('service_role',to_regprocedure(f),'EXECUTE'))
 and not exists(select 1 from unnest(array['greenloop_private.apw_guard(uuid,uuid,text,text)','greenloop_private.apw_immutable()'])f where has_function_privilege('anon',to_regprocedure(f),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(f),'EXECUTE')or has_function_privilege('service_role',to_regprocedure(f),'EXECUTE'))
 and not exists(select 1 from unnest(array['greenloop_private.admin_password_vault','greenloop_private.admin_password_requests','greenloop_private.admin_password_audit','greenloop_private.admin_password_installation'])t where not exists(select 1 from pg_class where oid=to_regclass(t)and relrowsecurity)or has_table_privilege('anon',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('service_role',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.admin_password_audit'::regclass and tgname='admin_password_audit_immutable'and tgenabled='O')then '20261030-user-password-1'end;$$;
revoke all on function public.get_admin_password_change_version()from public;grant execute on function public.get_admin_password_change_version()to anon,authenticated,service_role;
insert into greenloop_private.admin_password_installation select oid::regprocedure::text,md5(pg_get_functiondef(oid))from pg_proc where pronamespace='greenloop_private'::regnamespace and proname in('apw_guard','apw_immutable')or pronamespace='public'::regnamespace and proname in('reserve_admin_password_change_v1','finish_admin_password_change_v1','get_admin_password_change_status_v1','get_admin_password_visibility_v1','register_created_password_v1','get_admin_password_change_version')on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_admin_password_change_version()is distinct from '20261030-user-password-1'then raise exception 'Password management verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_admin_password_change_version()as installed_admin_password_change_version;
