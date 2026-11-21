-- Load one page of current Lab & Glass phone lines for original stock receipts.
begin;
create or replace function public.get_lab_stock_workbench_v1(p_filters jsonb, p_page integer default 1)
returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $stock$
declare
  supplier_id_filter uuid := nullif(p_filters->>'supplier_id','')::uuid;
  batch_id_filter uuid := nullif(p_filters->>'batch_id','')::uuid;
  invoice_filter text := nullif(p_filters->>'invoice_number','');
  show_names boolean;
  result jsonb;
begin
  perform greenloop_private.pf_cap('lab_glass','view');
  perform greenloop_private.pf_cap('lab_glass','search');
  if not public.is_active_staff() then
    raise exception 'Active staff access is required.' using errcode='42501';
  end if;
  if (supplier_id_filter is null and batch_id_filter is null and invoice_filter is null)
     or p_page is null or p_page < 1 or p_page > 100000 then
    raise exception 'Select a supplier, stock or invoice and a valid page.' using errcode='22023';
  end if;
  if exists(select 1 from greenloop_private.srp_receipts
            group by replacement_batch_id having count(distinct original_batch_id)>1) then
    raise exception 'Original stock receipt linkage needs review.';
  end if;
  show_names := coalesce(public.get_my_partner_name_access(),false);

  with recursive receipts(batch_id,root_id) as (
    select b.id,b.id from public.receiving_batches b
    where (supplier_id_filter is null or b.supplier_id=supplier_id_filter)
      and (batch_id_filter is null or b.id=batch_id_filter)
      and (invoice_filter is null or b.invoice_number=invoice_filter)
      and not exists(select 1 from greenloop_private.srp_receipts x where x.replacement_batch_id=b.id)
    union
    select x.replacement_batch_id,r.root_id
    from receipts r join greenloop_private.srp_receipts x on x.original_batch_id=r.batch_id
  ), eligible as materialized (
    select s.id as step_id,j.id as job_id,w.initial_qc_inspection_id,d.id as device_id,
           r.root_id,s.department,s.rework_count,s.assigned_at,s.created_at,j.received_at,d.imei_1
    from receipts r
    join public.jobs j on j.receiving_batch_id=r.batch_id and j.deleted_at is null
    join public.job_work_orders w on w.job_id=j.id and w.device_id=j.device_id
    join public.devices d on d.id=j.device_id and d.deleted_at is null
    join public.job_work_order_steps s on s.work_order_id=w.id
    where j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
      and s.department in ('laboratory','glass') and s.step_status='in_progress'
      and greenloop_private.company_job_available(j.id)
  ), totals as (
    select count(*) as total,count(distinct imei_1) as distinct_phones from eligible
  ), selected as materialized (
    select e.* from eligible e
    where (select total=distinct_phones from totals)
    order by e.created_at,e.received_at,e.step_id
    limit 50 offset (select least((p_page-1)*50,greatest((total-1)/50,0)*50) from totals)
  ), rows as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'step_id',e.step_id,'job_id',e.job_id,'job_number',j.job_number,'department',e.department,
      'rework_count',e.rework_count,'imei',e.imei_1,'model',d.model,'storage_gb',d.storage_gb,
      'color',d.color,'battery_health',d.battery_health,'device_number',d.device_number,
      'serial_number',d.serial_number,'receiving_batch_id',b.id,'supplier_id',b.supplier_id,
      'supplier_code',supplier.supplier_code,'supplier_name',case when show_names then supplier.company_name end,
      'planned_quantity',b.planned_quantity,'batch_number',b.batch_number,'invoice_number',b.invoice_number,
      'technician_name',tech.full_name,'unassigned',tech.id is null,
      'line_created_at',e.created_at,'technician_assigned_at',e.assigned_at,
      'lab_entered_at',plan.data->>'_ol_lab_entered_at',
      'returned_from_final_qc',greenloop_private.pd_returned(e.step_id),
      'pf_plan',greenloop_private.pd_enrich(plan.data-'_ol_lab_entered_at'),
      'initial_parts',coalesce((select jsonb_agg(jsonb_build_object(
        'id',q.id,'name',q.part_name,'quantity',q.quantity_required,'status',q.status,'notes',q.notes,
        'part_request_id',q.part_request_id) order by q.identified_at)
        from public.initial_qc_part_requirements q where q.job_id=e.job_id),'[]'::jsonb),
      'initial_services',coalesce((select jsonb_agg(jsonb_build_object(
        'id',f.id,'name',f.check_item,'action',f.action_required,'priority',f.priority,'notes',f.notes,
        'lab_decision',case when v.id is null then 'pending_review' when v.is_required then 'required' else 'not_required' end,
        'lab_notes',v.notes) order by f.created_at)
        from public.initial_qc_findings f left join public.lab_service_reviews v
          on v.work_order_step_id=e.step_id and v.initial_finding_id=f.id
        where f.inspection_id=e.initial_qc_inspection_id and f.department in ('laboratory','glass','frame')
          and public.is_initial_qc_service(f.check_item)),'[]'::jsonb),
      'lab_part_requests',coalesce((select jsonb_agg(jsonb_build_object(
        'id',q.id,'name',q.part_name,'quantity',q.quantity_requested,'issued',q.quantity_issued,
        'installed',q.quantity_installed,'returned',q.quantity_returned,'status',q.status,
        'source',q.request_source,'notes',q.notes) order by q.requested_at)
        from public.job_part_requests q where q.job_id=e.job_id and q.status<>'cancelled'),'[]'::jsonb),
      'lab_services',coalesce((select jsonb_agg(jsonb_build_object(
        'id',v.id,'name',v.service_name,'source',v.source,'required',v.is_required,
        'notes',v.notes,'reviewed_at',v.reviewed_at) order by v.reviewed_at)
        from public.lab_service_reviews v where v.work_order_step_id=e.step_id
          and (v.source='laboratory' or public.is_initial_qc_service(v.service_name))),'[]'::jsonb),
      'manual_parts',coalesce((select jsonb_agg(jsonb_build_object(
        'name',m.part_name,'quantity',m.quantity,'notes',m.notes) order by m.installed_at,m.part_name)
        from public.lab_manual_part_installations m where m.work_order_step_id=e.step_id),'[]'::jsonb),
      'pending_part_returns',coalesce((select jsonb_agg(jsonb_build_object(
        'id',r.id,'part_request_id',r.part_request_id,'status',r.status))
        from public.lab_part_return_requests r where r.work_order_step_id=e.step_id and r.status='pending'),'[]'::jsonb)
    ) order by e.created_at,e.received_at,e.step_id),'[]'::jsonb) as data
    from selected e
    join public.jobs j on j.id=e.job_id
    join public.devices d on d.id=e.device_id
    join public.job_work_order_steps s on s.id=e.step_id
    join public.receiving_batches b on b.id=e.root_id
    join public.suppliers supplier on supplier.id=b.supplier_id
    left join lateral (
      select t.id,t.full_name from public.technician_roster t where t.is_active
        and greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,t.id,t.full_name)
      order by t.id limit 1
    ) tech on true
    cross join lateral (select greenloop_private.ol_plan(e.step_id) as data offset 0) plan
  )
  select jsonb_build_object('total',total,'page',least(p_page,greatest((total-1)/50+1,1)),
    'rows',rows.data,'verified',total=distinct_phones)
  into result from totals cross join rows;

  if (result->>'verified')::boolean is distinct from true then
    raise exception 'Selected stock has ambiguous Lab & Glass phone lines. Use the technician list to review.';
  end if;
  return greenloop_private.qcie_workbench((result-'verified')||jsonb_build_object(
    'damage_version','20261117-parts-request-damage-1','server_now',now(),
    'work_options',greenloop_private.rank_work_options(
      public.get_qc_work_options_v1('lab_glass'),greenloop_private.qc_work_usage_v1())));
end;
$stock$;

revoke all on function public.get_lab_stock_workbench_v1(jsonb,integer) from public,anon;
grant execute on function public.get_lab_stock_workbench_v1(jsonb,integer) to authenticated;
insert into greenloop_private.capability_rpc_rules values
  ('get_lab_stock_workbench_v1','{"page":"lab_glass","capability":"search","read":true}'),
  ('get_lab_stock_workbench_version','{"read":true}')
on conflict (rpc_name) do update set rule=excluded.rule;

create or replace function public.get_lab_stock_workbench_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when to_regprocedure('greenloop_private.ol_plan(uuid)') is not null
    and has_function_privilege('authenticated','public.get_lab_stock_workbench_v1(jsonb,integer)','EXECUTE')
    and not has_function_privilege('anon','public.get_lab_stock_workbench_v1(jsonb,integer)','EXECUTE')
    then '20261121-lab-stock-workbench-1' end;
$version$;
revoke all on function public.get_lab_stock_workbench_version() from public;
grant execute on function public.get_lab_stock_workbench_version() to anon,authenticated;

do $verify$
begin
  if public.get_lab_stock_workbench_version() is distinct from '20261121-lab-stock-workbench-1' then
    raise exception 'Lab & Glass stock filter verification failed.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_lab_stock_workbench_version() as installed_lab_stock_workbench_version;
