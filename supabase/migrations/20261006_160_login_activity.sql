-- Login Activity: server-owned identity/time, private history, Super Admin reads only.
begin;
do $preflight$ begin
 if to_regclass('auth.sessions') is null then raise exception 'Supabase auth.sessions is required.'; end if;
 if to_regprocedure('public.get_login_activity_version()') is not null then
  if public.get_login_activity_version() is distinct from '20261006-login-activity-1' then raise exception 'Login Activity differs from the expected installation.'; end if;
 elsif to_regclass('greenloop_private.login_activity_sessions') is not null or to_regprocedure('public.touch_login_activity_v1(text,text,boolean)') is not null then
  raise exception 'Unexpected Login Activity objects; installation stopped.';
 end if;
end; $preflight$;
create schema if not exists greenloop_private;
create table if not exists greenloop_private.login_activity_installation (
 singleton boolean primary key default true check(singleton), installed_at timestamptz not null default clock_timestamp(), definition_hash text not null default ''
);
insert into greenloop_private.login_activity_installation(singleton) values(true) on conflict do nothing;
create table if not exists greenloop_private.login_activity_sessions (
 id bigint generated always as identity primary key,
 session_id uuid not null unique, user_id uuid not null,
 full_name text not null, username text not null,
 login_at timestamptz not null, first_seen timestamptz not null default clock_timestamp(), last_seen timestamptz not null default clock_timestamp(), logged_out_at timestamptz,
 device_type text not null, browser text not null, login_surface text not null, last_surface text not null, last_page text not null,
 is_new_login boolean not null
);
create index if not exists login_activity_user_time on greenloop_private.login_activity_sessions(user_id,login_at desc);
create index if not exists login_activity_time on greenloop_private.login_activity_sessions(login_at desc,id desc);
alter table greenloop_private.login_activity_sessions enable row level security;
alter table greenloop_private.login_activity_installation enable row level security;
revoke all on greenloop_private.login_activity_sessions,greenloop_private.login_activity_installation from public,anon,authenticated;
revoke all on sequence greenloop_private.login_activity_sessions_id_seq from public,anon,authenticated;

create or replace function public.get_login_activity_access_v1()
returns boolean language sql stable security definer set search_path=pg_catalog,public as $access$
 select exists(select 1 from public.user_profiles p join public.user_roles ur on ur.user_id=p.id join public.roles r on r.id=ur.role_id
 where p.id=auth.uid() and p.is_active and r.role_key='super_admin')
 and exists(select 1 from auth.sessions s where s.id::text=auth.jwt()->>'session_id' and s.user_id=auth.uid()
 and (to_jsonb(s)->>'not_after' is null or (to_jsonb(s)->>'not_after')::timestamptz>now()));
$access$;

create or replace function public.touch_login_activity_v1(p_surface text,p_page text,p_end boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $touch$
declare v_user uuid:=auth.uid();v_session uuid;v_login timestamptz;v_ua text;v_device text;v_browser text;v_name text;v_username text;v_now timestamptz:=clock_timestamp();
begin
 if v_user is null then raise exception 'Sign in required.' using errcode='42501'; end if;
 begin v_session:=(auth.jwt()->>'session_id')::uuid; exception when invalid_text_representation then v_session:=null; end;
 if v_session is null then raise exception 'Authenticated session required.' using errcode='42501'; end if;
 if p_end then
  update greenloop_private.login_activity_sessions set logged_out_at=coalesce(logged_out_at,v_now) where session_id=v_session and user_id=v_user;
  return jsonb_build_object('ok',true);
 end if;
 if p_surface is null or p_surface not in ('Software','Damage TV','Lab TV') or p_page is null or p_page!~'^[a-z0-9-]{1,60}\.html$' then raise exception 'Invalid activity source.' using errcode='22023'; end if;
 select coalesce(nullif(btrim(full_name),''),nullif(login_username,''),'Staff'),coalesce(login_username,'') into v_name,v_username
 from public.user_profiles where id=v_user and is_active;
 if not found then raise exception 'Active account required.' using errcode='42501'; end if;
 select s.created_at into v_login from auth.sessions s where s.id=v_session and s.user_id=v_user
 and (to_jsonb(s)->>'not_after' is null or (to_jsonb(s)->>'not_after')::timestamptz>v_now);
 if not found then raise exception 'Session no longer active.' using errcode='42501'; end if;
 v_ua:=left(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'user-agent',''),600);
 v_device:=case when v_ua~*'(smart-tv|smarttv|tizen|web0s|webos|hbbtv|netcast)' then 'TV' when v_ua~*'(ipad|tablet)' then 'Tablet' when v_ua~*'(mobile|iphone|android)' then 'Mobile' when v_ua='' then 'Unknown' else 'Computer' end;
 v_browser:=case when v_ua~*'(samsungbrowser|tizen)' then 'Samsung browser' when v_ua~*'(edg/|edge/|edgios|edga/)' then 'Edge' when v_ua~*'(opr/|opera)' then 'Opera' when v_ua~*'(firefox|fxios)' then 'Firefox' when v_ua~*'(chrome|crios)' then 'Chrome' when v_ua~*'safari' then 'Safari' else 'Other browser' end;
 -- Serialize first observations so a new-session alert cursor cannot overtake
 -- another new session whose insert has not committed yet. Heartbeats skip it.
 if not exists(select 1 from greenloop_private.login_activity_sessions where session_id=v_session) then
  perform pg_advisory_xact_lock(160,61006);
 end if;
 insert into greenloop_private.login_activity_sessions(session_id,user_id,full_name,username,login_at,last_seen,device_type,browser,login_surface,last_surface,last_page,is_new_login)
 values(v_session,v_user,v_name,v_username,coalesce(v_login,v_now),v_now,v_device,v_browser,p_surface,p_surface,p_page,
 coalesce(v_login,v_now)>=(select installed_at from greenloop_private.login_activity_installation where singleton))
 on conflict(session_id) do update set last_seen=excluded.last_seen,last_surface=excluded.last_surface,last_page=excluded.last_page
 where login_activity_sessions.user_id=v_user and login_activity_sessions.logged_out_at is null and login_activity_sessions.last_seen < v_now-interval '5 seconds';
 return jsonb_build_object('ok',true);
end;
$touch$;

create or replace function public.get_login_activity_v1(p_search text default '',p_from date default null,p_to date default null,p_offset integer default 0,p_limit integer default 25,p_after_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $read$
declare v_rows jsonb;v_count bigint;v_alerts jsonb;v_cursor bigint;v_active bigint;v_installed timestamptz;
begin
 if not public.get_login_activity_access_v1() then raise exception 'Only Super Admin can view Login Activity.' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 or length(coalesce(p_search,''))>100 or (p_from is not null and p_to is not null and p_from>p_to) or p_after_id<0 then raise exception 'Invalid login activity filter.' using errcode='22023'; end if;
 select installed_at into v_installed from greenloop_private.login_activity_installation where singleton;
 select coalesce(max(id),0) into v_cursor from greenloop_private.login_activity_sessions;
 select count(*) into v_count from greenloop_private.login_activity_sessions a
 where (coalesce(p_search,'')='' or position(lower(p_search) in lower(a.full_name||' '||a.username))>0)
 and (p_from is null or a.login_at >= p_from::timestamp at time zone 'Asia/Dubai') and (p_to is null or a.login_at < (p_to+1)::timestamp at time zone 'Asia/Dubai');
 select coalesce(jsonb_agg(item order by login_at desc,id desc),'[]'::jsonb) into v_rows from (
 select a.login_at,a.id,jsonb_build_object('id',a.id::text,'name',a.full_name,'username',a.username,'login_at',a.login_at,'first_seen',a.first_seen,'last_seen',a.last_seen,'logout_at',a.logged_out_at,
 'device',a.device_type,'browser',a.browser,'login_surface',a.login_surface,'last_surface',a.last_surface,'last_page',a.last_page,'existing_session',not a.is_new_login,
 'status',case when a.logged_out_at is not null then 'Signed out' when not coalesce(p.is_active,false) or s.id is null or (to_jsonb(s)->>'not_after')::timestamptz<=now() then 'Offline'
 when a.last_seen>=now()-interval '90 seconds' then 'Recently active' else 'Offline' end) item
 from greenloop_private.login_activity_sessions a left join auth.sessions s on s.id=a.session_id and s.user_id=a.user_id left join public.user_profiles p on p.id=a.user_id
 where (coalesce(p_search,'')='' or position(lower(p_search) in lower(a.full_name||' '||a.username))>0)
 and (p_from is null or a.login_at >= p_from::timestamp at time zone 'Asia/Dubai') and (p_to is null or a.login_at < (p_to+1)::timestamp at time zone 'Asia/Dubai')
 order by a.login_at desc,a.id desc offset p_offset limit p_limit) rows;
 select count(distinct a.user_id) into v_active from greenloop_private.login_activity_sessions a join auth.sessions s on s.id=a.session_id and s.user_id=a.user_id join public.user_profiles p on p.id=a.user_id and p.is_active
 where a.logged_out_at is null and a.last_seen>=now()-interval '90 seconds' and (to_jsonb(s)->>'not_after' is null or (to_jsonb(s)->>'not_after')::timestamptz>now());
 if p_after_id is null then v_alerts:='[]'::jsonb;
 else
  select coalesce(jsonb_agg(jsonb_build_object('id',id::text,'name',full_name,'username',username,'login_at',login_at,'device',device_type,'surface',login_surface) order by id),'[]'::jsonb),coalesce(max(id),p_after_id)
  into v_alerts,v_cursor from (select * from greenloop_private.login_activity_sessions where id>p_after_id and is_new_login order by id limit 50) alerts;
 end if;
 return jsonb_build_object('rows',v_rows,'total_count',v_count,'active_users',v_active,'has_more',p_offset::bigint+p_limit<v_count,'alerts',v_alerts,'cursor',v_cursor::text,'server_time',now(),'installed_at',v_installed);
end;
$read$;
revoke all on function public.get_login_activity_access_v1(),public.touch_login_activity_v1(text,text,boolean),public.get_login_activity_v1(text,date,date,integer,integer,bigint) from public,anon;
grant execute on function public.get_login_activity_access_v1(),public.touch_login_activity_v1(text,text,boolean),public.get_login_activity_v1(text,date,date,integer,integer,bigint) to authenticated;
update greenloop_private.login_activity_installation set definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['public.get_login_activity_access_v1()','public.touch_login_activity_v1(text,text,boolean)','public.get_login_activity_v1(text,date,date,integer,integer,bigint)']) signature);
create or replace function public.get_login_activity_version() returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when exists(select 1 from greenloop_private.login_activity_installation where definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['public.get_login_activity_access_v1()','public.touch_login_activity_v1(text,text,boolean)','public.get_login_activity_v1(text,date,date,integer,integer,bigint)']) signature))
 and not has_table_privilege('authenticated','greenloop_private.login_activity_sessions','SELECT,INSERT,UPDATE,DELETE')
 and not has_table_privilege('anon','greenloop_private.login_activity_sessions','SELECT,INSERT,UPDATE,DELETE')
 and not has_function_privilege('anon','public.get_login_activity_v1(text,date,date,integer,integer,bigint)','EXECUTE')
 then '20261006-login-activity-1' else null end;
$version$;
revoke all on function public.get_login_activity_version() from public;
grant execute on function public.get_login_activity_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_login_activity_version() as installed_login_activity_version;
