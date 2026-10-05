-- Independent TV damage wall and manual-entry permissions. Existing reports,
-- choices, employee histories and operational records are preserved.
begin;

-- Refuse an unknown/damaged predecessor before replacing reviewed functions.
-- Successful replays keep these predecessor markers valid via narrow hash updates.
do $preflight$
begin
 if to_regprocedure('public.get_manual_damage_report_version()') is null
  or to_regprocedure('public.get_damage_employee_cards_version()') is null then
  raise exception 'Install verified migrations 150 and 151 before TV damage access.' using errcode='55000';
 end if;
 if public.get_manual_damage_report_version() is distinct from '20261003-manual-damage-1'
  or public.get_damage_employee_cards_version() is distinct from '20261003-damage-cards-1' then
  raise exception 'Manual damage predecessor verification failed; no changes installed.' using errcode='55000';
 end if;
end;
$preflight$;
alter table public.user_page_permissions drop constraint if exists user_page_permissions_page_key_check;
alter table public.user_page_permissions add constraint user_page_permissions_page_key_check check(page_key in (
 'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass','lab_live_board','frame_department','parts','inventory',
 'final_qc','ready_stock','export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry'));
alter table public.user_page_permissions drop constraint if exists user_page_permissions_access_level_check;
alter table public.user_page_permissions add constraint user_page_permissions_access_level_check check(access_level in ('view','edit') or (access_level='none' and page_key in ('supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry')));

create or replace function public.get_my_page_access_v2()
returns table(page_key text,access_level text) language sql stable security definer set search_path=pg_catalog,public as $$
 select p.page_key,p.access_level from public.user_page_permissions p join public.user_profiles u on u.id=p.user_id where p.user_id=auth.uid() and u.is_active
 union all select k,'edit'::text from unnest(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry']) k
 where public.is_active_staff() and public.has_role(array['owner','super_admin']::public.app_role_key[])
 and not exists(select 1 from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key=k);
$$;
create or replace function public.get_user_page_access_matrix_v2()
returns table(user_id uuid,login_username text,full_name text,email text,is_active boolean,page_permissions jsonb)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not coalesce(public.has_role(array['super_admin','owner']::public.app_role_key[]),false) then raise exception 'Only Super Admin and Owner can view user access.' using errcode='42501'; end if;
 return query select u.id,u.login_username,u.full_name,u.email,u.is_active,
  (case when exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=u.id and ro.role_key::text in ('owner','super_admin'))
   then '{"supplier_returns":"edit","supplier_return_approval":"edit","supplier_return_handover":"edit","damage_report":"edit","tv_manual_entry":"edit"}'::jsonb else '{}'::jsonb end)
  || coalesce((select jsonb_object_agg(p.page_key,p.access_level) from public.user_page_permissions p where p.user_id=u.id),'{}'::jsonb)
 from public.user_profiles u order by u.is_active desc,lower(coalesce(u.full_name,'')),lower(coalesce(u.login_username,''));
end; $$;

create or replace function public.save_user_page_access(
  p_user_id uuid, p_full_name text, p_login_username text, p_is_active boolean, p_page_keys text[]
)
returns boolean language plpgsql security definer set search_path = public
as $$
declare
  v_username text := lower(nullif(regexp_replace(btrim(coalesce(p_login_username, '')), '\s+', '', 'g'), ''));
  v_pages text[] := coalesce(array(select distinct unnest(p_page_keys)), array[]::text[]);
  v_allowed_pages constant text[] := array[
    'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass',
    'lab_live_board','frame_department','parts','inventory','final_qc','ready_stock',
    'export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry'
  ]::text[];
  v_is_super_admin boolean := public.has_role(array['super_admin']::public.app_role_key[]);
  v_existing_user_access boolean;
begin
  if not public.has_role(array['super_admin', 'owner']::public.app_role_key[]) then raise exception 'Only Super Admin and Owner can manage user access.' using errcode = '42501'; end if;
  if not exists (select 1 from public.user_profiles where id = p_user_id) then raise exception 'The selected user account was not found.' using errcode = '22023'; end if;
  if v_username is null or v_username !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Username must use 3 to 40 letters, numbers, dots, underscores, or hyphens.' using errcode = '22023'; end if;
  if cardinality(v_pages) = 0 then raise exception 'Select at least one page for this user.' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_pages) page_key where not page_key = any(v_allowed_pages)) then raise exception 'One or more selected pages are not valid.' using errcode = '22023'; end if;
  select exists (select 1 from public.user_page_permissions where user_id = p_user_id and page_key = 'user_access') into v_existing_user_access;
  if not v_is_super_admin and v_existing_user_access is distinct from ('user_access' = any(v_pages)) then raise exception 'Only Super Admin can change User Access permission.' using errcode = '42501'; end if;
  if p_user_id = auth.uid() and (not coalesce(p_is_active, true) or not ('user_access' = any(v_pages))) then raise exception 'You cannot remove your own active User Access permission.' using errcode = '22023'; end if;

  update public.user_profiles set full_name = coalesce(btrim(p_full_name), ''), login_username = v_username, is_active = coalesce(p_is_active, true) where id = p_user_id;
  delete from public.user_page_permissions where user_id = p_user_id;
  insert into public.user_page_permissions (user_id, page_key, assigned_by) select p_user_id, page_key, auth.uid() from unnest(v_pages) page_key;

  -- Legacy account creation grants new pages read access until v2 applies levels.
  update public.user_page_permissions set access_level='view'
  where user_id=p_user_id and page_key in ('damage_report','tv_manual_entry');

  delete from public.user_roles assignment using public.roles role where assignment.user_id = p_user_id and assignment.role_id = role.id and role.role_key::text <> 'super_admin';
  insert into public.user_roles (user_id, role_id, assigned_by)
  select distinct p_user_id, role.id, auth.uid() from public.roles role
  where role.role_key::text = any(array_remove(array[
    case when v_pages && array['overview','reports']::text[] then 'manager' end,
    case when v_pages && array['stock_received','imei_entry']::text[] then 'receiving' end,
    case when 'imei_search' = any(v_pages) then 'shipping' end,
    case when 'initial_qc' = any(v_pages) then 'initial_qc' end,
    case when v_pages && array['lab_glass','lab_live_board']::text[] then 'technician' end,
    case when v_pages && array['lab_glass','lab_live_board']::text[] then 'glass' end,
    case when 'frame_department' = any(v_pages) then 'frame' end,
    case when v_pages && array['parts','inventory']::text[] then 'parts' end,
    case when 'final_qc' = any(v_pages) then 'final_qc' end,
    case when v_pages && array['ready_stock','ready_stock_journey']::text[] then 'production' end,
    case when 'export_boxes' = any(v_pages) then 'shipping' end,
    case when 'user_access' = any(v_pages) then 'owner' end
  ]::text[], null)) on conflict (user_id, role_id) do update set assigned_by = excluded.assigned_by, assigned_at = now();
  return true;
end;
$$;

create or replace function public.save_user_page_access_v2(
  p_user_id uuid,
  p_full_name text,
  p_login_username text,
  p_is_active boolean,
  p_page_permissions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page_keys text[];
begin
  if jsonb_typeof(coalesce(p_page_permissions, '{}'::jsonb)) <> 'object' then
    raise exception 'Page permissions must be a valid object.' using errcode = '22023';
  end if;
  if exists(
    select 1
    from jsonb_each_text(coalesce(p_page_permissions, '{}'::jsonb)) as permission
    where permission.value not in ('view', 'edit') and not (permission.value='none' and permission.key in ('supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry'))
  ) then
    raise exception 'Each selected page must be Only View or Entry Allowed.' using errcode = '22023';
  end if;

  select coalesce(array_agg(permission.key), array[]::text[])
  into v_page_keys
  from jsonb_each_text(coalesce(p_page_permissions, '{}'::jsonb)) as permission;

  perform public.save_user_page_access(
    p_user_id, p_full_name, p_login_username, p_is_active, v_page_keys
  );

  update public.user_page_permissions as saved
  set access_level = permission.value,
      assigned_by = auth.uid(),
      assigned_at = now()
  from jsonb_each_text(p_page_permissions) as permission
  where saved.user_id = p_user_id and saved.page_key = permission.key;

  return true;
end;
$$;

-- Legacy clients must never interpret an explicit denial as an allowed page.
create or replace function public.get_my_page_access()
returns text[] language sql stable security definer set search_path=pg_catalog,public as $my_pages$
 select coalesce(array_agg(p.page_key order by array_position(array[
  'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass','lab_live_board',
  'damage_report','tv_manual_entry','frame_department','parts','inventory','final_qc','ready_stock',
  'export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover'
 ]::text[],p.page_key)),array[]::text[])
 from public.get_my_page_access_v2() p where p.access_level in ('view','edit');
$my_pages$;
create or replace function greenloop_private.manual_damage_access(p_edit boolean default false)
returns boolean language sql stable security definer
set search_path=pg_catalog,public as $access$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false)
  and coalesce((select case when p_edit then p.access_level='edit'
     else p.access_level in ('view','edit') end
    from public.user_page_permissions p
    where p.user_id=auth.uid() and p.page_key='tv_manual_entry'),
   public.has_role(array['owner','super_admin']::public.app_role_key[]),false);
$access$;
revoke all on function greenloop_private.manual_damage_access(boolean) from public,anon,authenticated;

create or replace function greenloop_private.damage_report_access(p_edit boolean default false)
returns boolean language sql stable security definer
set search_path=pg_catalog,public as $access$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false)
  and coalesce((select case when p_edit then p.access_level='edit'
     else p.access_level in ('view','edit') end
    from public.user_page_permissions p
    where p.user_id=auth.uid() and p.page_key='damage_report'),
   public.has_role(array['owner','super_admin']::public.app_role_key[]),false);
$access$;
revoke all on function greenloop_private.damage_report_access(boolean) from public,anon,authenticated;

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
  raise exception 'TV Manual Entry edit permission is required to record manual damage.' using errcode='42501';
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
  raise exception 'TV Manual Entry view permission is required to view manual damage.' using errcode='42501';
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

create or replace function public.get_manual_damage_options_v1()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $options$
declare v_result jsonb;
begin
 if not greenloop_private.manual_damage_access() then
  raise exception 'TV Manual Entry view permission is required to view manual damage.' using errcode='42501';
 end if;
 select jsonb_build_object(
  'employees',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='employee'),'[]'::jsonb),
  'models',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='model'),'[]'::jsonb),
  'parts',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part'),'[]'::jsonb),
  'reasons',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='reason'),'[]'::jsonb)
 ) into v_result from public.manual_damage_options where is_active;
 return v_result;
end;
$options$;

create or replace function public.add_manual_damage_option_v1(p_kind text,p_label text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $add$
declare
 v_label text:=btrim(regexp_replace(coalesce(p_label,''),'[[:space:]]+',' ','g'));
 v_max integer;
 v_option public.manual_damage_options%rowtype;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to manage manual damage choices.' using errcode='42501';
 end if;
 v_max:=case p_kind when 'employee' then 120 when 'model' then 160 when 'part' then 120 when 'reason' then 2000 end;
 if v_max is null then raise exception 'Choose a valid manual damage option kind.' using errcode='22023'; end if;
 if char_length(v_label) not between 1 and v_max then
  raise exception 'A label is required and must be at most % characters.',v_max using errcode='22023';
 end if;
 insert into public.manual_damage_options(kind,label,created_by)
 values(p_kind,v_label,auth.uid())
 on conflict(kind,normalized_label) do update
 set is_active=true,
  restored_at=case when not manual_damage_options.is_active then now() else manual_damage_options.restored_at end,
  restored_by=case when not manual_damage_options.is_active then auth.uid() else manual_damage_options.restored_by end
 returning * into v_option;
 return jsonb_build_object('id',v_option.id,'label',v_option.label);
end;
$add$;

create or replace function public.archive_manual_damage_option_v1(p_kind text,p_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $archive$
declare v_id uuid;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to manage manual damage choices.' using errcode='42501';
 end if;
 if p_kind is null or p_kind not in ('employee','model','part','reason') then
  raise exception 'Choose a valid manual damage option kind.' using errcode='22023';
 end if;
 update public.manual_damage_options set is_active=false,
  archived_at=case when is_active then now() else archived_at end,
  archived_by=case when is_active then auth.uid() else archived_by end
 where id=p_id and kind=p_kind returning id into v_id;
 if not found then raise exception 'This manual damage choice does not exist.' using errcode='22023'; end if;
 return jsonb_build_object('id',v_id);
end;
$archive$;

create or replace function public.create_manual_damage_report_v2(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $create$
declare
 v_actor uuid:=auth.uid();
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_reported_by text;
 v_employee public.manual_damage_options%rowtype;
 v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;
 v_reason public.manual_damage_options%rowtype;
 v_row public.manual_damage_reports%rowtype;
 v_existing boolean;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to record manual damage.' using errcode='42501';
 end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;

 -- Serialize the same actor/request before examining activation. A retry of a
 -- committed request remains valid after any selected choice was archived.
 perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_request_id::text,0));
 select * into v_row from public.manual_damage_reports where reported_by_user_id=v_actor and request_id=p_request_id;
 v_existing:=found;
 -- Lock choices in a fixed order so archive cannot race a new report commit.
 perform 1 from public.manual_damage_options
 where id in (p_employee_id,p_model_id,p_part_id,p_reason_id) order by id for share;
 select * into v_employee from public.manual_damage_options where id=p_employee_id and kind='employee';
 select * into v_model from public.manual_damage_options where id=p_model_id and kind='model';
 select * into v_part from public.manual_damage_options where id=p_part_id and kind='part';
 select * into v_reason from public.manual_damage_options where id=p_reason_id and kind='reason';
 if v_employee.id is null or v_model.id is null or v_part.id is null or v_reason.id is null then
  raise exception 'Select an employee, model, part name, and reason from the available choices.' using errcode='22023';
 end if;
 if v_existing then
  if row(v_row.employee_id,v_row.model,v_row.part_name,v_row.reason,v_row.identifier,v_row.occurred_at)
    is distinct from row(v_employee.id,v_model.label,v_part.label,v_reason.label,v_identifier,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
  return to_jsonb(v_row)-'request_id'-'reported_by_user_id';
 end if;
 if not(v_employee.is_active and v_model.is_active and v_part.is_active and v_reason.is_active) then
  raise exception 'A selected employee or choice was deleted. Refresh the choices before saving.' using errcode='22023';
 end if;
 select coalesce(nullif(btrim(u.full_name),''),nullif(btrim(u.login_username),''),'Staff')
 into v_reported_by from public.user_profiles u where u.id=v_actor;
 -- The old required damage field stores the selected part label for v2 rows.
 -- Actual part display always uses the separate, explicit part_name snapshot.
 insert into public.manual_damage_reports(request_id,reported_by_user_id,reported_by,
  damaged_by,employee_id,model,identifier,damage,part_name,reason,occurred_at)
 values(p_request_id,v_actor,coalesce(v_reported_by,'Staff'),v_employee.label,v_employee.id,
  v_model.label,v_identifier,v_part.label,v_part.label,v_reason.label,p_occurred_at)
 on conflict(reported_by_user_id,request_id) do nothing returning * into v_row;
 if not found then
  select * into strict v_row from public.manual_damage_reports where reported_by_user_id=v_actor and request_id=p_request_id;
  if row(v_row.employee_id,v_row.model,v_row.part_name,v_row.reason,v_row.identifier,v_row.occurred_at)
    is distinct from row(v_employee.id,v_model.label,v_part.label,v_reason.label,v_identifier,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
 end if;
 return to_jsonb(v_row)-'request_id'-'reported_by_user_id';
end;
$create$;

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
 select count(*) into v_count from public.manual_damage_reports
 where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized);
 select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select id,occurred_at,model,part_name,reason,identifier,reported_by,created_at
  from public.manual_damage_reports
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
 into v_total_count,v_today_count,v_month_count from public.manual_damage_reports;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.label,
  'total_damage',h.data->'total_damage','rows',h.data->'rows','has_more',h.data->'has_more') order by e.sort_order,e.id),'[]'::jsonb)
 into v_employees from (select id,label,sort_order from public.manual_damage_options where kind='employee' and is_active
  order by sort_order,id offset v_offset limit v_limit) e
 cross join lateral (select public.get_manual_damage_employee_rows_v1(e.id,0,v_row_limit) as data) h;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc),'[]'::jsonb)
 into v_activity from (
  select id,created_at,occurred_at,damaged_by,model,part_name,reason
  from public.manual_damage_reports order by created_at desc,id desc limit 5
 ) r;
 return jsonb_build_object('employee_count',v_employee_count,'today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'activity',v_activity,'employees',v_employees,'has_more',v_offset::bigint+v_limit<v_employee_count);
end;
$cards$;

revoke all on function public.get_manual_damage_options_v1() from public,anon;
revoke all on function public.add_manual_damage_option_v1(text,text) from public,anon;
revoke all on function public.archive_manual_damage_option_v1(text,uuid) from public,anon;
revoke all on function public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz) from public,anon;
revoke all on function public.get_manual_damage_employee_rows_v1(uuid,integer,integer) from public,anon;
revoke all on function public.get_manual_damage_cards_v1(integer,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_options_v1() to authenticated;
grant execute on function public.add_manual_damage_option_v1(text,text) to authenticated;
grant execute on function public.archive_manual_damage_option_v1(text,uuid) to authenticated;
grant execute on function public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz) to authenticated;
grant execute on function public.get_manual_damage_employee_rows_v1(uuid,integer,integer) to authenticated;
grant execute on function public.get_manual_damage_cards_v1(integer,integer,integer) to authenticated;


create index if not exists manual_damage_reports_created_recent on public.manual_damage_reports(created_at desc,id desc);

-- Permissions RPCs keep their existing authenticated-only boundary.
revoke all on function public.get_my_page_access() from public,anon;
revoke all on function public.get_my_page_access_v2() from public,anon;
revoke all on function public.get_user_page_access_matrix_v2() from public,anon;
revoke all on function public.save_user_page_access(uuid,text,text,boolean,text[]) from public,anon;
revoke all on function public.save_user_page_access_v2(uuid,text,text,boolean,jsonb) from public,anon;
grant execute on function public.get_my_page_access() to authenticated;
grant execute on function public.get_my_page_access_v2() to authenticated;
grant execute on function public.get_user_page_access_matrix_v2() to authenticated;
grant execute on function public.save_user_page_access(uuid,text,text,boolean,text[]) to authenticated;
grant execute on function public.save_user_page_access_v2(uuid,text,text,boolean,jsonb) to authenticated;

-- Refresh only functions deliberately replaced above, preserving detection of
-- unrelated predecessor drift. Do not rebaseline entire installation tables.
update greenloop_private.manual_damage_report_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity) in (
 'greenloop_private.manual_damage_access(boolean)'::regprocedure,
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.get_manual_damage_report_v1(integer,integer)'::regprocedure);
update greenloop_private.damage_employee_cards_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity) in (
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure);
update greenloop_private.supplier_return_installation i
set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.object_identity)))
where i.object_kind='function' and to_regprocedure(i.object_identity) in (
 'public.save_user_page_access(uuid,text,text,boolean,text[])'::regprocedure,
 'public.save_user_page_access_v2(uuid,text,text,boolean,jsonb)'::regprocedure,
 'public.get_my_page_access_v2()'::regprocedure,
 'public.get_user_page_access_matrix_v2()'::regprocedure);

create table if not exists greenloop_private.tv_damage_access_installation(
 object_identity text primary key,
 object_kind text not null check(object_kind in ('function','constraint')),
 definition_hash text not null
);
revoke all on greenloop_private.tv_damage_access_installation from public,anon,authenticated;
insert into greenloop_private.tv_damage_access_installation
select p.oid::regprocedure::text,'function',md5(pg_get_functiondef(p.oid))
from pg_proc p where p.oid in (
 'public.get_my_page_access()'::regprocedure,
 'public.get_my_page_access_v2()'::regprocedure,
 'public.get_user_page_access_matrix_v2()'::regprocedure,
 'public.save_user_page_access(uuid,text,text,boolean,text[])'::regprocedure,
 'public.save_user_page_access_v2(uuid,text,text,boolean,jsonb)'::regprocedure,
 'greenloop_private.manual_damage_access(boolean)'::regprocedure,
 'greenloop_private.damage_report_access(boolean)'::regprocedure,
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.get_manual_damage_report_v1(integer,integer)'::regprocedure,
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure)
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.tv_damage_access_installation
select c.conname,'constraint',md5(pg_get_constraintdef(c.oid)||c.convalidated::text)
from pg_constraint c where c.conrelid='public.user_page_permissions'::regclass
and c.conname in ('user_page_permissions_page_key_check','user_page_permissions_access_level_check')
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_tv_damage_access_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_report_version()='20261003-manual-damage-1'
 and public.get_damage_employee_cards_version()='20261003-damage-cards-1'
 and (select count(*)=15 and bool_and(
  to_regprocedure(i.object_identity) is not null
  and md5(pg_get_functiondef(to_regprocedure(i.object_identity)))=i.definition_hash
  and not has_function_privilege('anon',to_regprocedure(i.object_identity),'EXECUTE')
  and has_function_privilege('authenticated',to_regprocedure(i.object_identity),'EXECUTE')=(i.object_identity not like 'greenloop_private.%'))
  from greenloop_private.tv_damage_access_installation i where i.object_kind='function')
 and (select count(*)=2 and bool_and(exists(
  select 1 from pg_constraint c where c.conrelid='public.user_page_permissions'::regclass
  and c.conname=i.object_identity and md5(pg_get_constraintdef(c.oid)||c.convalidated::text)=i.definition_hash))
  from greenloop_private.tv_damage_access_installation i where i.object_kind='constraint')
 and not has_table_privilege('authenticated','greenloop_private.tv_damage_access_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.tv_damage_access_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261005-tv-damage-access-1' end;
$version$;
revoke all on function public.get_tv_damage_access_version() from public;
grant execute on function public.get_tv_damage_access_version() to anon,authenticated;

do $verify$
begin
 if public.get_tv_damage_access_version() is distinct from '20261005-tv-damage-access-1' then
  raise exception 'TV damage access verification failed; no changes installed.' using errcode='55000';
 end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_tv_damage_access_version() as installed_tv_damage_access_version;
