-- Reviewed Box Entry/Accounts dependencies for Restricted Data.
-- Installation changes functions only; it NEVER executes a reset or deletes business data.
-- Live Damage Report and its employees/options/prices/department/audit tables remain separate.
begin;
do $$ begin
  if public.get_greenloop_restricted_data_version() is distinct from '20260925-restricted-data-1'
    or public.get_box_workflow_version() is distinct from '20261010-box-workflow-1' then
    raise exception 'Install and verify Restricted Data and Box Workflow before this correction.' using errcode='55000';
  end if;
end; $$;

create or replace function greenloop_private.deletion_plan(p_scope text,p_imei text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_imei text := nullif(btrim(p_imei),'');
  v_devices uuid[]; v_jobs uuid[]; v_orders uuid[]; v_steps uuid[];
  v_inspections uuid[]; v_requests uuid[]; v_issues uuid[];
  v_batches uuid[]; v_boxes uuid[] := '{}'::uuid[];
  v_table text; v_rows jsonb; v_plan jsonb := '{}'::jsonb;
  v_filter text; v_fk record; v_cross_link boolean; v_workflows_before jsonb;
begin
  perform greenloop_private.require_deletion_access(p_scope);
  if p_scope='single' and (v_imei is null or v_imei !~ '^[0-9]{15}$') then
    raise exception 'Enter the complete 15-digit IMEI.' using errcode='22023';
  elsif p_scope='all' and v_imei is not null then
    raise exception 'All-IMEI reset must not include an IMEI filter.' using errcode='22023';
  end if;

  -- The damage module has its own removal workflow and must never enter this list.
  if exists(select 1 from unnest(greenloop_private.restricted_tables()) t
    where t like 'manual_damage%' or t like 'damage_%') then
    raise exception 'Live Damage Report is excluded from the operational reset.' using errcode='55000';
  end if;
  -- Use the same serialization lock as Box Entry/Accounts before taking table locks.
  perform pg_advisory_xact_lock(16320261010);
  -- A consistent snapshot is also used at execution. Table locks prevent new
  -- children or edits between the rechecked preview and the final deletion.
  -- This intentionally briefly pauses writers, while normal reads continue.
  for v_table in select unnest(greenloop_private.restricted_tables() || array['part_inventory','part_stock_lots','part_lot_status_balances','data_change_history','deletion_history','supplier_returns','supplier_return_events']) order by 1 loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  lock table greenloop_private.box_workflow in share row exclusive mode;

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
      and not((ns.nspname='greenloop_private' and child.relname='box_workflow'
        and parent.relname='export_boxes' and c.confdeltype='c' and c.convalidated
        and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname='box_id')]::smallint[]
        and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])
        or (ns.nspname='public' and (child.relname=any(greenloop_private.restricted_tables())
        or (child.relname='supplier_returns' and c.confdeltype='r'
          and parent.relname in ('devices','jobs','receiving_batches','stock_batch_plan_lines')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' when 'jobs' then 'job_id' when 'receiving_batches' then 'batch_id' else 'plan_line_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])
        or (child.relname='data_change_history' and c.confdeltype='n' and parent.relname in ('devices','jobs')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' else 'job_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[]))))
  loop
    raise exception 'Unreviewed dependency % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
  end loop;

  -- No other table may be silently cascaded or detached when deleting a flow.
  for v_fk in select c.conrelid::regclass::text as child_table from pg_constraint c
    where c.contype='f' and c.confrelid='greenloop_private.box_workflow'::regclass
  loop
    raise exception 'Unreviewed dependency % -> box_workflow. No records deleted.',v_fk.child_table using errcode='55000';
  end loop;
  select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
    into v_workflows_before from greenloop_private.box_workflow w
    where p_scope='all' or exists(select 1 from public.export_box_items i
      where i.box_id=w.box_id and (i.device_id=any(v_devices) or i.job_id=any(v_jobs)));
  -- Include exact workflow rows in the reviewed token and deletion audit. A shared
  -- box survives a single-IMEI deletion; only fully removed boxes lose their flow.
  select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
    into v_rows from greenloop_private.box_workflow w where w.box_id=any(v_boxes);
  v_plan := jsonb_build_object('box_workflow',v_rows);

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
  return jsonb_build_object('scope',p_scope,'imei',v_imei,'records',v_plan,
    'box_workflow_before',v_workflows_before,
    'supplier_returns_to_archive',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from public.supplier_returns r where r.archived_at is null and (p_scope='all' or r.device_id=any(v_devices) or r.job_id=any(v_jobs) or r.batch_id=any(v_batches))),'[]'::jsonb));
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

  -- Detach only the exact Supplier Return rows included in the preview token;
  -- the return and its events remain as permanent, readable audit records.
  perform greenloop_private.archive_supplier_returns_for_deletion(v_audit_id);

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

  -- Remove reviewed private flows BEFORE box items. Item-delete triggers otherwise
  -- increment the revision and clear print metadata, changing the archived row.
  -- Shared boxes are not in this array and retain their normal revision behavior.
  v_rows := coalesce(v_plan->'records'->'box_workflow','[]'::jsonb);
  delete from greenloop_private.box_workflow w
    where exists(select 1 from jsonb_array_elements(v_rows) r where r=to_jsonb(w));
  get diagnostics v_deleted=row_count;
  if v_deleted<>jsonb_array_length(v_rows) then
    raise exception 'Selected box workflow records changed during deletion. No changes saved.' using errcode='40001';
  end if;

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
    'professional_lots_after',v_lots_after,'professional_balances_after',v_balances_after,
    'box_workflow_after',(select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
      from greenloop_private.box_workflow w where w.box_id::text in
      (select r->>'box_id' from jsonb_array_elements(v_plan->'box_workflow_before') r)))
    where id=v_audit_id;
  return jsonb_build_object('audit_id',v_audit_id,'scope',p_scope,
    'deleted_devices',jsonb_array_length(v_plan->'records'->'devices'),
    'deleted_jobs',jsonb_array_length(v_plan->'records'->'jobs'),
    'deleted_records',v_record_count,'restored_part_units',v_restored,'counts',v_counts);
end;
$$;

revoke all on function greenloop_private.deletion_plan(text,text) from public,anon,authenticated;
revoke all on function public.execute_greenloop_deletion(text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.execute_greenloop_deletion(text,text,text,text,text,text) to authenticated;
-- Update only receipts for the two deliberately revised routines.
update greenloop_private.restricted_routine_receipt
  set definition_hash=md5(pg_get_functiondef(to_regprocedure(function_identity)))
  where to_regprocedure(function_identity) in ('greenloop_private.deletion_plan(text,text)'::regprocedure,'public.execute_greenloop_deletion(text,text,text,text,text,text)'::regprocedure);
update greenloop_private.supplier_return_installation
  set definition_hash=md5(pg_get_functiondef(to_regprocedure(object_identity)))
  where object_kind='function' and to_regprocedure(object_identity) in ('greenloop_private.deletion_plan(text,text)'::regprocedure,'public.execute_greenloop_deletion(text,text,text,text,text,text)'::regprocedure);

create table if not exists greenloop_private.operational_reset_installation (
  identity text primary key, definition_hash text not null
);
revoke all on greenloop_private.operational_reset_installation from public,anon,authenticated;
create or replace function public.get_operational_reset_version()
returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r record;
begin
  if public.get_greenloop_restricted_data_version() is distinct from '20260925-restricted-data-1'
    or public.get_box_workflow_version() is distinct from '20261010-box-workflow-1' then return null; end if;
  if (select count(*) from greenloop_private.operational_reset_installation)<>3 then return null; end if;
  for r in select * from greenloop_private.operational_reset_installation loop
    if to_regprocedure(r.identity) is null or r.definition_hash is distinct from md5(pg_get_functiondef(to_regprocedure(r.identity))) then return null; end if;
  end loop;
  if exists(select 1 from unnest(greenloop_private.restricted_tables()) t where t like 'manual_damage%' or t like 'damage_%')
    or has_table_privilege('anon','greenloop_private.operational_reset_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
    or has_table_privilege('authenticated','greenloop_private.operational_reset_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then return null; end if;
  if not exists(select 1 from pg_constraint c where c.conrelid='greenloop_private.box_workflow'::regclass
    and c.confrelid='public.export_boxes'::regclass and c.contype='f' and c.confdeltype='c' and c.convalidated
    and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname='box_id')]::smallint[]
    and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[]) then return null; end if;
  return '20261014-operational-reset-1';
end; $$;
revoke all on function public.get_operational_reset_version() from public;
grant execute on function public.get_operational_reset_version() to anon,authenticated;
insert into greenloop_private.operational_reset_installation(identity,definition_hash)
  select name,md5(pg_get_functiondef(to_regprocedure(name))) from unnest(array[
    'greenloop_private.deletion_plan(text,text)',
    'public.execute_greenloop_deletion(text,text,text,text,text,text)',
    'public.get_operational_reset_version()']) name
  on conflict(identity) do update set definition_hash=excluded.definition_hash;
do $$ begin
  if public.get_operational_reset_version() is distinct from '20261014-operational-reset-1' then
    raise exception 'Operational reset correction verification failed; installation rolled back.' using errcode='55000';
  end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_operational_reset_version() as installed_operational_reset_version;
