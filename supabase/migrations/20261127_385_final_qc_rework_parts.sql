-- Return a failed Final QC phone and submit its rework parts in one transaction.
begin;

create or replace function public.get_final_qc_rework_part_options_v1()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
declare options jsonb;
begin
  perform greenloop_private.pf_cap('final_qc','view');

  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',option_value)),'[]'::jsonb)
    into options
  from (
    select distinct on (greenloop_private.pp_key(option_value)) id,option_value
    from public.entry_options
    where option_group='part_name' and is_active
    order by greenloop_private.pp_key(option_value),created_at,id
  ) parts;

  return greenloop_private.rank_work_options(
    jsonb_build_object('parts',options),greenloop_private.qc_work_usage_v1()
  )->'parts';
end;
$body$;

create or replace function public.return_final_qc_with_parts_v1(
  p_final_step_id uuid,p_reason_id uuid,p_technician_id uuid,p_context_token text,
  p_final_battery_health smallint,p_battery_health_unavailable boolean,p_parts jsonb
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
declare
  part jsonb;
  name text;
  quantity integer;
  seen text[] := '{}';
  parts jsonb := '[]';
  result jsonb;
  returned greenloop_private.final_qc_failure_returns%rowtype;
  lab_cycle integer;
  order_id uuid;
  request_id uuid;
begin
  perform greenloop_private.pf_cap('final_qc','entry');
  if jsonb_typeof(p_parts) is distinct from 'array' then
    raise exception 'Choose a valid list of required parts.' using errcode='22023';
  end if;
  if jsonb_array_length(p_parts) not between 1 and 100 then
    raise exception 'Choose between 1 and 100 required parts.' using errcode='22023';
  end if;

  for part in select value from jsonb_array_elements(p_parts) loop
    if jsonb_typeof(part) is distinct from 'object' or coalesce(part->>'quantity','') !~ '^[0-9]{1,5}$' then
      raise exception 'Each required part needs a positive whole quantity.' using errcode='22023';
    end if;
    quantity := (part->>'quantity')::integer;
    select option_value into name
      from public.entry_options
      where option_group='part_name' and is_active
        and greenloop_private.pp_key(option_value)=greenloop_private.pp_key(part->>'name')
      order by created_at,id limit 1 for share;
    if name is null or quantity not between 1 and 10000 or greenloop_private.pp_key(name)=any(seen) then
      raise exception 'Choose each active part once and enter a whole quantity from 1 to 10000.' using errcode='22023';
    end if;
    seen := array_append(seen,greenloop_private.pp_key(name));
    parts := parts || jsonb_build_array(jsonb_build_object('name',name,'quantity',quantity));
  end loop;

  -- Match the ordering of the existing QC return and Parts workflow locks.
  perform pg_advisory_xact_lock(20420261026);
  perform pg_advisory_xact_lock(19920261026);
  result := public.return_final_qc_with_technician_v1(
    p_final_step_id,p_reason_id,p_technician_id,p_context_token,p_final_battery_health,p_battery_health_unavailable
  );
  select * into strict returned from greenloop_private.final_qc_failure_returns
    where inspection_id=(result->>'inspection_id')::uuid and final_step_id=p_final_step_id;

  if greenloop_private.pf_step(returned.return_step_id) is distinct from returned.job_id then
    raise exception 'The parts request does not match the returned phone.';
  end if;
  lab_cycle := greenloop_private.pf_cycle(returned.job_id);
  if lab_cycle<1 or exists (
    select 1 from greenloop_private.parts_flow_orders o where o.job_id=returned.job_id and o.cycle=lab_cycle
  ) then
    raise exception 'The new Lab / Glass visit could not be verified. Refresh the phone before returning it.' using errcode='40001';
  end if;
  if exists (
    select 1 from public.job_part_requests r
    where r.job_id=returned.job_id and r.status<>'cancelled' and greenloop_private.pp_key(r.part_name)=any(seen)
      and (r.quantity_issued<r.quantity_requested or r.quantity_issued-r.quantity_returned-r.quantity_installed>0)
  ) then
    raise exception 'A selected part already has a pending order or an uninstalled issue for this phone.' using errcode='22023';
  end if;

  -- Use the same order, request and link records read by Lab & Glass and Parts Ordered.
  -- This adds a new visit order and preserves the previous visit's installed parts.
  perform greenloop_private.pf_context(true);
  insert into greenloop_private.parts_flow_orders(job_id,device_id,step_id,cycle,submitted_by)
    values(returned.job_id,returned.device_id,returned.return_step_id,lab_cycle,auth.uid())
    returning id into order_id;
  for part in select value from jsonb_array_elements(parts) loop
    insert into public.job_part_requests(
      job_id,device_id,part_name,quantity_requested,request_source,requested_by,requested_for_technician
    ) values (
      returned.job_id,returned.device_id,part->>'name',(part->>'quantity')::integer,
      'technician_additional',auth.uid(),returned.technician_name
    ) returning id into request_id;
    insert into greenloop_private.parts_flow_requests(request_id,order_id) values(request_id,order_id);
  end loop;
  perform greenloop_private.pf_context(false);

  insert into greenloop_private.parts_flow_audit(order_id,action,actor,details)
    values(order_id,'final_qc_rework_ordered',auth.uid(),
      jsonb_build_object('inspection_id',returned.inspection_id,'parts',parts,'failure_reason',returned.reason));
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
    values(returned.device_id,returned.job_id,'final_qc_rework_parts','Final QC ordered rework parts',
      jsonb_build_object('order_id',order_id,'inspection_id',returned.inspection_id,'parts',parts,
        'failure_reason',returned.reason,'technician',returned.technician_name),auth.uid());
  return result || jsonb_build_object('parts_order_id',order_id,'parts',parts);
end;
$body$;

revoke all on function public.get_final_qc_rework_part_options_v1(),
  public.return_final_qc_with_parts_v1(uuid,uuid,uuid,text,smallint,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.get_final_qc_rework_part_options_v1(),
  public.return_final_qc_with_parts_v1(uuid,uuid,uuid,text,smallint,boolean,jsonb) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_final_qc_rework_part_options_v1','{"page":"final_qc","capability":"view","read":true}'),
  ('return_final_qc_with_parts_v1','{"page":"final_qc","capability":"entry"}')
  on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(
  select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r
) where identity='rules';

do $seal$
begin
  execute format($ddl$
    create or replace function public.get_final_qc_rework_parts_version()
    returns text language sql stable security definer set search_path=pg_catalog,public as $version$
      select case when
        md5(pg_get_functiondef(to_regprocedure('public.get_final_qc_rework_part_options_v1()')))=%L
        and md5(pg_get_functiondef(to_regprocedure('public.return_final_qc_with_parts_v1(uuid,uuid,uuid,text,smallint,boolean,jsonb)')))=%L
        and (select count(*)=2 and bool_and(
          has_function_privilege('authenticated',api,'EXECUTE') and not has_function_privilege('anon',api,'EXECUTE')
        ) from unnest(array[
          'public.get_final_qc_rework_part_options_v1()',
          'public.return_final_qc_with_parts_v1(uuid,uuid,uuid,text,smallint,boolean,jsonb)'
        ]) as routines(api))
        and (select count(*)=2 from greenloop_private.capability_rpc_rules where
          (rpc_name='get_final_qc_rework_part_options_v1' and rule='{"page":"final_qc","capability":"view","read":true}')
          or (rpc_name='return_final_qc_with_parts_v1' and rule='{"page":"final_qc","capability":"entry"}'))
      then '20261127-final-qc-rework-parts-1' end;
    $version$;
  $ddl$,md5(pg_get_functiondef('public.get_final_qc_rework_part_options_v1()'::regprocedure)),
    md5(pg_get_functiondef('public.return_final_qc_with_parts_v1(uuid,uuid,uuid,text,smallint,boolean,jsonb)'::regprocedure)));
end;
$seal$;

revoke all on function public.get_final_qc_rework_parts_version() from public,anon,authenticated;
grant execute on function public.get_final_qc_rework_parts_version() to anon,authenticated;

do $verify$
begin
  if public.get_final_qc_rework_parts_version() is distinct from '20261127-final-qc-rework-parts-1' then
    raise exception 'Final QC rework parts installation could not be verified.';
  end if;
end;
$verify$;

notify pgrst,'reload schema';
commit;
select public.get_final_qc_rework_parts_version() as installed_final_qc_rework_parts_version;
