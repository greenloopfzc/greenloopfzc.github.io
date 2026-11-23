-- Read the saved Final QC battery health on the Accounts verification detail.
begin;

create or replace function public.get_accounts_verify_box_detail_v1(p_box_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $details$
declare
  details jsonb;
  updated_lines jsonb;
begin
  perform greenloop_private.require_office_network();
  if greenloop_private.damage_tv_only(auth.uid())
     or not coalesce(public.has_page_capability_v1('accounts','view'),false) then
    raise exception 'Accounts view permission required.' using errcode='42501';
  end if;
  details := public.get_box_workflow_v1(p_box_id);
  if details->'box'->>'state' is distinct from 'accounts' then
    raise exception 'This box is no longer awaiting Accounts verification. Refresh the box list.'
      using errcode='22023';
  end if;

  select coalesce(jsonb_agg(line.value||jsonb_build_object(
    'final_battery_health',case when not coalesce(battery.unavailable,false) then battery.health end,
    'final_battery_health_unavailable',coalesce(battery.unavailable,false)
  ) order by line.position),'[]'::jsonb)
  into updated_lines
  from jsonb_array_elements(details->'lines') with ordinality line(value,position)
  join public.export_box_items item on item.id=(line.value->>'id')::uuid and item.box_id=p_box_id
  left join lateral (
    -- Match the saved QC and direct-Ready sources used in IMEI Search.
    select inspection.final_battery_health as health,
           inspection.final_battery_health_unavailable as unavailable,
           inspection.inspected_at as recorded_at, 0 as source_order, inspection.id as source_id
    from public.final_qc_inspections inspection
    where inspection.job_id=item.job_id and inspection.device_id=item.device_id
      and not (coalesce(inspection.routed_to_frame,false)
               and strpos(coalesce(inspection.notes,''),'Initial QC direct route to Frame')>0)
    union all
    select ready.battery_health, ready.battery_health_unavailable, ready.ready_at, 1, ready.inspection_id
    from greenloop_private.qc_direct_ready ready
    where ready.job_id=item.job_id and ready.device_id=item.device_id
    order by recorded_at desc nulls last, source_order, source_id desc
    limit 1
  ) battery on true;
  return jsonb_set(details,'{lines}',updated_lines);
end;
$details$;

revoke all on function public.get_accounts_verify_box_detail_v1(uuid) from public,anon;
grant execute on function public.get_accounts_verify_box_detail_v1(uuid) to authenticated;

create or replace function public.get_accounts_box_final_bh_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when to_regprocedure('public.get_box_workflow_v1(uuid,text)') is not null
    and exists (
      select 1 from pg_proc
      where oid=to_regprocedure('public.get_accounts_verify_box_detail_v1(uuid)')
        and prosecdef and provolatile='s' and strpos(prosrc,'final_battery_health_unavailable')>0
    )
    and has_function_privilege('authenticated','public.get_accounts_verify_box_detail_v1(uuid)','EXECUTE')
    and not has_function_privilege('anon','public.get_accounts_verify_box_detail_v1(uuid)','EXECUTE')
    then '20261123-accounts-box-final-bh-1' end;
$version$;
revoke all on function public.get_accounts_box_final_bh_version() from public;
grant execute on function public.get_accounts_box_final_bh_version() to anon,authenticated;

do $verify$ begin
  if public.get_accounts_box_final_bh_version() is distinct from '20261123-accounts-box-final-bh-1' then
    raise exception 'Accounts Verify Box Final BH could not be verified.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_accounts_box_final_bh_version() as installed_accounts_box_final_bh_version;
