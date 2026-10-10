-- Box Entry -> Accounts -> Stock Exported. Existing closed boxes remain legacy history.
-- Enum additions require a committed transaction before use. No business rows are deleted.
begin;
alter type public.job_status add value if not exists 'box_entry';
alter type public.job_status add value if not exists 'accounts_pending';
commit;
begin;
create schema if not exists greenloop_private;
create table if not exists greenloop_private.box_workflow (
 box_id uuid primary key references public.export_boxes(id) on delete cascade,
 state text not null default 'draft' check(state in ('draft','accounts','exported','legacy')),
 revision integer not null default 0,
 printed_revision integer,printed_at timestamptz,printed_by uuid,
 saved_at timestamptz,saved_by uuid,verified_at timestamptz,verified_by uuid
);
create table if not exists greenloop_private.box_workflow_audit (
 id bigint generated always as identity primary key,box_id uuid not null,box_number text,
 action text not null,actor uuid,occurred_at timestamptz not null default now(),details jsonb not null default '{}'
);
alter table greenloop_private.box_workflow enable row level security;
alter table greenloop_private.box_workflow_audit enable row level security;
revoke all on greenloop_private.box_workflow,greenloop_private.box_workflow_audit from public,anon,authenticated;
insert into greenloop_private.box_workflow(box_id,state,saved_at)
select id,case when box_status='open' then 'draft' else 'legacy' end,closed_at from public.export_boxes
on conflict(box_id) do nothing;
insert into public.locations(location_code,location_name,location_type,notes)
values('BOX-ENTRY','Box Entry','other','Phones reserved in boxes, awaiting Accounts verification.') on conflict(location_code) do nothing;

create or replace function greenloop_private.box_access(p_page text,p_edit boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false) and coalesce(
 (select case when p_edit then access_level='edit' else access_level in ('view','edit') end from public.user_page_permissions where user_id=auth.uid() and page_key=p_page),
 public.has_role(array['super_admin','owner']::public.app_role_key[]),false);
$$;
create or replace function greenloop_private.box_created()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin insert into greenloop_private.box_workflow(box_id) values(new.id); return new; end; $$;
drop trigger if exists box_workflow_created on public.export_boxes;
create trigger box_workflow_created after insert on public.export_boxes for each row execute function greenloop_private.box_created();
create or replace function greenloop_private.box_item_changed()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_state text;v_id uuid:=coalesce(new.box_id,old.box_id);
begin
 if tg_op='UPDATE' and to_jsonb(new)=to_jsonb(old) then return new;end if;
 select state into v_state from greenloop_private.box_workflow where box_id=v_id for update;
 if tg_op='INSERT' and v_state<>'draft' then raise exception 'This box is already saved. Open a new box.' using errcode='22023';end if;
 update greenloop_private.box_workflow set revision=revision+1,printed_revision=null,printed_at=null,printed_by=null,
 state=case when state in ('exported','legacy') and tg_op='UPDATE' then 'accounts' else state end,
 saved_at=case when state in ('exported','legacy') and tg_op='UPDATE' then now() else saved_at end,
 verified_at=case when tg_op='UPDATE' then null else verified_at end,verified_by=case when tg_op='UPDATE' then null else verified_by end where box_id=v_id;
 if tg_op='UPDATE' then
  insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)
  select v_id,box_number,'correction',auth.uid(),jsonb_build_object('device_id',new.device_id,'before',to_jsonb(old),'after',to_jsonb(new),'previous_state',v_state) from public.export_boxes where id=v_id;
  if v_state<>'draft' then
   update public.jobs set current_status='accounts_pending',closed_at=null,current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select job_id from public.export_box_items where box_id=v_id);
   update public.devices set current_status='accounts_pending',current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select device_id from public.export_box_items where box_id=v_id);
  end if;
 end if;
 return coalesce(new,old);
end; $$;
drop trigger if exists box_workflow_item_changed on public.export_box_items;
create trigger box_workflow_item_changed after insert or update or delete on public.export_box_items for each row execute function greenloop_private.box_item_changed();
-- Replace the previous immediate-dispatch trigger; scanning now reserves stock.
create or replace function public.force_export_box_item_to_shipped()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_location uuid;begin
 select id into v_location from public.locations where location_code='BOX-ENTRY' and is_active;
 if v_location is null then raise exception 'Box Entry location is not configured.';end if;
 update public.jobs set current_status='box_entry',current_location_id=v_location,closed_at=null where id=new.job_id;
 update public.devices set current_status='box_entry',current_location_id=v_location where id=new.device_id;
 return new;end; $$;
drop trigger if exists force_export_box_item_to_shipped_after_insert on public.export_box_items;
create trigger force_export_box_item_to_shipped_after_insert after insert on public.export_box_items for each row execute function public.force_export_box_item_to_shipped();

do $patch$ declare v text;begin
 select pg_get_functiondef('public.scan_imei_to_export_box(text)'::regprocedure) into v;
 if position('''box_entry''' in v)=0 then
  if position('''shipped''' in v)=0 or position('''OUTBOUND''' in v)=0 then raise exception 'Unknown export scanner definition. Install stopped.';end if;
  v:=replace(replace(replace(v,'''shipped''','''box_entry'''),'''OUTBOUND''','''BOX-ENTRY'''),'closed_at = now()','closed_at = null');execute v;
 end if;
end; $patch$;
do $lock$ declare n text;v text;begin
 foreach n in array array['public.get_or_create_open_export_box(integer)','public.scan_imei_to_export_box(text)'] loop
 select pg_get_functiondef(to_regprocedure(n)) into v;
 if position('box-workflow-lock' in v)=0 then
  v:=regexp_replace(v,'(\mbegin\M)',E'begin
  -- box-workflow-lock
  perform pg_advisory_xact_lock(16320261010);
  if not greenloop_private.box_access(''export_boxes'',true) then raise exception ''Box Entry permission required.'' using errcode=''42501''; end if;','i');execute v;
 end if;end loop;end; $lock$;

-- Adopt only currently open boxes; completed historical boxes are not re-verified automatically.
update public.export_boxes set capacity=1000000 where box_status='open';
update public.jobs j set current_status='box_entry',closed_at=null,
 current_location_id=(select id from public.locations where location_code='BOX-ENTRY')
from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id
where j.id=i.job_id and w.state='draft' and j.current_status='shipped';
update public.devices d set current_status='box_entry',current_location_id=(select id from public.locations where location_code='BOX-ENTRY')
from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id
where d.id=i.device_id and w.state='draft' and d.current_status='shipped';
create or replace function greenloop_private.box_source_changed()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare r record;v_changed boolean;begin
 if tg_table_name='devices' then
  v_changed:= (to_jsonb(new)-array['current_status','current_location_id','updated_at']) is distinct from (to_jsonb(old)-array['current_status','current_location_id','updated_at']);
 elsif tg_table_name='jobs' then
  v_changed:=new.supplier_id is distinct from old.supplier_id or new.receiving_batch_id is distinct from old.receiving_batch_id or new.received_at is distinct from old.received_at;
 else
  v_changed:=new.invoice_number is distinct from old.invoice_number or new.received_at is distinct from old.received_at or new.supplier_id is distinct from old.supplier_id;
 end if;
 if not v_changed then return new;end if;
 for r in select distinct b.id,b.box_number,w.state from public.export_boxes b join public.export_box_items i on i.box_id=b.id join greenloop_private.box_workflow w on w.box_id=b.id
 where (tg_table_name='devices' and i.device_id=new.id) or (tg_table_name='jobs' and i.job_id=new.id)
 or (tg_table_name='receiving_batches' and i.job_id in(select id from public.jobs where receiving_batch_id=new.id)) loop
  update greenloop_private.box_workflow set revision=revision+1,printed_revision=null,printed_at=null,printed_by=null,
   state=case when state='draft' then 'draft' else 'accounts' end,
   saved_at=case when state in ('exported','legacy') then now() else saved_at end,verified_at=null,verified_by=null where box_id=r.id;
  if r.state<>'draft' then
   update public.jobs set current_status='accounts_pending',closed_at=null,current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select job_id from public.export_box_items where box_id=r.id);
   update public.devices set current_status='accounts_pending',current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select device_id from public.export_box_items where box_id=r.id);
  end if;
  insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) values(r.id,r.box_number,'source_corrected',auth.uid(),jsonb_build_object('table',tg_table_name,'record_id',new.id));
 end loop;return new;end; $$;
drop trigger if exists box_source_device_changed on public.devices;
create trigger box_source_device_changed after update on public.devices for each row execute function greenloop_private.box_source_changed();
drop trigger if exists box_source_job_changed on public.jobs;
create trigger box_source_job_changed after update on public.jobs for each row execute function greenloop_private.box_source_changed();
drop trigger if exists box_source_receipt_changed on public.receiving_batches;
create trigger box_source_receipt_changed after update on public.receiving_batches for each row execute function greenloop_private.box_source_changed();
alter table public.user_page_permissions drop constraint if exists user_page_permissions_page_key_check;
alter table public.user_page_permissions add constraint user_page_permissions_page_key_check check(page_key in (
 'overview','stock_received','imei_entry','imei_search','initial_qc','lab_glass','lab_live_board','frame_department','parts','inventory',
 'final_qc','ready_stock','export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported'));
alter table public.user_page_permissions drop constraint if exists user_page_permissions_access_level_check;
alter table public.user_page_permissions add constraint user_page_permissions_access_level_check check(access_level in ('view','edit') or (access_level='none' and page_key in ('supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported')));

create or replace function public.get_my_page_access_v2()
returns table(page_key text,access_level text) language sql stable security definer set search_path=pg_catalog,public as $$
 select p.page_key,p.access_level from public.user_page_permissions p join public.user_profiles u on u.id=p.user_id where p.user_id=auth.uid() and u.is_active
 union all select k,'edit'::text from unnest(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported']) k
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
   then '{"supplier_returns":"edit","supplier_return_approval":"edit","supplier_return_handover":"edit","damage_report":"edit","tv_manual_entry":"edit","accounts":"edit","stock_exported":"edit"}'::jsonb else '{}'::jsonb end)
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
    'export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported'
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
  where user_id=p_user_id and page_key in ('damage_report','tv_manual_entry','accounts','stock_exported');

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
    where permission.value not in ('view', 'edit') and not (permission.value='none' and permission.key in ('supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported'))
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
  'damage_report','tv_manual_entry','accounts','stock_exported','frame_department','parts','inventory','final_qc','ready_stock',
  'export_boxes','ready_stock_journey','reports','user_access','supplier_returns','supplier_return_approval','supplier_return_handover'
 ]::text[],p.page_key)),array[]::text[])
 from public.get_my_page_access_v2() p where p.access_level in ('view','edit');
$my_pages$;

create or replace function public.get_box_workflow_v1(p_box_id uuid default null,p_box_number text default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_box public.export_boxes%rowtype;v_flow greenloop_private.box_workflow%rowtype;v_lines jsonb;v_names boolean;begin
 select * into v_box from public.export_boxes where (p_box_id is not null and id=p_box_id) or (p_box_id is null and box_number=p_box_number);
 if not found then raise exception 'Box not found.' using errcode='22023';end if;
 select * into v_flow from greenloop_private.box_workflow where box_id=v_box.id;
 if not(greenloop_private.box_access('reports') or greenloop_private.box_access(case v_flow.state when 'draft' then 'export_boxes' when 'accounts' then 'accounts' else 'stock_exported' end)) then raise exception 'Box page permission required.' using errcode='42501';end if;
 v_names:=coalesce(public.get_my_partner_name_access(),false);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.serial_no),'[]') into v_lines from (
 select i.id,i.device_id,i.serial_no,i.imei,i.model,i.storage_gb,i.color,i.final_grade,i.scanned_at,
 d.device_number,d.serial_number,s.supplier_code,case when v_names then s.company_name end supplier_name,
 coalesce(b.received_at,j.received_at) received_at,b.invoice_number,b.batch_number
 from public.export_box_items i join public.devices d on d.id=i.device_id join public.jobs j on j.id=i.job_id
 left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=j.supplier_id where i.box_id=v_box.id
 ) t;
 return jsonb_build_object('box',to_jsonb(v_box)||to_jsonb(v_flow)||jsonb_build_object('saved_by_name',(select full_name from public.user_profiles where id=v_flow.saved_by),'verified_by_name',(select full_name from public.user_profiles where id=v_flow.verified_by)), 'lines',v_lines);
end; $$;
create or replace function public.get_box_queue_v1(p_page text,p_date_from date default null,p_date_to date default null,p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_result jsonb;begin
 if p_page not in ('accounts','stock_exported') or not greenloop_private.box_access(p_page) then raise exception 'Box page permission required.' using errcode='42501';end if;
 if (p_date_from is null)<>(p_date_to is null) or p_date_from>p_date_to or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Select valid dates and page.' using errcode='22023';end if;
 with q as materialized(select b.id,b.box_number,w.state,w.revision,coalesce(w.saved_at,b.closed_at,b.opened_at) saved_at,w.verified_at,
 (select full_name from public.user_profiles where id=w.saved_by) saved_by_name,(select full_name from public.user_profiles where id=w.verified_by) verified_by_name,
 (select count(*) from public.export_box_items i where i.box_id=b.id) quantity
 from public.export_boxes b join greenloop_private.box_workflow w on w.box_id=b.id
 where (p_page='accounts' and w.state='accounts' or p_page='stock_exported' and w.state in ('exported','legacy'))
 and (p_date_from is null or (coalesce(case when p_page='stock_exported' then w.verified_at end,w.saved_at,b.closed_at,b.opened_at) at time zone 'Asia/Dubai')::date between p_date_from and p_date_to)),
 selected as(select * from q order by coalesce(verified_at,saved_at) desc,id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from q),'rows',coalesce((select jsonb_agg(to_jsonb(selected)) from selected),'[]')) into v_result;return v_result;
end; $$;
create or replace function public.mark_box_printed_v1(p_box_id uuid,p_revision integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare w greenloop_private.box_workflow%rowtype;begin
 perform pg_advisory_xact_lock(16320261010);
 perform 1 from public.export_boxes where id=p_box_id for update;
 select * into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if not found then raise exception 'Box not found.';end if;
 if w.state not in ('draft','accounts') or not greenloop_private.box_access(case when w.state='draft' then 'export_boxes' else 'accounts' end,true) then raise exception 'Entry Allowed permission required to confirm printing.' using errcode='42501';end if;
 if p_revision is distinct from w.revision or not exists(select 1 from public.export_box_items where box_id=p_box_id) then raise exception 'Box changed or is empty. Reload and print again.' using errcode='40001';end if;
 update greenloop_private.box_workflow set printed_revision=revision,printed_at=now(),printed_by=auth.uid() where box_id=p_box_id;
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) select p_box_id,box_number,'print_confirmed',auth.uid(),jsonb_build_object('revision',w.revision) from public.export_boxes where id=p_box_id;
 return true;end; $$;
create or replace function public.close_export_box(p_box_id uuid)
returns table(box_number text,box_capacity integer,item_count integer,box_status text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare w greenloop_private.box_workflow%rowtype;b public.export_boxes%rowtype;n integer;begin
 if not greenloop_private.box_access('export_boxes',true) then raise exception 'Box Entry edit permission required.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(16320261010);
 select * into b from public.export_boxes where id=p_box_id for update;
 select * into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 select count(*)::integer into n from public.export_box_items where box_id=p_box_id;
 if w.state='accounts' then return query select b.box_number,b.capacity,n,b.box_status;return;end if;
 if w.state is distinct from 'draft' or n=0 then raise exception 'Select a non-empty draft box.' using errcode='22023';end if;
 if w.printed_revision is distinct from w.revision or w.printed_at is null then raise exception 'Print this box and confirm printing before Save Box.' using errcode='22023';end if;
 update greenloop_private.box_workflow set state='accounts',saved_at=now(),saved_by=auth.uid() where box_id=p_box_id;
 update public.export_boxes set box_status='closed',closed_at=now() where id=p_box_id;
 update public.jobs set current_status='accounts_pending',closed_at=null,current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select job_id from public.export_box_items where box_id=p_box_id);
 update public.devices set current_status='accounts_pending',current_location_id=(select id from public.locations where location_code='BOX-ENTRY') where id in(select device_id from public.export_box_items where box_id=p_box_id);
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor) values(p_box_id,b.box_number,'saved_to_accounts',auth.uid());
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
 select device_id,job_id,'box_saved_to_accounts','Box saved to Accounts',jsonb_build_object('box_number',b.box_number,'next_status','accounts_pending'),auth.uid() from public.export_box_items where box_id=p_box_id;
 return query select b.box_number,b.capacity,n,'closed'::text;end; $$;
create or replace function public.verify_box_v1(p_box_id uuid,p_revision integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare w greenloop_private.box_workflow%rowtype;b public.export_boxes%rowtype;v_location uuid;begin
 if not greenloop_private.box_access('accounts',true) then raise exception 'Accounts Entry Allowed permission required to verify.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(16320261010);
 select * into b from public.export_boxes where id=p_box_id for update;
 select * into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if p_revision is distinct from w.revision then raise exception 'Box changed. Reload and review again.' using errcode='40001';end if;
 if w.state='exported' then return true;end if;
 if w.state is distinct from 'accounts' or not exists(select 1 from public.export_box_items where box_id=p_box_id) then raise exception 'Only a saved Accounts box can be verified.' using errcode='22023';end if;
 if w.printed_revision is distinct from w.revision or w.printed_at is null then raise exception 'Box was corrected. Print the updated box before verification.' using errcode='22023';end if;
 select id into v_location from public.locations where location_code='OUTBOUND' and is_active;
 if v_location is null then raise exception 'Outbound location is not configured.';end if;
 update greenloop_private.box_workflow set state='exported',verified_at=now(),verified_by=auth.uid() where box_id=p_box_id;
 insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by)
 select i.device_id,i.job_id,j.current_location_id,v_location,'Accounts verified box',b.box_number,auth.uid() from public.export_box_items i join public.jobs j on j.id=i.job_id where i.box_id=p_box_id;
 update public.jobs set current_status='shipped',current_location_id=v_location,closed_at=now() where id in(select job_id from public.export_box_items where box_id=p_box_id);
 update public.devices set current_status='shipped',current_location_id=v_location where id in(select device_id from public.export_box_items where box_id=p_box_id);
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor) values(p_box_id,b.box_number,'verified_exported',auth.uid());
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
 select device_id,job_id,'box_accounts_verified','Accounts verified — Stock Exported',jsonb_build_object('box_number',b.box_number,'next_status','shipped'),auth.uid() from public.export_box_items where box_id=p_box_id;
 return true;end; $$;

revoke all on function public.get_box_workflow_v1(uuid,text) from public,anon,authenticated;
grant execute on function public.get_box_workflow_v1(uuid,text) to authenticated;

revoke all on function public.get_box_queue_v1(text,date,date,integer,integer) from public,anon,authenticated;
grant execute on function public.get_box_queue_v1(text,date,date,integer,integer) to authenticated;

revoke all on function public.mark_box_printed_v1(uuid,integer) from public,anon,authenticated;
grant execute on function public.mark_box_printed_v1(uuid,integer) to authenticated;

revoke all on function public.verify_box_v1(uuid,integer) from public,anon,authenticated;
grant execute on function public.verify_box_v1(uuid,integer) to authenticated;

revoke all on function public.close_export_box(uuid) from public,anon,authenticated;
grant execute on function public.close_export_box(uuid) to authenticated;

revoke all on function public.scan_imei_to_export_box(text) from public,anon,authenticated;
grant execute on function public.scan_imei_to_export_box(text) to authenticated;

revoke all on function public.get_or_create_open_export_box(integer) from public,anon,authenticated;
grant execute on function public.get_or_create_open_export_box(integer) to authenticated;

revoke all on function public.force_export_box_item_to_shipped() from public,anon,authenticated;

revoke all on function greenloop_private.box_access(text,boolean) from public,anon,authenticated;

revoke all on function greenloop_private.box_created() from public,anon,authenticated;

revoke all on function greenloop_private.box_item_changed() from public,anon,authenticated;

revoke all on function greenloop_private.box_source_changed() from public,anon,authenticated;

do $seals$ declare t text;begin
 foreach t in array array['greenloop_private.tv_damage_access_installation','greenloop_private.supplier_return_installation'] loop
 if to_regclass(t) is not null then
 execute format('update %s i set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.object_identity))) where object_kind=''function'' and split_part(i.object_identity,''('',1) in (''get_my_page_access'',''public.get_my_page_access'',''get_my_page_access_v2'',''public.get_my_page_access_v2'',''get_user_page_access_matrix_v2'',''public.get_user_page_access_matrix_v2'',''save_user_page_access'',''public.save_user_page_access'',''save_user_page_access_v2'',''public.save_user_page_access_v2'')',t);
 execute format('update %s i set definition_hash=md5(pg_get_constraintdef(c.oid)||c.convalidated::text) from pg_constraint c where i.object_kind=''constraint'' and c.conrelid=''public.user_page_permissions''::regclass and c.conname=i.object_identity and c.conname in (''user_page_permissions_page_key_check'',''user_page_permissions_access_level_check'')',t);
 end if;end loop;end;$seals$;
create table if not exists greenloop_private.box_workflow_installation(identity text primary key,hash text not null);
revoke all on greenloop_private.box_workflow_installation from public,anon,authenticated;
insert into greenloop_private.box_workflow_installation select p,md5(pg_get_functiondef(to_regprocedure(p))) from unnest(array['public.get_box_workflow_v1(uuid,text)','public.get_box_queue_v1(text,date,date,integer,integer)','public.mark_box_printed_v1(uuid,integer)','public.verify_box_v1(uuid,integer)','public.close_export_box(uuid)','public.scan_imei_to_export_box(text)','public.get_or_create_open_export_box(integer)','public.force_export_box_item_to_shipped()','greenloop_private.box_access(text,boolean)','greenloop_private.box_created()','greenloop_private.box_item_changed()','greenloop_private.box_source_changed()']) p on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_box_workflow_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when (select count(*)=12 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')) from greenloop_private.box_workflow_installation)
 and not has_table_privilege('authenticated','greenloop_private.box_workflow','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.box_workflow','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and (select count(*)=6 from pg_trigger where tgname in ('box_workflow_created','box_workflow_item_changed','force_export_box_item_to_shipped_after_insert','box_source_device_changed','box_source_job_changed','box_source_receipt_changed') and tgenabled='O')
 then '20261010-box-workflow-1' end; $$;
revoke all on function public.get_box_workflow_version() from public;
grant execute on function public.get_box_workflow_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_box_workflow_version() as installed_box_workflow_version;
