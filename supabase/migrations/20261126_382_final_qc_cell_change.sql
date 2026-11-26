-- Extend the existing Final QC rule to the separate Cell Change catalog item.
do $install$
declare
  helper regprocedure := to_regprocedure('greenloop_private.qca_battery_issue_parts(uuid)');
  previous_hash text;
begin
  if helper is null or to_regprocedure('public.get_battery_cell_final_bh_version()') is null then
    raise exception 'Install the Battery Cell Final BH update first.';
  end if;
  if public.get_battery_cell_final_bh_version() is distinct from '20261117-battery-cell-final-bh-1' then
    raise exception 'The existing Battery Cell Final BH rule could not be verified.';
  end if;
  previous_hash := md5(pg_get_functiondef(helper));

  execute $definition$
    create or replace function greenloop_private.qca_battery_issue_parts(p_step uuid)
    returns text[] language sql stable security definer set search_path=pg_catalog,public as $parts$
      select coalesce(array_agg(distinct part.label order by part.label),'{}'::text[])
      from public.job_work_order_steps f
      join public.job_work_orders w on w.id=f.work_order_id
      join public.jobs j on j.id=w.job_id and j.deleted_at is null
      join public.devices d on d.id=j.device_id and d.deleted_at is null
      join public.job_part_requests r on r.job_id=j.id and r.device_id=d.id and r.status<>'cancelled'
      join (values ('diagnostic battery','Diagnostic Battery'),('battery cell','Battery Cell'),('cell change','Cell Change'))
        as part(part_key,label) on part.part_key=greenloop_private.pp_key(r.part_name)
      join public.part_issue_transactions i on i.part_request_id=r.id
      where f.id=p_step and f.department='final_qc'
        and i.quantity_issued-i.quantity_returned-coalesce((
          select sum(ret.quantity) from greenloop_private.parts_flow_returns ret
          where ret.issue_id=i.id and ret.status='pending'
        ),0)>0;
    $parts$;
  $definition$;
  update greenloop_private.battery_cell_bh_installation
  set hash=md5(pg_get_functiondef(helper))
  where to_regprocedure(identity)=helper and hash=previous_hash;

  execute $definition$
    create or replace function public.get_final_qc_cell_change_version()
    returns text language sql stable security definer set search_path=pg_catalog,public as $version$
      select case when public.get_battery_cell_final_bh_version()='20261117-battery-cell-final-bh-1'
        and exists(select 1 from pg_proc where oid='greenloop_private.qca_battery_issue_parts(uuid)'::regprocedure
          and strpos(prosrc,$match$('cell change','Cell Change')$match$)>0)
        then '20261126-final-qc-cell-change-1' end;
    $version$;
  $definition$;
  revoke all on function public.get_final_qc_cell_change_version() from public,anon,authenticated;
  grant execute on function public.get_final_qc_cell_change_version() to anon,authenticated;
  if public.get_final_qc_cell_change_version() is distinct from '20261126-final-qc-cell-change-1' then
    raise exception 'Final QC Cell Change installation could not be verified.';
  end if;
  notify pgrst,'reload schema';
end;
$install$;
select public.get_final_qc_cell_change_version() as installed_final_qc_cell_change_version;
