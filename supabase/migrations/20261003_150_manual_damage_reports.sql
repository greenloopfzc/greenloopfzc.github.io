-- Manual incidents are independent audit records: never inferred from IMEI,
-- parts, QC or technician performance. Operational resets preserve this table.
-- Removing manual incident history requires a separate, explicit future change.
begin;
create schema if not exists greenloop_private;

create table if not exists public.manual_damage_reports (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null,
 reported_by_user_id uuid not null,
 reported_by text not null,
 damaged_by text not null check (char_length(damaged_by) between 1 and 120),
 model text not null check (char_length(model) between 1 and 160),
 identifier text check (identifier is null or char_length(identifier) between 1 and 120),
 damage text not null check (char_length(damage) between 1 and 300),
 reason text not null check (char_length(reason) between 1 and 2000),
 occurred_at timestamptz not null check (isfinite(occurred_at)),
 created_at timestamptz not null default now(),
 unique (reported_by_user_id, request_id)
);
comment on table public.manual_damage_reports is
 'Immutable manually reported damage incidents. No operational or user foreign keys; preserved by operational resets. Does not change existing damage/performance statistics.';
create index if not exists manual_damage_reports_recent
 on public.manual_damage_reports(occurred_at desc,id desc);
alter table public.manual_damage_reports enable row level security;
revoke all on public.manual_damage_reports from public,anon,authenticated;

create or replace function greenloop_private.manual_damage_access(p_edit boolean default false)
returns boolean language sql stable security definer
set search_path=pg_catalog,public as $access$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false)
  and coalesce((select case when p_edit then p.access_level='edit'
     else p.access_level in ('view','edit') end
    from public.user_page_permissions p
    where p.user_id=auth.uid() and p.page_key='lab_live_board'),
   public.has_role(array['owner','super_admin']::public.app_role_key[]),false);
$access$;
revoke all on function greenloop_private.manual_damage_access(boolean) from public,anon,authenticated;

create or replace function greenloop_private.prevent_manual_damage_changes()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public as $immutable$
begin
 raise exception 'Manual damage reports are permanent audit records.' using errcode='42501';
end;
$immutable$;
revoke all on function greenloop_private.prevent_manual_damage_changes() from public,anon,authenticated;
drop trigger if exists manual_damage_reports_immutable on public.manual_damage_reports;
create trigger manual_damage_reports_immutable before update or delete
 on public.manual_damage_reports for each row
 execute function greenloop_private.prevent_manual_damage_changes();

create or replace function public.create_manual_damage_report_v1(
 p_request_id uuid,p_damaged_by text,p_model text,p_identifier text,
 p_damage text,p_reason text,p_occurred_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $create$
declare
 v_actor uuid:=auth.uid();
 v_damaged_by text:=btrim(coalesce(p_damaged_by,''),E' \t\n\r\f');
 v_model text:=btrim(coalesce(p_model,''),E' \t\n\r\f');
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_damage text:=btrim(coalesce(p_damage,''),E' \t\n\r\f');
 v_reason text:=btrim(coalesce(p_reason,''),E' \t\n\r\f');
 v_reported_by text;
 v_row public.manual_damage_reports%rowtype;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'Lab Live Board edit permission is required to record manual damage.' using errcode='42501';
 end if;
 if p_request_id is null then
  raise exception 'A request ID is required.' using errcode='22023';
 end if;
 if char_length(v_damaged_by) not between 1 and 120 then
  raise exception 'Damaged by is required and must be at most 120 characters.' using errcode='22023';
 end if;
 if char_length(v_model) not between 1 and 160 then
  raise exception 'Model is required and must be at most 160 characters.' using errcode='22023';
 end if;
 if char_length(v_identifier)>120 then
  raise exception 'Identifier must be at most 120 characters.' using errcode='22023';
 end if;
 if char_length(v_damage) not between 1 and 300 then
  raise exception 'Damage is required and must be at most 300 characters.' using errcode='22023';
 end if;
 if char_length(v_reason) not between 1 and 2000 then
  raise exception 'Reason is required and must be at most 2000 characters.' using errcode='22023';
 end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 select coalesce(nullif(btrim(u.full_name),''),nullif(btrim(u.login_username),''),'Staff')
 into v_reported_by from public.user_profiles u where u.id=v_actor;

 -- The unique actor/request pair serializes concurrent retries. Never use an
 -- upsert that changes the first incident or its original submitter snapshot.
 insert into public.manual_damage_reports(request_id,reported_by_user_id,reported_by,
  damaged_by,model,identifier,damage,reason,occurred_at)
 values(p_request_id,v_actor,coalesce(v_reported_by,'Staff'),
  v_damaged_by,v_model,v_identifier,v_damage,v_reason,p_occurred_at)
 on conflict(reported_by_user_id,request_id) do nothing
 returning * into v_row;
 if not found then
  select * into strict v_row from public.manual_damage_reports
  where reported_by_user_id=v_actor and request_id=p_request_id;
  if row(v_row.damaged_by,v_row.model,v_row.identifier,v_row.damage,v_row.reason,v_row.occurred_at)
    is distinct from row(v_damaged_by,v_model,v_identifier,v_damage,v_reason,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
 end if;
 return to_jsonb(v_row)-'request_id'-'reported_by_user_id';
end;
$create$;
revoke all on function public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz) from public,anon;
grant execute on function public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz) to authenticated;

create or replace function public.get_manual_damage_report_v1(p_offset integer default 0,p_limit integer default 8)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $read$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,8),100));
 v_today date:=(now() at time zone 'Asia/Dubai')::date;
 v_month timestamp:=date_trunc('month',now() at time zone 'Asia/Dubai');
 v_today_count bigint; v_month_count bigint; v_total_count bigint;
 v_rows jsonb; v_technicians jsonb;
begin
 if not greenloop_private.manual_damage_access() then
  raise exception 'Lab Live Board view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*),
  count(*) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai'
   and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),
  count(*) filter(where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai')
 into v_total_count,v_today_count,v_month_count from public.manual_damage_reports;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.count desc,lower(t.damaged_by),t.damaged_by),'[]'::jsonb)
 into v_technicians from (
  select damaged_by,count(*) as count from public.manual_damage_reports
  where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai'
  group by damaged_by
 ) t;
 select coalesce(jsonb_agg(to_jsonb(r)-'request_id'-'reported_by_user_id'
  order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select * from public.manual_damage_reports order by occurred_at desc,id desc
  offset v_offset limit v_limit) r;
 return jsonb_build_object('today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'technicians',v_technicians,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_total_count);
end;
$read$;
revoke all on function public.get_manual_damage_report_v1(integer,integer) from public,anon;
grant execute on function public.get_manual_damage_report_v1(integer,integer) to authenticated;

create table if not exists greenloop_private.manual_damage_report_installation(
 function_identity text primary key,definition_hash text not null);
revoke all on greenloop_private.manual_damage_report_installation from public,anon,authenticated;
insert into greenloop_private.manual_damage_report_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p
where p.oid in ('greenloop_private.manual_damage_access(boolean)'::regprocedure,
 'greenloop_private.prevent_manual_damage_changes()'::regprocedure,
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.get_manual_damage_report_v1(integer,integer)'::regprocedure)
on conflict(function_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_manual_damage_report_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when (select count(*)=4 and bool_and(
  to_regprocedure(i.function_identity) is not null and
  md5(pg_get_functiondef(to_regprocedure(i.function_identity)))=i.definition_hash)
  from greenloop_private.manual_damage_report_installation i)
 and exists(select 1 from pg_class where oid='public.manual_damage_reports'::regclass and relrowsecurity)
 and exists(select 1 from pg_trigger where tgrelid='public.manual_damage_reports'::regclass
  and tgname='manual_damage_reports_immutable' and tgenabled='O')
 and not has_table_privilege('authenticated','public.manual_damage_reports','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','public.manual_damage_reports','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)','EXECUTE')
 and not has_function_privilege('anon','public.get_manual_damage_report_v1(integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_report_v1(integer,integer)','EXECUTE')
 then '20261003-manual-damage-1' end;
$version$;
revoke all on function public.get_manual_damage_report_version() from public;
grant execute on function public.get_manual_damage_report_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_manual_damage_report_version() as installed_manual_damage_report_version;
