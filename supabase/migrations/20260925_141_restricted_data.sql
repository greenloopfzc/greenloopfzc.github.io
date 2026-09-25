begin;

-- Standalone replacement for the Reports deletion workflow. Installation never
-- invokes deletion and does not depend on the body/version of the old cleanup.
create schema if not exists greenloop_private;
revoke all on schema greenloop_private from public, anon, authenticated;

create table if not exists greenloop_private.ledger_delete_capabilities (
  transaction_id bigint not null,
  backend_pid integer not null,
  movement_id uuid not null,
  audit_id uuid not null,
  primary key (transaction_id, backend_pid, movement_id)
);
revoke all on greenloop_private.ledger_delete_capabilities from public, anon, authenticated;

create or replace function greenloop_private.restricted_tables()
returns text[] language sql immutable set search_path = pg_catalog as $$
  select array[
    'part_return_stock_corrections','part_return_audit','lab_part_return_requests',
    'lab_manual_part_installations','frame_department_results','part_stock_movements',
    'final_qc_check_results','part_installations','part_issue_transactions',
    'lab_service_reviews','initial_qc_part_requirements','job_part_requests',
    'laboratory_work_records','glass_work_records','final_qc_inspections',
    'technician_job_timers','production_records','packing_records','stock_out_records',
    'export_box_items','job_work_order_steps','job_work_orders','initial_qc_findings',
    'initial_qc_inspections','device_events','device_location_history','jobs','devices',
    'stock_batch_plan_lines','receiving_batches','export_boxes'
  ]::text[];
$$;

create or replace function greenloop_private.require_deletion_access(p_scope text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null or not coalesce(public.has_page_edit_access('reports'),false) then
    raise exception 'Reports edit access is required.' using errcode='42501';
  end if;
  if p_scope not in ('single','all') or p_scope is null then
    raise exception 'Choose single IMEI or all IMEIs.' using errcode='22023';
  end if;
  if not coalesce(public.has_role(array['super_admin','owner','manager']::public.app_role_key[]),false)
     or (p_scope='all' and not coalesce(public.has_role(array['super_admin','owner']::public.app_role_key[]),false)) then
    raise exception 'Only owners/admins can reset all IMEIs; managers can delete one IMEI.' using errcode='42501';
  end if;
end;
$$;

create or replace function greenloop_private.deletion_plan(p_scope text,p_imei text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_imei text := nullif(btrim(p_imei),'');
  v_devices uuid[]; v_jobs uuid[]; v_orders uuid[]; v_steps uuid[];
  v_inspections uuid[]; v_requests uuid[]; v_issues uuid[];
  v_batches uuid[]; v_boxes uuid[] := '{}'::uuid[];
  v_table text; v_rows jsonb; v_plan jsonb := '{}'::jsonb;
  v_filter text; v_fk record; v_cross_link boolean;
begin
  perform greenloop_private.require_deletion_access(p_scope);
  if p_scope='single' and (v_imei is null or v_imei !~ '^[0-9]{15}$') then
    raise exception 'Enter the complete 15-digit IMEI.' using errcode='22023';
  elsif p_scope='all' and v_imei is not null then
    raise exception 'All-IMEI reset must not include an IMEI filter.' using errcode='22023';
  end if;

  -- A consistent snapshot is also used at execution. Table locks prevent new
  -- children or edits between the rechecked preview and the final deletion.
  -- This intentionally briefly pauses writers, while normal reads continue.
  for v_table in select unnest(greenloop_private.restricted_tables() || array['part_inventory','part_stock_lots','part_lot_status_balances','data_change_history','deletion_history']) order by 1 loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  select coalesce(array_agg(d.id order by d.id),'{}'::uuid[]) into v_devices
  from public.devices d where p_scope='all' or d.imei_1=v_imei or d.imei_2=v_imei;
  if p_scope='single' and cardinality(v_devices)=0 then
    raise exception 'No device matches that exact IMEI.' using errcode='22023';
  elsif p_scope='single' and cardinality(v_devices)>1 then
    raise exception 'This IMEI matches multiple devices. Correct the duplicate IMEI first.' using errcode='22023';
  end if;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_jobs from public.jobs where device_id=any(v_devices);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_orders from public.job_work_orders where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_steps from public.job_work_order_steps where work_order_id=any(v_orders);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_inspections from (
    select id from public.initial_qc_inspections where job_id=any(v_jobs)
    union select id from public.final_qc_inspections where job_id=any(v_jobs)
  ) q;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_requests from public.job_part_requests where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_issues from public.part_issue_transactions where part_request_id=any(v_requests);
  select coalesce(array_agg(b.id),'{}'::uuid[]) into v_batches from public.receiving_batches b
    where (p_scope='all' or exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and j.id=any(v_jobs)))
      and not exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and not(j.id=any(v_jobs)));
  if to_regclass('public.export_boxes') is not null and to_regclass('public.export_box_items') is not null then
    select coalesce(array_agg(b.id),'{}'::uuid[]) into v_boxes from public.export_boxes b
      where (p_scope='all' or exists(select 1 from public.export_box_items i where i.box_id=b.id and (i.device_id=any(v_devices) or i.job_id=any(v_jobs))))
        and not exists(select 1 from public.export_box_items i where i.box_id=b.id and not(i.device_id=any(v_devices) or i.job_id=any(v_jobs)));
  end if;

  -- Explicit allowlist: a newly added dependency must be reviewed, rather than
  -- silently being removed by an ON DELETE CASCADE without an audit snapshot.
  for v_fk in
    select child.relname as child_table, parent.relname as parent_table
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    where c.contype='f' and pn.nspname='public'
      and parent.relname=any(greenloop_private.restricted_tables())
      and not(ns.nspname='public' and (child.relname=any(greenloop_private.restricted_tables())
        or (child.relname='data_change_history' and c.confdeltype='n' and parent.relname in ('devices','jobs')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' else 'job_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])))
  loop
    raise exception 'Unreviewed dependency % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
  end loop;

  foreach v_table in array greenloop_private.restricted_tables() || array['data_change_history'] loop
    if to_regclass('public.'||v_table) is null then continue; end if;
    if p_scope='all' and v_table not in ('part_stock_movements','data_change_history') then v_filter := 'true';
    elsif v_table='devices' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($1)';
    elsif v_table='receiving_batches' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($8)';
    elsif v_table='stock_batch_plan_lines' then v_filter := '(to_jsonb(t)->>''receiving_batch_id'')::uuid=any($8)';
    elsif v_table='export_boxes' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($9)';
    else
      v_filter := '(to_jsonb(t)->>''device_id'')::uuid=any($1) or (to_jsonb(t)->>''job_id'')::uuid=any($2) or (to_jsonb(t)->>''work_order_id'')::uuid=any($3) or (to_jsonb(t)->>''work_order_step_id'')::uuid=any($4) or (to_jsonb(t)->>''inspection_id'')::uuid=any($5) or (to_jsonb(t)->>''part_request_id'')::uuid=any($6) or (to_jsonb(t)->>''part_issue_id'')::uuid=any($7)';
    end if;
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from public.%I t where %s',v_table,v_filter)
      into v_rows using v_devices,v_jobs,v_orders,v_steps,v_inspections,v_requests,v_issues,v_batches,v_boxes;
    v_plan := v_plan || jsonb_build_object(v_table,v_rows);
  end loop;
  -- Detect unplanned cross-links even if a future FK uses an existing table.
  -- This includes CASCADE/SET NULL FKs which otherwise could modify extra rows.
  for v_fk in
    select child.relname as child_table,parent.relname as parent_table,
      string_agg(format('to_jsonb(t)->%L = r->%L',ca.attname,pa.attname),' and ' order by k.ord) as predicate
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    cross join lateral unnest(c.conkey,c.confkey) with ordinality k(child_att,parent_att,ord)
    join pg_attribute ca on ca.attrelid=c.conrelid and ca.attnum=k.child_att
    join pg_attribute pa on pa.attrelid=c.confrelid and pa.attnum=k.parent_att
    where c.contype='f' and ns.nspname='public' and pn.nspname='public'
      and child.relname=any(greenloop_private.restricted_tables())
      and parent.relname=any(greenloop_private.restricted_tables())
    group by c.oid,child.relname,parent.relname
  loop
    execute format('select exists(select 1 from public.%I t where exists(select 1 from jsonb_array_elements($1) r where %s) and not exists(select 1 from jsonb_array_elements($2) r where r=to_jsonb(t)))',v_fk.child_table,v_fk.predicate)
      into v_cross_link using coalesce(v_plan->v_fk.parent_table,'[]'::jsonb),coalesce(v_plan->v_fk.child_table,'[]'::jsonb);
    if v_cross_link then
      raise exception 'Unreviewed cross-link % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
    end if;
  end loop;
  return jsonb_build_object('scope',p_scope,'imei',v_imei,'records',v_plan);
end;
$$;

create or replace function public.get_greenloop_deletion_preview(p_scope text,p_imei text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public set lock_timeout='5s' set statement_timeout='90s' as $$
declare v_plan jsonb; v_counts jsonb; v_count bigint;
begin
  v_plan := greenloop_private.deletion_plan(p_scope,p_imei);
  select jsonb_object_agg(key,jsonb_array_length(value)),sum(jsonb_array_length(value))
    into v_counts,v_count from jsonb_each(v_plan->'records') where key<>'data_change_history';
  return jsonb_build_object('scope',p_scope,'imei',v_plan->'imei',
    'device_count',jsonb_array_length(v_plan->'records'->'devices'),
    'job_count',jsonb_array_length(v_plan->'records'->'jobs'),
    'record_count',coalesce(v_count,0),'has_data',coalesce(v_count,0)>0,'counts',v_counts,
    'devices',(select coalesce(jsonb_agg(jsonb_build_object('imei_1',d->>'imei_1','imei_2',d->>'imei_2','device_number',d->>'device_number')),'[]'::jsonb) from jsonb_array_elements(v_plan->'records'->'devices') d),
    'confirmation',case when p_scope='single' then 'DELETE '||btrim(p_imei) else 'DELETE ALL IMEIS' end,
    'selection_token',md5(v_plan::text||auth.uid()::text));
end;
$$;

-- The only exception to the immutable movement ledger is an exact row already
-- archived by the authorized routine below. Callers cannot write capabilities,
-- fake them through session settings, or use them in another transaction.
create or replace function public.prevent_part_ledger_changes()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_allowed boolean := false;
begin
  if tg_op='DELETE' and tg_table_schema='public' and tg_table_name='part_stock_movements' then
    delete from greenloop_private.ledger_delete_capabilities c
    using public.deletion_history h
    where c.transaction_id=txid_current() and c.backend_pid=pg_backend_pid()
      and c.movement_id=old.id and h.id=c.audit_id
      and h.record_type='restricted_data_deletion'
      and h.deleted_by=auth.uid()
      and exists(select 1 from jsonb_array_elements(h.record_data->'records'->'part_stock_movements') r where r=to_jsonb(old))
    returning true into v_allowed;
    if v_allowed then return old; end if;
  end if;
  raise exception 'Stock Movement Ledger is immutable. Create a correcting movement instead.' using errcode='55000';
end;
$$;

create or replace function public.execute_greenloop_deletion(
  p_scope text,p_imei text,p_deletion_code text,p_confirmation text,p_reason text,p_selection_token text
)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public set lock_timeout='5s' set statement_timeout='90s' as $$
declare
  v_plan jsonb; v_table text; v_rows jsonb; v_row jsonb;
  v_audit_id uuid := gen_random_uuid(); v_actor jsonb; v_counts jsonb;
  v_record_count bigint := 0; v_deleted bigint; v_restored numeric := 0;
  v_stock_before jsonb; v_stock_after jsonb;
  v_lots_before jsonb := '[]'::jsonb; v_balances_before jsonb := '[]'::jsonb;
  v_lots_after jsonb := '[]'::jsonb; v_balances_after jsonb := '[]'::jsonb;
begin
  perform greenloop_private.require_deletion_access(p_scope);
  if coalesce(p_deletion_code,'')<>'1213' then raise exception 'Incorrect deletion code.' using errcode='42501'; end if;
  if p_reason is null or char_length(btrim(p_reason))<5 or char_length(btrim(p_reason))>1000 then
    raise exception 'Enter a deletion reason (5 to 1000 characters).' using errcode='22023';
  end if;
  if p_confirmation is distinct from (case when p_scope='single' then 'DELETE '||btrim(p_imei) else 'DELETE ALL IMEIS' end) then
    raise exception 'Type the exact confirmation shown in the preview.' using errcode='22023';
  end if;
  v_plan := greenloop_private.deletion_plan(p_scope,p_imei);
  if p_selection_token is null or p_selection_token<>md5(v_plan::text||auth.uid()::text) then
    raise exception 'The selected data changed. Preview it again before deleting.' using errcode='40001';
  end if;
  select jsonb_object_agg(key,jsonb_array_length(value)),sum(jsonb_array_length(value))
    into v_counts,v_record_count from jsonb_each(v_plan->'records') where key<>'data_change_history';
  if coalesce(v_record_count,0)=0 then raise exception 'There are no IMEI records or phone processes to delete.' using errcode='22023'; end if;
  select jsonb_build_object('id',id,'name',to_jsonb(p)->>'full_name','email',to_jsonb(p)->>'email')
    into v_actor from public.user_profiles p where id=auth.uid();
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_before from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_before from public.part_stock_lots l
      where l.id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_before from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;

  -- Archive complete ORIGINAL rows (including technician IDs, issue/return
  -- details and existing correction audit links) before any mutation.
  insert into public.deletion_history(id,deleted_by,record_type,record_id,record_label,deletion_method,deletion_reason,record_data)
    values(v_audit_id,auth.uid(),'restricted_data_deletion',v_audit_id::text,
      case when p_scope='single' then 'Single IMEI: '||btrim(p_imei) else 'All IMEIs reset' end,
      'hard_delete',btrim(p_reason),v_plan||jsonb_build_object('audit_id',v_audit_id,'actor',v_actor,'counts',v_counts,'inventory_before',v_stock_before,
        'professional_lots_before',v_lots_before,'professional_balances_before',v_balances_before,
        'professional_inventory_policy','Physical lot quantities and statuses retained. Removing phone history is not a physical stock return.'));

  -- Retain the established stock rule: only uninstalled, unreturned units are
  -- restored. Installed/damaged/manual parts are never added to available stock.
  with remaining as (
    select i.inventory_part_id,sum(greatest(i.quantity_issued-coalesce((select sum(x.quantity_installed) from public.part_installations x where x.part_issue_id=i.id),0)-i.quantity_returned,0)) as quantity
    from public.part_issue_transactions i
    where i.id::text in(select r->>'id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r)
    group by i.inventory_part_id
  ), changed as (
    update public.part_inventory i set stock_quantity=i.stock_quantity+r.quantity::integer
      from remaining r where i.id=r.inventory_part_id and r.quantity>0 returning r.quantity
  ) select coalesce(sum(quantity),0) into v_restored from changed;

  insert into greenloop_private.ledger_delete_capabilities(transaction_id,backend_pid,movement_id,audit_id)
    select txid_current(),pg_backend_pid(),(r->>'id')::uuid,v_audit_id
    from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r;

  foreach v_table in array greenloop_private.restricted_tables() loop
    v_rows := coalesce(v_plan->'records'->v_table,'[]'::jsonb);
    if jsonb_array_length(v_rows)=0 then continue; end if;
    -- Compare the complete archived row, not caller-provided identifiers.
    execute format('delete from public.%I t where exists(select 1 from jsonb_array_elements($1) r where r=to_jsonb(t))',v_table) using v_rows;
    get diagnostics v_deleted=row_count;
    if v_deleted<>jsonb_array_length(v_rows) then
      raise exception 'Selected % records changed during deletion. No changes saved.',v_table using errcode='40001';
    end if;
  end loop;
  if exists(select 1 from greenloop_private.ledger_delete_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid()) then
    raise exception 'Ledger deletion did not consume its exact audit authorization.' using errcode='55000';
  end if;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_after from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_after from public.part_stock_lots l
      where l.id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_after from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if v_lots_after<>v_lots_before or v_balances_after<>v_balances_before then
    raise exception 'Professional inventory changed during phone deletion. No changes saved.' using errcode='40001';
  end if;
  update public.deletion_history set record_data=record_data||jsonb_build_object('restored_part_units',v_restored,'inventory_after',v_stock_after,
    'professional_lots_after',v_lots_after,'professional_balances_after',v_balances_after)
    where id=v_audit_id;
  return jsonb_build_object('audit_id',v_audit_id,'scope',p_scope,
    'deleted_devices',jsonb_array_length(v_plan->'records'->'devices'),
    'deleted_jobs',jsonb_array_length(v_plan->'records'->'jobs'),
    'deleted_records',v_record_count,'restored_part_units',v_restored,'counts',v_counts);
end;
$$;

revoke all on all functions in schema greenloop_private from public,anon,authenticated;
revoke all on function public.prevent_part_ledger_changes() from public,anon,authenticated;
revoke all on function public.get_greenloop_deletion_preview(text,text) from public,anon;
revoke all on function public.execute_greenloop_deletion(text,text,text,text,text,text) from public,anon;
grant execute on function public.get_greenloop_deletion_preview(text,text) to authenticated;
grant execute on function public.execute_greenloop_deletion(text,text,text,text,text,text) to authenticated;

-- Old tabs must not bypass the new preview/audit workflow or erase setup/audit.
-- Keep the first ACL for recovery; do not rewrite any legacy function body.
create table if not exists greenloop_private.legacy_cleanup_acl_backup (
  function_identity text primary key, original_acl aclitem[], captured_at timestamptz not null default now()
);
revoke all on greenloop_private.legacy_cleanup_acl_backup from public,anon,authenticated;
do $$
declare r record;
begin
  for r in select p.oid::regprocedure::text as identity,p.proacl from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
      and p.proname in ('delete_greenloop_test_data_selectively','delete_all_test_operational_data','reset_greenloop_to_zero')
  loop
    insert into greenloop_private.legacy_cleanup_acl_backup(function_identity,original_acl)
      values(r.identity,r.proacl) on conflict(function_identity) do nothing;
    execute format('revoke all on function %s from public,anon,authenticated',r.identity);
  end loop;
end;
$$;

create table if not exists greenloop_private.restricted_routine_receipt (
  function_identity text primary key, definition_hash text not null
);
revoke all on greenloop_private.restricted_routine_receipt from public,anon,authenticated;
insert into greenloop_private.restricted_routine_receipt(function_identity,definition_hash)
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where (n.nspname='greenloop_private' and p.proname in ('restricted_tables','require_deletion_access','deletion_plan'))
   or (n.nspname='public' and p.proname in ('get_greenloop_deletion_preview','execute_greenloop_deletion','prevent_part_ledger_changes'))
on conflict(function_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_greenloop_restricted_data_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r record;
begin
  if (select count(*) from greenloop_private.restricted_routine_receipt)<>6 then return null; end if;
  for r in select * from greenloop_private.restricted_routine_receipt loop
    if to_regprocedure(r.function_identity) is null
       or md5(pg_get_functiondef(to_regprocedure(r.function_identity)))<>r.definition_hash then return null; end if;
  end loop;
  if has_schema_privilege('anon','greenloop_private','usage') or has_schema_privilege('authenticated','greenloop_private','usage') then return null; end if;
  if has_function_privilege('anon','public.get_greenloop_deletion_preview(text,text)','execute')
     or has_function_privilege('anon','public.execute_greenloop_deletion(text,text,text,text,text,text)','execute')
     or not has_function_privilege('authenticated','public.get_greenloop_deletion_preview(text,text)','execute')
     or not has_function_privilege('authenticated','public.execute_greenloop_deletion(text,text,text,text,text,text)','execute') then return null; end if;
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('delete_greenloop_test_data_selectively','delete_all_test_operational_data','reset_greenloop_to_zero')
  loop
    if has_function_privilege('anon',r.oid,'execute') or has_function_privilege('authenticated',r.oid,'execute') then return null; end if;
  end loop;
  if to_regclass('public.part_stock_movements') is not null and not exists(
    select 1 from pg_trigger where tgrelid=to_regclass('public.part_stock_movements')
      and tgfoid='public.prevent_part_ledger_changes()'::regprocedure and tgtype=27 and tgenabled in ('O','A')
  ) then return null; end if;
  return '20260925-restricted-data-1';
end;
$$;
revoke all on function public.get_greenloop_restricted_data_version() from public;
grant execute on function public.get_greenloop_restricted_data_version() to anon,authenticated;

do $$ begin
  if public.get_greenloop_restricted_data_version() is distinct from '20260925-restricted-data-1' then
    raise exception 'Restricted Data integrity verification failed. No changes were installed.' using errcode='55000';
  end if;
end; $$;

commit;
notify pgrst, 'reload schema';
select public.get_greenloop_restricted_data_version() as installed_restricted_data_version;
