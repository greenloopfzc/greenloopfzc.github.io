-- GreenLoop software audit 20260918-audit-2
-- Run the complete file once in the GreenLoop Supabase SQL editor.
-- One transaction: an incompatible installed definition aborts all changes.
-- No business records are deleted or reset. Original routine definitions and partner ACLs are backed up privately.
begin;

-- SECTION: page-entry-guards.sql
-- Add page-entry checks without replacing the installed business rules.
-- Legacy account creation assigns page keys before the frontend sets levels.
-- Keep that first step read-only; existing permission rows are unchanged.
alter table public.user_page_permissions alter column access_level set default 'view';
create table if not exists public.greenloop_audit_20260918_backup (
  function_identity text primary key, definition text not null, saved_at timestamptz not null default now()
);
revoke all on public.greenloop_audit_20260918_backup from public, anon, authenticated;

create or replace function public.greenloop_require_entry(p_pages text[])
returns void language plpgsql security definer set search_path=public as $guard$
begin
  if not exists(select 1 from unnest(p_pages) page_key where public.has_page_edit_access(page_key)) then
    raise exception 'Entry Allowed permission is required for this operation.' using errcode='42501';
  end if;
end;
$guard$;
revoke all on function public.greenloop_require_entry(text[]) from public, anon;
grant execute on function public.greenloop_require_entry(text[]) to authenticated;

do $install$
declare target record; routine record; patched text; checks integer:=0;
begin
  for target in select * from (values
('create_receiving_job', array['stock_received']::text[]),
('create_stock_received_job', array['stock_received']::text[]),
('create_stock_received_channel_job', array['stock_received']::text[]),
('transfer_device_to_retail_shop', array['stock_received']::text[]),
('add_stock_channel', array['stock_received']::text[]),
('delete_stock_channel', array['stock_received']::text[]),
('create_stock_entry_batch', array['stock_received']::text[]),
('create_stock_entry_batch_with_lines', array['stock_received']::text[]),
('create_simple_stock_entry_batch', array['stock_received']::text[]),
('create_supplier_with_code', array['stock_received']::text[]),
('create_supplier_from_company', array['stock_received']::text[]),
('remove_supplier_from_receipts', array['stock_received']::text[]),
('delete_unused_supplier_company', array['stock_received']::text[]),
('archive_supplier_company', array['stock_received']::text[]),
('update_supplier_company_name', array['stock_received']::text[]),
('receive_stock_batch_imei', array['imei_entry']::text[]),
('receive_stock_batch_imei_with_plan', array['imei_entry']::text[]),
('complete_initial_qc', array['initial_qc']::text[]),
('complete_scanned_initial_qc', array['initial_qc']::text[]),
('complete_scanned_initial_qc_with_roster', array['initial_qc']::text[]),
('complete_scanned_initial_qc_with_roster_and_grades', array['initial_qc']::text[]),
('complete_initial_qc_lab_first', array['initial_qc']::text[]),
('complete_initial_qc_direct_to_frame', array['initial_qc']::text[]),
('complete_initial_qc_skip_lab_parts', array['initial_qc']::text[]),
('send_initial_qc_to_parts_and_laboratory', array['initial_qc']::text[]),
('start_glass_work', array['lab_glass']::text[]),
('complete_glass_work', array['lab_glass']::text[]),
('start_laboratory_work', array['lab_glass']::text[]),
('pause_laboratory_work', array['lab_glass']::text[]),
('resume_laboratory_work', array['lab_glass']::text[]),
('complete_laboratory_work', array['lab_glass']::text[]),
('record_part_installation', array['lab_glass']::text[]),
('request_additional_part', array['lab_glass']::text[]),
('request_initial_qc_part_from_lab', array['lab_glass']::text[]),
('review_initial_qc_service_from_lab', array['lab_glass']::text[]),
('add_lab_service_requirement', array['lab_glass']::text[]),
('request_lab_part', array['lab_glass']::text[]),
('save_lab_technician_line', array['lab_glass']::text[]),
('complete_lab_technician_line', array['lab_glass']::text[]),
('save_lab_technician_line_v2', array['lab_glass']::text[]),
('save_lab_technician_line_automatic_v2', array['lab_glass']::text[]),
('return_lab_unused_part', array['lab_glass']::text[]),
('return_lab_issued_part_v2', array['lab_glass']::text[]),
('return_lab_issued_part_v3', array['lab_glass']::text[]),
('request_lab_part_return', array['lab_glass']::text[]),
('mark_initial_qc_part_not_required', array['lab_glass']::text[]),
('complete_final_qc', array['final_qc','frame_department']::text[]),
('complete_final_qc_with_final_grade', array['final_qc','frame_department']::text[]),
('route_final_qc_pass_to_frame', array['final_qc']::text[]),
('route_final_qc_pass_to_frame_v2', array['final_qc','initial_qc']::text[]),
('receive_final_qc_phone', array['final_qc']::text[]),
('complete_frame_and_return_to_final_qc', array['frame_department']::text[]),
('complete_frame_to_ready_stock', array['frame_department']::text[]),
('complete_frame_to_ready_stock_with_grade', array['frame_department']::text[]),
('complete_frame_to_production', array['frame_department']::text[]),
('record_frame_department_result', array['frame_department']::text[]),
('record_frame_department_result_v2', array['frame_department']::text[]),
('receive_part_inventory_with_invoice', array['inventory']::text[]),
('create_part_master', array['inventory']::text[]),
('receive_part_stock_lot', array['inventory']::text[]),
('create_supplier_part_claim', array['inventory']::text[]),
('request_part_stock_adjustment', array['inventory']::text[]),
('route_job_to_laboratory_after_parts', array['parts']::text[]),
('issue_part_request', array['parts']::text[]),
('review_lab_part_return', array['parts']::text[]),
('cancel_part_request', array['parts']::text[]),
('set_manual_lab_parts_mode', array['parts']::text[]),
('set_part_request_technician', array['parts']::text[]),
('start_packing', array['export_boxes']::text[]),
('complete_packing', array['export_boxes']::text[]),
('complete_stock_out', array['export_boxes']::text[]),
('get_or_create_open_export_box', array['export_boxes']::text[]),
('scan_imei_to_export_box', array['export_boxes']::text[]),
('set_open_export_box_capacity', array['export_boxes']::text[]),
('close_export_box', array['export_boxes']::text[]),
('delete_export_box_with_restore', array['export_boxes','reports']::text[]),
('delete_export_box_by_number_with_restore', array['export_boxes','reports']::text[]),
('start_production', array['ready_stock']::text[]),
('complete_production', array['ready_stock']::text[]),
('send_ready_stock_for_rework', array['ready_stock']::text[]),
('ensure_ready_stock_frame_rework_cycle', array['ready_stock']::text[]),
('assign_ready_stock_rework_technician', array['ready_stock']::text[]),
('correct_imei_complete_record', array['reports']::text[]),
('delete_all_test_operational_data', array['reports']::text[]),
('delete_greenloop_test_data_selectively', array['reports']::text[]),
('reset_greenloop_to_zero', array['reports']::text[]),
('save_user_access', array['user_access']::text[]),
('save_user_page_access', array['user_access']::text[]),
('save_user_page_access_v2', array['user_access']::text[]),
('save_user_partner_name_access', array['user_access']::text[]),
('add_entry_option', array['final_qc','frame_department','imei_entry','initial_qc','inventory','lab_glass','parts','stock_received']::text[]),
('delete_entry_option', array['final_qc','frame_department','imei_entry','initial_qc','inventory','lab_glass','parts','stock_received']::text[]),
('add_technician_roster', array['initial_qc','lab_glass']::text[]),
('delete_technician_roster', array['initial_qc','lab_glass']::text[]),
('add_lab_technician', array['initial_qc','lab_glass']::text[]),
('remove_lab_technician', array['initial_qc','lab_glass']::text[]),
('add_part_inventory', array['inventory','parts']::text[]),
('return_unused_part', array['lab_glass','parts']::text[]),
('create_supplier', array['inventory','stock_received']::text[]),
('create_customer', array['export_boxes','stock_received']::text[]),
('save_stock_device_cable_details', array['imei_entry','ready_stock_journey','stock_received']::text[])
  ) as mapping(function_name, page_keys)
  loop
    for routine in select p.oid, p.prosrc, l.lanname, pg_get_functiondef(p.oid) as ddl,
      p.oid::regprocedure::text as identity
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang
      where n.nspname='public' and p.proname=target.function_name and p.prokind='f'
        and p.prorettype <> 'trigger'::regtype
    loop
      if strpos(routine.prosrc, '-- greenloop-entry-guard-20260918') > 0 then continue; end if;
      patched := routine.prosrc;
      -- Migration 135 uses "declare v_id uuid; begin" on one line. Normalize
      -- only this unambiguous, uninitialized UUID declaration form. Never match
      -- arbitrary semicolons/BEGIN words inside strings, comments or expressions.
      if routine.lanname = 'plpgsql' and patched ~* '^[[:space:]]*declare[[:space:]]+[a-z_][a-z_0-9]*[[:space:]]+uuid[[:space:]]*;[[:space:]]*begin\M'
         and patched !~* '(^|\n)[ \t]*begin\M' then
        patched := left(patched,strpos(patched,';')) || E'\n' || substring(patched from strpos(patched,';')+1);
      end if;
      if routine.lanname <> 'plpgsql' or patched !~* '(^|\n)[ \t]*begin\M' then
        raise exception 'Cannot safely guard %. No changes were installed.', routine.identity;
      end if;
      insert into public.greenloop_audit_20260918_backup(function_identity,definition)
        values(routine.identity,routine.ddl) on conflict do nothing;
      patched := regexp_replace(patched, '(^|\n)([ \t]*begin)\M',
        E'\nbegin\n  -- greenloop-entry-guard-20260918\n  perform public.greenloop_require_entry(' || quote_literal(target.page_keys::text) || E'::text[]);', 'i');
      if target.function_name = 'save_user_page_access_v2' then
        patched := replace(patched, '-- greenloop-entry-guard-20260918',
          E'-- greenloop-entry-guard-20260918\n  if p_user_id = auth.uid() and coalesce(p_page_permissions ->> ''user_access'', '''') <> ''edit'' then\n    raise exception ''You cannot remove your own User Access entry permission.'' using errcode=''42501'';\n  end if;');
      end if;
      if target.function_name = 'save_user_page_access' then
        patched := replace(patched, '-- greenloop-entry-guard-20260918',
          E'-- greenloop-entry-guard-20260918\n  insert into public.user_partner_name_permissions(user_id,can_view,access_level) values(p_user_id,false,''none'') on conflict (user_id) do nothing;');
        if patched !~* '\mreturn[ \t]+true[ \t]*;' then
          raise exception 'Cannot safely preserve legacy self access in %.', routine.identity;
        end if;
        -- The entry guard above proves the caller already had User Access edit.
        -- Legacy key-only saves reinsert rows using the new safe view default;
        -- preserve that existing self permission before returning to the caller.
        patched := regexp_replace(patched, '\mreturn[ \t]+true[ \t]*;',
          E'if p_user_id = auth.uid() then\n    update public.user_page_permissions set access_level = ''edit'' where user_id = p_user_id and page_key = ''user_access'';\n  end if;\n  return true;', 'i');
      end if;
      execute replace(routine.ddl, routine.prosrc, patched);
      checks:=checks+1;
    end loop;
  end loop;
  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='save_user_page_access_v2' and strpos(p.prosrc,'-- greenloop-entry-guard-20260918')>0) then
    raise exception 'Expected User Access function was not found; transaction rolled back.';
  end if;
  raise notice 'Installed % entry checks. Existing records were not changed.', checks;
end;
$install$;

create or replace function public.save_user_access_complete(
  p_user_id uuid, p_full_name text, p_login_username text, p_is_active boolean,
  p_page_permissions jsonb, p_partner_names_access text
) returns boolean language plpgsql security definer set search_path=public as $atomic$
begin
  perform public.greenloop_require_entry(array['user_access']);
  perform public.save_user_page_access_v2(p_user_id,p_full_name,p_login_username,p_is_active,p_page_permissions);
  perform public.save_user_partner_name_access(p_user_id,p_partner_names_access);
  return true;
end;
$atomic$;
revoke all on function public.save_user_access_complete(uuid,text,text,boolean,jsonb,text) from public,anon;
grant execute on function public.save_user_access_complete(uuid,text,text,boolean,jsonb,text) to authenticated;
notify pgrst, 'reload schema';


-- SECTION: intake-partner-permission-helper.sql
-- An explicit saved name permission takes precedence over the legacy admin
-- default. Existing admins with no saved row retain their established access.
-- Requires the audit migration's private backup table; changes no table grants.

do $backup_partner_helpers$
declare v_oid oid;
begin
  if to_regclass('public.greenloop_audit_20260918_backup') is null then
    raise exception 'Install the audit guard migration and its private backup table first.';
  end if;
  foreach v_oid in array array[
    to_regprocedure('public.get_my_partner_name_access()')::oid,
    to_regprocedure('public.get_my_partner_name_access_level()')::oid
  ] loop
    if v_oid is null then raise exception 'Existing partner-name permission helpers are required.'; end if;
    insert into public.greenloop_audit_20260918_backup(function_identity, definition)
      values (v_oid::regprocedure::text, pg_get_functiondef(v_oid)) on conflict do nothing;
  end loop;
end;
$backup_partner_helpers$;

create or replace function public.get_my_partner_name_access_level()
returns text
language sql stable security definer set search_path = public
as $$
  select case when public.is_active_staff() then coalesce(
    (select permission.access_level from public.user_partner_name_permissions as permission
     where permission.user_id = auth.uid()),
    case when public.has_role(array['super_admin','owner']::public.app_role_key[]) then 'edit' else 'none' end
  ) else 'none' end;
$$;

create or replace function public.get_my_partner_name_access()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.get_my_partner_name_access_level() in ('view', 'edit');
$$;

notify pgrst, 'reload schema';


-- SECTION: intake-privacy-fixes.sql
-- Candidate additive RPC-only privacy fix; prepared from local migrations.
-- Not installed or tested against the live database. This does NOT close direct
-- suppliers/customers table reads; see intake-backend-privacy.md.
-- Each function's installed body, signature, security mode and role guards are
-- preserved. An unexpected body aborts the entire transaction for review.

do $greenloop_privacy$
declare
  v_target record;
  v_oid oid;
  v_definition text;
  v_alias text;
  v_pattern text;
  v_replacement text;
  v_marker constant text := 'greenloop_partner_names_mask_20260918';
begin
  if to_regprocedure('public.get_my_partner_name_access()') is null then
    raise exception 'Partner-name permissions must be installed before this update.';
  end if;
  if to_regclass('public.greenloop_audit_20260918_backup') is null then
    raise exception 'Install the audit guard migration and its private backup table first.';
  end if;

  for v_target in
    select * from (values
      ('public.get_initial_qc_job_by_identifier(text)', array['supplier']),
      ('public.get_greenloop_reports(date,date)', array['customer']),
      ('public.get_open_stock_entry_batches()', array['supplier']),
      ('public.get_open_stock_entry_batches_with_lines()', array['supplier']),
      ('public.get_ready_stock_journey(date,date)', array['supplier','customer','owner_customer']),
      ('public.get_imei_correction_record(text)', array['supplier']),
      ('public.get_supplier_stock_progress(date,date)', array['supplier']),
      ('public.get_lab_technician_rows(uuid)', array['supplier']),
      ('public.get_frame_department_rows()', array['supplier']),
      ('public.get_overview_activity_headlines(integer,timestamp with time zone)', array['supplier'])
    ) as target(signature, aliases)
  loop
    v_oid := to_regprocedure(v_target.signature);
    if v_oid is null then
      raise exception 'Expected RPC is missing; no privacy update applied: %', v_target.signature;
    end if;
    v_definition := pg_get_functiondef(v_oid);
    if position(v_marker in v_definition) > 0 then
      continue;
    end if;
    if position('get_my_partner_name_access' in v_definition) > 0 then
      raise exception 'RPC already contains custom name masking; review before changing: %', v_target.signature;
    end if;

    foreach v_alias in array v_target.aliases loop
      v_pattern := '\m' || v_alias || '\.company_name\M';
      if v_definition !~ v_pattern then
        raise exception 'Expected name expression is missing in %: %', v_target.signature, v_alias;
      end if;
      v_replacement := '/* ' || v_marker || ' */ (case when coalesce(public.get_my_partner_name_access(), false) then '
        || v_alias || '.company_name else null::text end)';
      v_definition := regexp_replace(v_definition, v_pattern, v_replacement, 'g');
    end loop;

    insert into public.greenloop_audit_20260918_backup(function_identity, definition)
      values (v_oid::regprocedure::text, pg_get_functiondef(v_oid)) on conflict do nothing;
    execute v_definition;
  end loop;
end;
$greenloop_privacy$;

notify pgrst, 'reload schema';


-- SECTION: intake-safe-partner-views.sql
-- Deploy together with the frontend queries that use these masked views.
-- The view owner reads the base tables; callers receive only allowed fields.

create table if not exists public.greenloop_audit_20260918_partner_acl_backup (
  table_identity text primary key,
  table_acl text,
  column_acl jsonb not null,
  restore_select_sql text not null,
  saved_at timestamptz not null default now()
);
revoke all on public.greenloop_audit_20260918_partner_acl_backup from public, anon, authenticated;

do $backup_partner_select$
declare v_table record; v_restore text; v_columns jsonb;
begin
  for v_table in
    select c.oid, n.nspname, c.relname, c.relowner, c.relacl
    from pg_class as c join pg_namespace as n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('suppliers','customers') and c.relkind = 'r'
  loop
    select coalesce(jsonb_object_agg(a.attname, a.attacl::text) filter (where a.attacl is not null), '{}'::jsonb)
      into v_columns from pg_attribute as a where a.attrelid = v_table.oid and a.attnum > 0 and not a.attisdropped;
    select coalesce(string_agg(statement, E'\n'), '') into v_restore from (
      select format('grant select on table %I.%I to %s%s;', v_table.nspname, v_table.relname,
        case when acl.grantee = 0 then 'public' else quote_ident(role.rolname) end,
        case when acl.is_grantable then ' with grant option' else '' end) as statement
      from aclexplode(coalesce(v_table.relacl, acldefault('r', v_table.relowner))) as acl
      left join pg_roles as role on role.oid = acl.grantee
      where acl.privilege_type = 'SELECT' and (acl.grantee = 0 or role.rolname in ('anon','authenticated'))
      union all
      select format('grant select (%I) on table %I.%I to %s%s;', a.attname, v_table.nspname, v_table.relname,
        case when acl.grantee = 0 then 'public' else quote_ident(role.rolname) end,
        case when acl.is_grantable then ' with grant option' else '' end)
      from pg_attribute as a cross join lateral aclexplode(a.attacl) as acl
      left join pg_roles as role on role.oid = acl.grantee
      where a.attrelid = v_table.oid and a.attnum > 0 and not a.attisdropped
        and acl.privilege_type = 'SELECT' and (acl.grantee = 0 or role.rolname in ('anon','authenticated'))
    ) as statements;
    insert into public.greenloop_audit_20260918_partner_acl_backup(table_identity, table_acl, column_acl, restore_select_sql)
      values (format('%I.%I', v_table.nspname, v_table.relname), v_table.relacl::text, v_columns, v_restore)
      on conflict do nothing;
  end loop;
end;
$backup_partner_select$;

create or replace view public.greenloop_suppliers with (security_barrier = true) as
select supplier.id, supplier.supplier_code,
  case when public.get_my_partner_name_access() then supplier.company_name else null end as company_name,
  case when public.get_my_partner_name_access() then supplier.contact_name else null end as contact_name,
  supplier.is_active, supplier.deleted_at
from public.suppliers as supplier
where public.is_active_staff() and supplier.deleted_at is null;

create or replace view public.greenloop_customers with (security_barrier = true) as
select customer.id, customer.customer_code,
  case when public.get_my_partner_name_access() then customer.company_name else null end as company_name,
  case when public.get_my_partner_name_access() then customer.contact_name else null end as contact_name,
  customer.is_active, customer.deleted_at
from public.customers as customer
where public.is_active_staff() and customer.deleted_at is null;

revoke all on public.greenloop_suppliers, public.greenloop_customers from public, anon, authenticated;
grant select on public.greenloop_suppliers, public.greenloop_customers to authenticated;
notify pgrst, 'reload schema';


do $backup_board$
begin
  if to_regprocedure('public.get_lab_live_board()') is null then
    raise exception 'The current Lab Live Board function is missing; audit update aborted.';
  end if;
  insert into public.greenloop_audit_20260918_backup(function_identity,definition)
  values ('get_lab_live_board()',pg_get_functiondef('public.get_lab_live_board()'::regprocedure)) on conflict do nothing;
end;
$backup_board$;

-- SECTION: repair-board-metrics.sql
-- Repair audit: complete counts include the current technician workbench.
-- Replaces only this reader; preserves its signature, grants and existing data.

create or replace function public.get_lab_live_board()
returns table(
  technician_id uuid,
  technician_name text,
  pending_count integer,
  working_count integer,
  final_qc_handoff_count integer,
  overdue_count integer,
  oldest_pending_hours integer,
  completed_today integer,
  completed_month integer,
  completed_total integer,
  damage_month integer,
  qc_returns_month integer,
  latest_imei text,
  latest_model text,
  latest_gb integer,
  latest_color text,
  oldest_imei text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_role(array['super_admin', 'owner', 'manager', 'technician', 'glass']::public.app_role_key[]) then
    raise exception 'You do not have permission to view the Lab Live Board.' using errcode = '42501';
  end if;

  return query
  select
    technician.id, technician.full_name,
    coalesce(active_stats.pending_count, 0)::integer,
    coalesce(active_stats.working_count, 0)::integer,
    coalesce(active_stats.final_qc_handoff_count, 0)::integer,
    coalesce(active_stats.overdue_count, 0)::integer,
    active_stats.oldest_pending_hours,
    coalesce(completed_stats.completed_today, 0)::integer,
    coalesce(completed_stats.completed_month, 0)::integer,
    coalesce(completed_stats.completed_total, 0)::integer,
    coalesce(quality_stats.damage_month, 0)::integer,
    coalesce(quality_stats.qc_returns_month, 0)::integer,
    latest_device.imei_1::text, latest_device.model, latest_device.storage_gb, latest_device.color,
    oldest_device.imei_1::text
  from public.technician_roster as technician
  left join lateral (
    select
      count(distinct step.id)::integer as pending_count,
      count(distinct step.id) filter (where step.step_status = 'in_progress' and record_state.is_working)::integer as working_count,
      count(distinct step.id) filter (where step.step_status = 'completed')::integer as final_qc_handoff_count,
      count(distinct step.id) filter (where coalesce(step.returned_at, step.assigned_at, step.created_at) <= now() - interval '2 days')::integer as overdue_count,
      floor(extract(epoch from (now() - min(coalesce(step.returned_at, step.assigned_at, step.created_at)))) / 3600)::integer as oldest_pending_hours
    from public.job_work_order_steps as step
    join public.job_work_orders as work_order on work_order.id = step.work_order_id
    join public.jobs as job on job.id = work_order.job_id and job.deleted_at is null
    left join lateral (
      select exists (select 1 from public.laboratory_work_records as record where record.work_order_step_id = step.id and record.completed_at is null and record.paused_at is null)
          or exists (select 1 from public.glass_work_records as record where record.work_order_step_id = step.id and record.completed_at is null) as is_working
    ) as record_state on true
    where step.department in ('laboratory', 'glass')
      and (step.step_status = 'in_progress' or (step.step_status = 'completed' and exists (
        select 1 from public.job_work_order_steps as final_step
        where final_step.work_order_id = step.work_order_id and final_step.department = 'final_qc' and final_step.step_status = 'in_progress'
          and not exists (select 1 from public.device_events as event where event.job_id = work_order.job_id and event.event_type = 'final_qc_received' and event.event_data ->> 'final_qc_step_id' = final_step.id::text)
      )))
      and (step.assigned_technician_roster_id = technician.id or (step.assigned_technician_roster_id is null and lower(regexp_replace(btrim(coalesce(step.assigned_technician_name, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))))
  ) as active_stats on true
  left join lateral (
    select
      count(distinct completed.job_id) filter (where completed.completed_at is not null and timezone('Asia/Dubai', completed.completed_at)::date = timezone('Asia/Dubai', now())::date)::integer as completed_today,
      count(distinct completed.job_id) filter (where completed.completed_at is not null and timezone('Asia/Dubai', completed.completed_at) >= date_trunc('month', timezone('Asia/Dubai', now())))::integer as completed_month,
      count(distinct completed.job_id) filter (where completed.completed_at is not null)::integer as completed_total
    from (
      select record.work_order_step_id, record.job_id, record.completed_at from public.laboratory_work_records as record
      union all
      select record.work_order_step_id, record.job_id, record.completed_at from public.glass_work_records as record
      union all
      -- The current workbench records completion as an event, without closing
      -- legacy work records. Count that evidence too; distinct job_id above
      -- prevents repeat events, rework, and legacy records double-counting phones.
      select event_step.id, event.job_id, event.created_at
      from public.device_events as event
      join public.job_work_order_steps as event_step
        on event.event_data ->> 'step_id' = event_step.id::text
      where event.event_type = 'laboratory_completed'
    ) as completed
    join public.job_work_order_steps as step on step.id = completed.work_order_step_id
    where step.department in ('laboratory', 'glass')
      and (step.assigned_technician_roster_id = technician.id or (step.assigned_technician_roster_id is null and lower(regexp_replace(btrim(coalesce(step.assigned_technician_name, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))))
  ) as completed_stats on true
  left join lateral (
    select
      count(distinct request.id) filter (where request.notes ilike '%Damaged by Technician%' and timezone('Asia/Dubai', request.requested_at) >= date_trunc('month', timezone('Asia/Dubai', now())))::integer as damage_month,
      count(distinct inspection.id) filter (where inspection.result = 'fail' and inspection.failure_department in ('laboratory', 'glass') and timezone('Asia/Dubai', inspection.inspected_at) >= date_trunc('month', timezone('Asia/Dubai', now())))::integer as qc_returns_month
    from public.job_work_order_steps as assigned_step
    join public.job_work_orders as assigned_order on assigned_order.id = assigned_step.work_order_id
    join public.jobs as assigned_job on assigned_job.id = assigned_order.job_id and assigned_job.deleted_at is null
    left join public.job_part_requests as request on request.job_id = assigned_job.id and lower(regexp_replace(btrim(coalesce(request.requested_for_technician, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))
    left join public.final_qc_inspections as inspection on inspection.job_id = assigned_job.id
    where assigned_step.department in ('laboratory', 'glass')
      and (assigned_step.assigned_technician_roster_id = technician.id or (assigned_step.assigned_technician_roster_id is null and lower(regexp_replace(btrim(coalesce(assigned_step.assigned_technician_name, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))))
  ) as quality_stats on true
  left join lateral (
    select device.imei_1, device.model, device.storage_gb, device.color
    from public.job_work_order_steps as step
    join public.job_work_orders as work_order on work_order.id = step.work_order_id
    join public.jobs as job on job.id = work_order.job_id and job.deleted_at is null
    join public.devices as device on device.id = work_order.device_id and device.deleted_at is null
    where step.department in ('laboratory', 'glass')
      and (step.step_status = 'in_progress' or (step.step_status = 'completed' and exists (
        select 1 from public.job_work_order_steps as final_step
        where final_step.work_order_id = step.work_order_id and final_step.department = 'final_qc' and final_step.step_status = 'in_progress'
          and not exists (select 1 from public.device_events as event where event.job_id = work_order.job_id and event.event_type = 'final_qc_received' and event.event_data ->> 'final_qc_step_id' = final_step.id::text)
      )))
      and (step.assigned_technician_roster_id = technician.id or (step.assigned_technician_roster_id is null and lower(regexp_replace(btrim(coalesce(step.assigned_technician_name, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))))
    order by coalesce(step.returned_at, step.assigned_at, step.created_at) desc limit 1
  ) as latest_device on true
  left join lateral (
    select device.imei_1
    from public.job_work_order_steps as step
    join public.job_work_orders as work_order on work_order.id = step.work_order_id
    join public.jobs as job on job.id = work_order.job_id and job.deleted_at is null
    join public.devices as device on device.id = work_order.device_id and device.deleted_at is null
    where step.department in ('laboratory', 'glass')
      and (step.step_status = 'in_progress' or (step.step_status = 'completed' and exists (
        select 1 from public.job_work_order_steps as final_step
        where final_step.work_order_id = step.work_order_id and final_step.department = 'final_qc' and final_step.step_status = 'in_progress'
          and not exists (select 1 from public.device_events as event where event.job_id = work_order.job_id and event.event_type = 'final_qc_received' and event.event_data ->> 'final_qc_step_id' = final_step.id::text)
      )))
      and (step.assigned_technician_roster_id = technician.id or (step.assigned_technician_roster_id is null and lower(regexp_replace(btrim(coalesce(step.assigned_technician_name, '')), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(technician.full_name), '\s+', ' ', 'g'))))
    order by coalesce(step.returned_at, step.assigned_at, step.created_at), step.id limit 1
  ) as oldest_device on true
  where technician.is_active
  order by lower(technician.full_name);
end;
$$;




-- SECTION: stock-atomic-rework.sql
-- Additive API: all routing, history, and destination preparation succeed together.
-- Existing helper definitions and their role/technician/status checks are unchanged.
create or replace function public.send_ready_stock_for_rework_atomic(
  p_imei text,
  p_department text,
  p_customer_reason text default null,
  p_technician_id uuid default null
)
returns table (job_id uuid, destination text, rework_cycle integer)
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_department text := lower(btrim(coalesce(p_department, '')));
  v_result record;
begin
  if auth.uid() is null or not coalesce(public.has_page_edit_access('ready_stock'), false) then
    raise exception 'You do not have entry permission for Ready Stock.' using errcode = '42501';
  end if;
  if v_department not in ('laboratory', 'frame') then
    raise exception 'Select Laboratory or Frame Department.' using errcode = '22023';
  end if;
  if v_department = 'laboratory' and p_technician_id is null then
    raise exception 'Select an active Laboratory technician.' using errcode = '22023';
  end if;

  select routed.job_id, routed.destination, routed.rework_cycle into strict v_result
  from public.send_ready_stock_for_rework(p_imei, p_department, p_customer_reason) as routed;

  -- Do not catch helper failures: PostgreSQL rolls back the entire RPC statement,
  -- including routing, location changes, work-order changes, and history writes.
  if v_department = 'laboratory' then
    perform public.assign_ready_stock_rework_technician(p_imei, p_technician_id);
  else
    perform public.ensure_ready_stock_frame_rework_cycle(p_imei);
  end if;

  return query select v_result.job_id, v_result.destination, v_result.rework_cycle;
end;
$function$;

revoke all on function public.send_ready_stock_for_rework_atomic(text, text, text, uuid) from public;
grant execute on function public.send_ready_stock_for_rework_atomic(text, text, text, uuid) to authenticated;
notify pgrst, 'reload schema';


-- Public readiness marker contains no operational data.
create or replace function public.get_greenloop_audit_version()
returns text language sql immutable set search_path=public as $version$ select '20260918-audit-2-prepared'::text; $version$;
revoke all on function public.get_greenloop_audit_version() from public;
grant execute on function public.get_greenloop_audit_version() to anon,authenticated;
notify pgrst, 'reload schema';
commit;
select public.get_greenloop_audit_version() as installed_audit_version;
