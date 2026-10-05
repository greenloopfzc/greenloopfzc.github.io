-- Controlled manual damage corrections/removal. Original submissions, create
-- request IDs and permanent audits are retained; active histories use an overlay.
-- No operational rows, option catalogs, users or permissions are changed.
begin;
do $preflight$
begin
 if to_regprocedure('public.get_tv_damage_access_version()') is null then
  raise exception 'Install verified migration 152 before manual damage management.' using errcode='55000';
 end if;
 if public.get_tv_damage_access_version() is distinct from '20261005-tv-damage-access-1' then
  raise exception 'Manual damage predecessor verification failed; no changes installed.' using errcode='55000';
 end if;
 if (select count(*) from pg_attribute where attrelid='public.manual_damage_reports'::regclass and attnum>0 and not attisdropped)<>13
 or exists(select 1 from (values
  ('id','uuid',true),('request_id','uuid',true),('reported_by_user_id','uuid',true),('reported_by','text',true),
  ('damaged_by','text',true),('model','text',true),('identifier','text',false),('damage','text',true),('reason','text',true),
  ('occurred_at','timestamp with time zone',true),('created_at','timestamp with time zone',true),('employee_id','uuid',false),('part_name','text',false)
 ) expected(name,type_name,required) where not exists(select 1 from pg_attribute a
  where a.attrelid='public.manual_damage_reports'::regclass and a.attname=expected.name and not a.attisdropped
  and format_type(a.atttypid,a.atttypmod)=expected.type_name and a.attnotnull=expected.required))
 or not exists(select 1 from pg_trigger where tgrelid='public.manual_damage_reports'::regclass
  and tgname='manual_damage_reports_immutable' and tgenabled='O' and tgfoid='greenloop_private.prevent_manual_damage_changes()'::regprocedure)
 or exists(select 1 from pg_constraint where conrelid='public.manual_damage_reports'::regclass and contype='f') then
  raise exception 'Unexpected manual damage source schema; no changes installed.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_manual_damage_management_version()') is not null then
  if public.get_manual_damage_management_version() is distinct from '20261005-manual-damage-management-1' then
   raise exception 'Existing manual damage management verification failed; no changes installed.' using errcode='55000';
  end if;
 elsif to_regclass('greenloop_private.manual_damage_state') is not null
    or to_regclass('greenloop_private.manual_damage_operations') is not null
    or to_regclass('greenloop_private.manual_damage_audit') is not null
    or to_regclass('greenloop_private.manual_damage_effective') is not null
    or to_regclass('greenloop_private.manual_damage_management_installation') is not null
    or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where (n.nspname='public' and p.proname in ('get_manual_damage_management_v1','correct_manual_damage_report_v1',
      'preview_manual_damage_removal_v1','remove_manual_damage_reports_v1','get_manual_damage_management_audit_v1'))
      or (n.nspname='greenloop_private' and p.proname in ('prevent_manual_damage_audit_changes',
       'manual_damage_management_access','manual_damage_management_row','manual_damage_management_schema'))) then
  raise exception 'Unexpected manual damage management schema; no changes installed.' using errcode='55000';
 end if;
end;
$preflight$;

create table if not exists greenloop_private.manual_damage_state(
 report_id uuid primary key,
 row_data jsonb not null check(jsonb_typeof(row_data)='object'),
 revision bigint not null check(revision>0),
 deleted boolean not null default false
);
create table if not exists greenloop_private.manual_damage_operations(
 id uuid primary key default gen_random_uuid(),
 actor_user_id uuid not null,
 actor_name text not null,
 request_id uuid not null,
 payload jsonb not null,
 action text not null check(action in ('correct','delete','reset')),
 reason text not null check(char_length(reason) between 3 and 2000),
 created_at timestamptz not null default clock_timestamp(),
 affected_count bigint not null check(affected_count>0),
 result jsonb not null,
 unique(actor_user_id,request_id)
);
create table if not exists greenloop_private.manual_damage_audit(
 id uuid primary key default gen_random_uuid(),
 operation_id uuid not null,
 report_id uuid not null,
 before_data jsonb not null,
 after_data jsonb,
 unique(operation_id,report_id)
);
create index if not exists manual_damage_audit_report on greenloop_private.manual_damage_audit(report_id,operation_id);
create index if not exists manual_damage_operations_recent on greenloop_private.manual_damage_operations(created_at desc,id desc);
alter table greenloop_private.manual_damage_state enable row level security;
alter table greenloop_private.manual_damage_operations enable row level security;
alter table greenloop_private.manual_damage_audit enable row level security;
revoke all on greenloop_private.manual_damage_state,greenloop_private.manual_damage_operations,greenloop_private.manual_damage_audit from public,anon,authenticated;

create or replace function greenloop_private.prevent_manual_damage_audit_changes()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $immutable$
begin
 raise exception 'Manual damage management audit records are permanent.' using errcode='42501';
end;
$immutable$;
revoke all on function greenloop_private.prevent_manual_damage_audit_changes() from public,anon,authenticated;
drop trigger if exists manual_damage_audit_immutable on greenloop_private.manual_damage_audit;
create trigger manual_damage_audit_immutable before update or delete or truncate on greenloop_private.manual_damage_audit
 for each statement execute function greenloop_private.prevent_manual_damage_audit_changes();
drop trigger if exists manual_damage_operations_immutable on greenloop_private.manual_damage_operations;
create trigger manual_damage_operations_immutable before update or delete or truncate on greenloop_private.manual_damage_operations
 for each statement execute function greenloop_private.prevent_manual_damage_audit_changes();

create or replace view greenloop_private.manual_damage_effective as
 select r.* from public.manual_damage_reports b
 left join greenloop_private.manual_damage_state s on s.report_id=b.id
 cross join lateral jsonb_populate_record(null::public.manual_damage_reports,coalesce(s.row_data,to_jsonb(b))) r
 where not coalesce(s.deleted,false);
revoke all on greenloop_private.manual_damage_effective from public,anon,authenticated;

create or replace function greenloop_private.manual_damage_management_access(p_edit boolean default false,p_reset boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $access$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false)
 and coalesce((select case when p_edit or p_reset then p.access_level='edit' else p.access_level in ('view','edit') end
  from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key='reports'),
  public.has_role(array['owner','super_admin']::public.app_role_key[]),false)
 and case when p_edit or p_reset then greenloop_private.manual_damage_access(true)
  else greenloop_private.manual_damage_access() or greenloop_private.damage_report_access() end
 and (not p_reset or coalesce(public.has_role(array['owner','super_admin']::public.app_role_key[]),false));
$access$;

create or replace function greenloop_private.manual_damage_management_row(p_row jsonb)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $row$
 select p_row-'request_id'-'reported_by_user_id'||jsonb_build_object('version',
  md5(p_row::text||':'||coalesce((select revision from greenloop_private.manual_damage_state where report_id=(p_row->>'id')::uuid),0)::text));
$row$;

create or replace function public.get_manual_damage_management_v1(p_search text default '',p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $read$
declare
 v_search text:=lower(btrim(coalesce(p_search,'')));
 v_offset integer:=greatest(0,coalesce(p_offset,0));
 v_limit integer:=greatest(1,least(coalesce(p_limit,20),100));
 v_count bigint;v_rows jsonb;v_options jsonb;
begin
 if not greenloop_private.manual_damage_management_access() then
  raise exception 'Reports and Damage Report or TV Manual Entry view permission are required.' using errcode='42501';
 end if;
 if char_length(v_search)>200 then raise exception 'Search must be at most 200 characters.' using errcode='22023'; end if;
 select count(*) into v_count from greenloop_private.manual_damage_effective r
 where v_search='' or strpos(lower(concat_ws(' ',r.id::text,r.damaged_by,r.model,r.part_name,r.damage,r.reason,r.identifier,r.reported_by)),v_search)>0;
 select coalesce(jsonb_agg(greenloop_private.manual_damage_management_row(to_jsonb(r)) order by r.occurred_at desc,r.id desc),'[]'::jsonb)
 into v_rows from (select * from greenloop_private.manual_damage_effective r
  where v_search='' or strpos(lower(concat_ws(' ',r.id::text,r.damaged_by,r.model,r.part_name,r.damage,r.reason,r.identifier,r.reported_by)),v_search)>0
  order by r.occurred_at desc,r.id desc offset v_offset limit v_limit) r;
 select jsonb_build_object(
  'employees',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='employee'),'[]'::jsonb),
  'models',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='model'),'[]'::jsonb),
  'parts',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part'),'[]'::jsonb),
  'reasons',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='reason'),'[]'::jsonb)
 ) into v_options from public.manual_damage_options where is_active;
 return jsonb_build_object('rows',v_rows,'total_count',v_count,'has_more',v_offset::bigint+v_limit<v_count,
  'can_edit',greenloop_private.manual_damage_management_access(true),'can_reset',greenloop_private.manual_damage_management_access(true,true),'options',v_options);
end;
$read$;

create or replace function public.correct_manual_damage_report_v1(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $correct$
declare
 v_actor uuid:=auth.uid();v_name text;v_operation uuid:=gen_random_uuid();v_result jsonb;v_payload jsonb;v_previous greenloop_private.manual_damage_operations%rowtype;
 v_before jsonb;v_after jsonb;v_row jsonb;
 v_employee public.manual_damage_options%rowtype;v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;v_reason public.manual_damage_options%rowtype;
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_explanation text:=btrim(coalesce(p_correction_reason,''),E' \t\n\r\f');
begin
 if not greenloop_private.manual_damage_management_access(true) then
  raise exception 'Reports edit and TV Manual Entry edit permission are required to correct manual damage.' using errcode='42501';
 end if;
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation);
 -- This lock also conflicts with ordinary submission INSERTs. All management
 -- writers take it before reading state, so a confirmed snapshot stays exact.
 lock table public.manual_damage_reports in share row exclusive mode;
 select * into v_previous from greenloop_private.manual_damage_operations where actor_user_id=v_actor and request_id=p_request_id;
 if found then
  if v_previous.payload is distinct from v_payload then raise exception 'This request ID was already used for different management details.' using errcode='22023'; end if;
  return v_previous.result;
 end if;
 select to_jsonb(r) into v_before from greenloop_private.manual_damage_effective r where id=p_id;
 if not found or greenloop_private.manual_damage_management_row(v_before)->>'version' is distinct from p_expected_version then
  raise exception 'This entry changed or was removed. Refresh it before saving.' using errcode='40001';
 end if;
 perform 1 from public.manual_damage_options where id in (p_employee_id,p_model_id,p_part_id,p_reason_id) order by id for share;
 select * into v_employee from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 select * into v_model from public.manual_damage_options where id=p_model_id and kind='model' and is_active;
 select * into v_part from public.manual_damage_options where id=p_part_id and kind='part' and is_active;
 select * into v_reason from public.manual_damage_options where id=p_reason_id and kind='reason' and is_active;
 if v_employee.id is null or v_model.id is null or v_part.id is null or v_reason.id is null then
  raise exception 'Select an active employee, model, part and reason. Refresh the choices if one was removed.' using errcode='22023';
 end if;
 v_after:=v_before||jsonb_build_object('employee_id',v_employee.id,'damaged_by',v_employee.label,'model',v_model.label,
  'part_name',v_part.label,'damage',v_part.label,'reason',v_reason.label,'identifier',v_identifier,'occurred_at',p_occurred_at);
 if v_after=v_before then raise exception 'Change at least one entry field before saving a correction.' using errcode='22023'; end if;
 insert into greenloop_private.manual_damage_state(report_id,row_data,revision,deleted) values(p_id,v_after,1,false)
 on conflict(report_id) do update set row_data=excluded.row_data,revision=manual_damage_state.revision+1;
 select greenloop_private.manual_damage_management_row(to_jsonb(r)) into v_row from greenloop_private.manual_damage_effective r where id=p_id;
 v_result:=jsonb_build_object('operation_id',v_operation,'action','correct','affected_count',1,'row',v_row);
 select coalesce(nullif(btrim(full_name),''),nullif(btrim(login_username),''),'Staff') into v_name from public.user_profiles where id=v_actor;
 insert into greenloop_private.manual_damage_operations(id,actor_user_id,actor_name,request_id,payload,action,reason,affected_count,result)
 values(v_operation,v_actor,coalesce(v_name,'Staff'),p_request_id,v_payload,'correct',v_explanation,1,v_result);
 insert into greenloop_private.manual_damage_audit(operation_id,report_id,before_data,after_data) values(v_operation,p_id,v_before,v_after);
 return v_result;
end;
$correct$;

create or replace function public.preview_manual_damage_removal_v1(p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $preview$
declare v_count bigint;v_snapshot text;v_rows jsonb;
begin
 if not greenloop_private.manual_damage_management_access(true,p_id is null) then
  raise exception 'Reports edit and TV Manual Entry edit are required; full reset also requires Owner or Super Admin.' using errcode='42501';
 end if;
 select count(*),md5(coalesce(string_agg(r.id::text||':'||(greenloop_private.manual_damage_management_row(to_jsonb(r))->>'version'),',' order by r.id),''))
 into v_count,v_snapshot from greenloop_private.manual_damage_effective r where p_id is null or r.id=p_id;
 if p_id is not null and v_count=0 then raise exception 'This entry was removed. Refresh the history.' using errcode='40001'; end if;
 select coalesce(jsonb_agg(greenloop_private.manual_damage_management_row(to_jsonb(r)) order by r.occurred_at desc,r.id desc),'[]'::jsonb)
 into v_rows from (select * from greenloop_private.manual_damage_effective where p_id is null or id=p_id order by occurred_at desc,id desc limit 20) r;
 return jsonb_build_object('scope',case when p_id is null then 'all' else 'single' end,'id',p_id,'count',v_count,'snapshot',v_snapshot,
  'confirmation',case when p_id is null then 'RESET MANUAL DAMAGE HISTORY' else 'DELETE ENTRY' end,'rows',v_rows);
end;
$preview$;

create or replace function public.remove_manual_damage_reports_v1(
 p_request_id uuid,p_id uuid,p_expected_snapshot text,p_expected_count bigint,p_confirmation text,p_reason text
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $remove$
declare
 v_actor uuid:=auth.uid();v_name text;v_operation uuid:=gen_random_uuid();v_preview jsonb;
 v_payload jsonb;v_previous greenloop_private.manual_damage_operations%rowtype;v_result jsonb;v_count bigint;
 v_action text:=case when p_id is null then 'reset' else 'delete' end;
 v_reason text:=btrim(coalesce(p_reason,''),E' \t\n\r\f');
begin
 if not greenloop_private.manual_damage_management_access(true,p_id is null) then
  raise exception 'Reports edit and TV Manual Entry edit are required; full reset also requires Owner or Super Admin.' using errcode='42501';
 end if;
 if p_request_id is null or coalesce(p_expected_snapshot,'')='' or coalesce(p_expected_count,0)<1 then
  raise exception 'A request ID and a nonempty confirmed preview are required.' using errcode='22023';
 end if;
 if char_length(v_reason) not between 3 and 2000 then raise exception 'Enter a removal reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if p_confirmation is distinct from (case when p_id is null then 'RESET MANUAL DAMAGE HISTORY' else 'DELETE ENTRY' end) then
  raise exception 'Type the exact confirmation phrase shown in the preview.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action',v_action,'id',p_id,'snapshot',p_expected_snapshot,'count',p_expected_count,'confirmation',p_confirmation,'reason',v_reason);
 lock table public.manual_damage_reports in share row exclusive mode;
 select * into v_previous from greenloop_private.manual_damage_operations where actor_user_id=v_actor and request_id=p_request_id;
 if found then
  if v_previous.payload is distinct from v_payload then raise exception 'This request ID was already used for different management details.' using errcode='22023'; end if;
  return v_previous.result;
 end if;
 v_preview:=public.preview_manual_damage_removal_v1(p_id);
 v_count:=(v_preview->>'count')::bigint;
 if v_preview->>'snapshot' is distinct from p_expected_snapshot or v_count is distinct from p_expected_count then
  raise exception 'The manual damage history changed after the preview. Review a fresh preview before confirming.' using errcode='40001';
 end if;
 v_result:=jsonb_build_object('operation_id',v_operation,'action',v_action,'affected_count',v_count);
 select coalesce(nullif(btrim(full_name),''),nullif(btrim(login_username),''),'Staff') into v_name from public.user_profiles where id=v_actor;
 insert into greenloop_private.manual_damage_operations(id,actor_user_id,actor_name,request_id,payload,action,reason,affected_count,result)
 values(v_operation,v_actor,coalesce(v_name,'Staff'),p_request_id,v_payload,v_action,v_reason,v_count,v_result);
 insert into greenloop_private.manual_damage_audit(operation_id,report_id,before_data,after_data)
 select v_operation,r.id,to_jsonb(r),null from greenloop_private.manual_damage_effective r where p_id is null or r.id=p_id;
 insert into greenloop_private.manual_damage_state(report_id,row_data,revision,deleted)
 select a.report_id,a.before_data,1,true from greenloop_private.manual_damage_audit a where operation_id=v_operation
 on conflict(report_id) do update set deleted=true,revision=manual_damage_state.revision+1;
 return v_result;
end;
$remove$;

create or replace function public.get_manual_damage_management_audit_v1(p_id uuid default null,p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $audit$
declare v_count bigint;v_rows jsonb;v_offset integer:=greatest(0,coalesce(p_offset,0));v_limit integer:=greatest(1,least(coalesce(p_limit,20),100));
begin
 if not greenloop_private.manual_damage_management_access() then
  raise exception 'Reports and Damage Report or TV Manual Entry view permission are required.' using errcode='42501';
 end if;
 select count(*) into v_count from greenloop_private.manual_damage_audit where p_id is null or report_id=p_id;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.operation_id desc,r.id desc),'[]'::jsonb) into v_rows from (
  select a.id,a.operation_id,a.report_id,o.action,o.actor_user_id,o.actor_name,o.created_at,o.reason,o.affected_count,
   a.before_data-'request_id'-'reported_by_user_id' as before,a.after_data-'request_id'-'reported_by_user_id' as after
  from greenloop_private.manual_damage_audit a join greenloop_private.manual_damage_operations o on o.id=a.operation_id
  where p_id is null or a.report_id=p_id order by o.created_at desc,o.id desc,a.id desc offset v_offset limit v_limit
 ) r;
 return jsonb_build_object('rows',v_rows,'total_count',v_count,'has_more',v_offset::bigint+v_limit<v_count);
end;
$audit$;

revoke all on function greenloop_private.manual_damage_management_access(boolean,boolean) from public,anon,authenticated;
revoke all on function greenloop_private.manual_damage_management_row(jsonb) from public,anon,authenticated;
revoke all on function public.get_manual_damage_management_v1(text,integer,integer) from public,anon;
revoke all on function public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text) from public,anon;
revoke all on function public.preview_manual_damage_removal_v1(uuid) from public,anon;
revoke all on function public.remove_manual_damage_reports_v1(uuid,uuid,text,bigint,text,text) from public,anon;
revoke all on function public.get_manual_damage_management_audit_v1(uuid,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_management_v1(text,integer,integer) to authenticated;
grant execute on function public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text) to authenticated;
grant execute on function public.preview_manual_damage_removal_v1(uuid) to authenticated;
grant execute on function public.remove_manual_damage_reports_v1(uuid,uuid,text,bigint,text,text) to authenticated;
grant execute on function public.get_manual_damage_management_audit_v1(uuid,integer,integer) to authenticated;

-- Effective readers: keep both existing permission boundaries and response shapes.
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
  raise exception 'TV Manual Entry view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*),
  count(*) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai'
   and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),
  count(*) filter(where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai')
 into v_total_count,v_today_count,v_month_count from greenloop_private.manual_damage_effective;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.count desc,lower(t.damaged_by),t.damaged_by),'[]'::jsonb)
 into v_technicians from (
  select damaged_by,count(*) as count from greenloop_private.manual_damage_effective
  where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai'
  group by damaged_by
 ) t;
 select coalesce(jsonb_agg(to_jsonb(r)-'request_id'-'reported_by_user_id'
  order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select * from greenloop_private.manual_damage_effective order by occurred_at desc,id desc
  offset v_offset limit v_limit) r;
 return jsonb_build_object('today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'technicians',v_technicians,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_total_count);
end;
$read$;

create or replace function public.get_manual_damage_employee_rows_v1(
 p_employee_id uuid,p_offset integer default 0,p_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $rows$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,6),100));
 v_normalized text;
 v_count bigint;
 v_rows jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select normalized_label into v_normalized from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 if not found then raise exception 'This employee does not exist.' using errcode='22023'; end if;
 select count(*) into v_count from greenloop_private.manual_damage_effective
 where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized);
 select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select id,occurred_at,model,part_name,reason,identifier,reported_by,created_at
  from greenloop_private.manual_damage_effective
  where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized)
  order by occurred_at desc,id desc offset v_offset limit v_limit) r;
 return jsonb_build_object('employee_id',p_employee_id,'total_damage',v_count,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_count);
end;
$rows$;

create or replace function public.get_manual_damage_cards_v1(
 p_offset integer default 0,p_limit integer default 4,p_row_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $cards$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,4),100));
 v_row_limit integer:=greatest(1,least(coalesce(p_row_limit,6),100));
 v_today date:=(now() at time zone 'Asia/Dubai')::date;
 v_month timestamp:=date_trunc('month',now() at time zone 'Asia/Dubai');
 v_employee_count bigint; v_today_count bigint; v_month_count bigint; v_total_count bigint;
 v_employees jsonb; v_activity jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*) into v_employee_count from public.manual_damage_options where kind='employee' and is_active;
 select count(*),
  count(*) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai'
   and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),
  count(*) filter(where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai')
 into v_total_count,v_today_count,v_month_count from greenloop_private.manual_damage_effective;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.label,
  'total_damage',h.data->'total_damage','rows',h.data->'rows','has_more',h.data->'has_more') order by e.sort_order,e.id),'[]'::jsonb)
 into v_employees from (select id,label,sort_order from public.manual_damage_options where kind='employee' and is_active
  order by sort_order,id offset v_offset limit v_limit) e
 cross join lateral (select public.get_manual_damage_employee_rows_v1(e.id,0,v_row_limit) as data) h;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc),'[]'::jsonb)
 into v_activity from (
  select id,created_at,occurred_at,damaged_by,model,part_name,reason
  from greenloop_private.manual_damage_effective order by created_at desc,id desc limit 5
 ) r;
 return jsonb_build_object('employee_count',v_employee_count,'today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'activity',v_activity,'employees',v_employees,'has_more',v_offset::bigint+v_limit<v_employee_count);
end;
$cards$;


-- Rebaseline only the three deliberately replaced reader definitions.
update greenloop_private.manual_damage_report_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity)='public.get_manual_damage_report_v1(integer,integer)'::regprocedure;
update greenloop_private.damage_employee_cards_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity) in ('public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure);
update greenloop_private.tv_damage_access_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.object_identity)))
where i.object_kind='function' and to_regprocedure(i.object_identity) in (
 'public.get_manual_damage_report_v1(integer,integer)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure);

-- Hash the structure as well as executable definitions, so replay and the
-- installer probe fail closed on missing/disabled triggers, drifted views,
-- changed columns/constraints, added policies, RLS changes or changed grants.
create or replace function greenloop_private.manual_damage_management_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $schema$
 select md5(jsonb_build_object(
  'relations',(select jsonb_agg(jsonb_build_array(c.oid::regclass::text,c.relkind,c.relrowsecurity,c.relforcerowsecurity,c.relacl::text,c.relowner) order by c.oid::regclass::text)
   from pg_class c where c.oid=any(array[
    'public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,
    'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass,
    'greenloop_private.manual_damage_effective'::regclass])),
  'columns',(select jsonb_agg(jsonb_build_array(a.attrelid::regclass::text,a.attnum,a.attname,a.atttypid::regtype::text,a.attnotnull,a.attisdropped,pg_get_expr(d.adbin,d.adrelid)) order by a.attrelid::regclass::text,a.attnum)
   from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
   where a.attrelid=any(array['public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass]) and a.attnum>0),
  'constraints',(select jsonb_agg(jsonb_build_array(c.conrelid::regclass::text,c.conname,pg_get_constraintdef(c.oid),c.convalidated) order by c.conrelid::regclass::text,c.conname)
   from pg_constraint c where c.conrelid=any(array['public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass])),
  'triggers',(select jsonb_agg(jsonb_build_array(t.tgrelid::regclass::text,t.tgname,pg_get_triggerdef(t.oid),t.tgenabled) order by t.tgrelid::regclass::text,t.tgname)
   from pg_trigger t where t.tgrelid=any(array['public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass]) and not t.tgisinternal),
  'indexes',(select jsonb_agg(pg_get_indexdef(i.indexrelid) order by pg_get_indexdef(i.indexrelid)) from pg_index i
   where i.indrelid=any(array['public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass])),
  'policies',(select jsonb_agg(to_jsonb(p)-'oid' order by p.polrelid::regclass::text,p.polname) from pg_policy p
   where p.polrelid=any(array['public.manual_damage_reports'::regclass,'greenloop_private.manual_damage_state'::regclass,'greenloop_private.manual_damage_operations'::regclass,'greenloop_private.manual_damage_audit'::regclass])),
  'view',pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true)
 )::text);
$schema$;
revoke all on function greenloop_private.manual_damage_management_schema() from public,anon,authenticated;
create table if not exists greenloop_private.manual_damage_management_installation(
 object_identity text primary key,object_kind text not null check(object_kind in ('function','schema')),definition_hash text not null);
revoke all on greenloop_private.manual_damage_management_installation from public,anon,authenticated;
insert into greenloop_private.manual_damage_management_installation
select p.oid::regprocedure::text,'function',md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in (
 'greenloop_private.prevent_manual_damage_audit_changes()'::regprocedure,
 'greenloop_private.manual_damage_management_access(boolean,boolean)'::regprocedure,
 'greenloop_private.manual_damage_management_row(jsonb)'::regprocedure,
 'greenloop_private.manual_damage_management_schema()'::regprocedure,
 'public.get_manual_damage_management_v1(text,integer,integer)'::regprocedure,
 'public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text)'::regprocedure,
 'public.preview_manual_damage_removal_v1(uuid)'::regprocedure,
 'public.remove_manual_damage_reports_v1(uuid,uuid,text,bigint,text,text)'::regprocedure,
 'public.get_manual_damage_management_audit_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_report_v1(integer,integer)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure)
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.manual_damage_management_installation values('manual_damage_management_schema','schema',greenloop_private.manual_damage_management_schema())
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_manual_damage_management_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_tv_damage_access_version()='20261005-tv-damage-access-1'
 and (select count(*)=12 and bool_and(to_regprocedure(i.object_identity) is not null
  and md5(pg_get_functiondef(to_regprocedure(i.object_identity)))=i.definition_hash
  and not has_function_privilege('anon',to_regprocedure(i.object_identity),'EXECUTE')
  and has_function_privilege('authenticated',to_regprocedure(i.object_identity),'EXECUTE')=(i.object_identity not like 'greenloop_private.%'))
  from greenloop_private.manual_damage_management_installation i where object_kind='function')
 and (select count(*)=1 and bool_and(definition_hash=greenloop_private.manual_damage_management_schema())
  from greenloop_private.manual_damage_management_installation where object_kind='schema' and object_identity='manual_damage_management_schema')
 and not exists(select 1 from unnest(array[
  'greenloop_private.manual_damage_state','greenloop_private.manual_damage_operations','greenloop_private.manual_damage_audit',
  'greenloop_private.manual_damage_effective','greenloop_private.manual_damage_management_installation']) r
  where has_table_privilege('anon',r,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',r,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 then '20261005-manual-damage-management-1' end;
$version$;
revoke all on function public.get_manual_damage_management_version() from public;
grant execute on function public.get_manual_damage_management_version() to anon,authenticated;
do $verify$
begin
 if public.get_manual_damage_management_version() is distinct from '20261005-manual-damage-management-1' then
  raise exception 'Manual damage management verification failed; no changes installed.' using errcode='55000';
 end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_manual_damage_management_version() as installed_manual_damage_management_version;
