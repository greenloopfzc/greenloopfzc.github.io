-- Final BH is a correction to a saved battery result, independent of stock custody.
begin;

create or replace function greenloop_private.bcg_battery_target(p_job uuid,p_device uuid)
returns table(kind text,id uuid,health smallint,unavailable boolean)
language sql stable security definer set search_path=pg_catalog,public as $target$
  with outcomes as (
    select 'final_qc'::text as kind,inspection.id,
           inspection.final_battery_health as health,inspection.final_battery_health_unavailable as unavailable,
           inspection.inspected_at as recorded_at,0 as source_order
    from public.final_qc_inspections inspection
    where inspection.job_id=p_job and inspection.device_id=p_device
      and not (coalesce(inspection.routed_to_frame,false)
               and strpos(coalesce(inspection.notes,''),'Initial QC direct route to Frame')>0)
    union all
    select 'direct_ready',ready.job_id,ready.battery_health,ready.battery_health_unavailable,ready.ready_at,1
    from greenloop_private.qc_direct_ready ready
    where ready.job_id=p_job and ready.device_id=p_device
  )
  select outcome.kind,outcome.id,outcome.health,outcome.unavailable
  from outcomes outcome
  order by outcome.recorded_at desc nulls last,outcome.source_order,outcome.id desc
  limit 1;
$target$;
revoke all on function greenloop_private.bcg_battery_target(uuid,uuid) from public,anon,authenticated;

do $upgrade$
declare
  edit record;
  fragment record;
  routine regprocedure;
  definition text;
  before_hash text;
  after_hash text;
  step_count integer;
begin
  perform set_config('lock_timeout','5s',true);
  if to_regprocedure('public.get_bulk_locked_final_bh_version()') is not null then
    if public.get_bulk_locked_final_bh_version() is distinct from '20261123-bulk-locked-final-bh-1' then
      raise exception 'Existing Final BH correction could not be verified.';
    end if;
    return;
  end if;

  for edit in
    select * from (values
      ('greenloop_private.bcg_row(jsonb)',jsonb_build_array(
        jsonb_build_array('declare target jsonb;ready boolean;',
                          'declare target jsonb;ready boolean;battery record;'),
        jsonb_build_array('return p_row||jsonb_build_object',
          $new$select * into battery from greenloop_private.bcg_battery_target((p_row->>'job_id')::uuid,(p_row->>'device_id')::uuid);
  return p_row||jsonb_build_object$new$),
        jsonb_build_array($old$'native',p_row->>'revision','final',target$old$,
                          $new$'native',p_row->>'revision','final',target,'battery',to_jsonb(battery)$new$),
        jsonb_build_array($old$'values',(p_row->'values')||jsonb_build_object('final_grade',target->>'final_grade')$old$,
          $new$'has_final_bh',battery.id is not null,
   'can_correct_locked_final_bh',battery.id is not null and p_row->>'read_only_reason' is not null,
   'values',(p_row->'values')||jsonb_build_object(
     'final_grade',target->>'final_grade',
     'final_bh',case when not coalesce(battery.unavailable,false) then battery.health end
   )$new$)
      )),
      ('greenloop_private.bcg_save(jsonb,text,text,uuid)',jsonb_build_array(
        jsonb_build_array('target jsonb;begin',
                          'target jsonb;battery record;final_bh_only boolean;begin'),
        jsonb_build_array($old$if old->>'read_only_reason'is not null then raise exception '%',old->>'read_only_reason'using errcode='22023';end if;$old$,''),
        jsonb_build_array('v:=(old->''values'')||patch;',
          $new$final_bh_only:=patch?'final_bh' and (patch-'final_bh')='{}'::jsonb;
 if old->>'read_only_reason' is not null
    and not (final_bh_only and coalesce((old->>'can_correct_locked_final_bh')::boolean,false)) then
   raise exception '%',old->>'read_only_reason' using errcode='22023';
 end if;
 v:=(old->'values')||patch;$new$),
        jsonb_build_array($old$if nullif(btrim(v->>'model'),'')is null or length(v->>'model')>120 or length(coalesce(v->>'color',''))>120 or(v->>'storage_gb')is null or(v->>'storage_gb')::integer not between 1 and 16384 then$old$,
          $new$if not final_bh_only and (nullif(btrim(v->>'model'),'')is null or length(v->>'model')>120 or length(coalesce(v->>'color',''))>120 or(v->>'storage_gb')is null or(v->>'storage_gb')::integer not between 1 and 16384) then$new$),
        jsonb_build_array('update public.devices set model=case', 'if not final_bh_only then update public.devices set model=case'),
        jsonb_build_array($old$else gc_grade end where id=dev;$old$, $new$else gc_grade end where id=dev;end if;$new$),
        jsonb_build_array(
          $old$if exists(select 1 from public.final_qc_inspections where job_id=job)then update public.final_qc_inspections set final_battery_health=(v->>'final_bh')::smallint,final_battery_health_unavailable=false where id=(select id from public.final_qc_inspections where job_id=job order by inspected_at desc,created_at desc,id desc limit 1);
 else update greenloop_private.qc_direct_ready set battery_health=(v->>'final_bh')::smallint where job_id=job;end if;end if;$old$,
          $new$select * into battery from greenloop_private.bcg_battery_target(job,dev);
  if battery.kind='final_qc' then
    update public.final_qc_inspections
    set final_battery_health=(v->>'final_bh')::smallint,final_battery_health_unavailable=false
    where id=battery.id and job_id=job and device_id=dev;
  elsif battery.kind='direct_ready' then
    update greenloop_private.qc_direct_ready
    set battery_health=(v->>'final_bh')::smallint,battery_health_unavailable=false
    where job_id=battery.id and job_id=job and device_id=dev;
  else
    raise exception 'Final BH requires an existing result.' using errcode='22023';
  end if;
  if not found then
    raise exception 'The battery result changed. Reload before saving.' using errcode='40001';
  end if;
 end if;$new$)
      ))
    ) as reviewed(signature,changes)
  loop
    routine:=to_regprocedure(edit.signature);
    definition:=pg_get_functiondef(routine);
    before_hash:=md5(definition);
    if not exists (
      select 1 from greenloop_private.bulk_final_grade_installation
      where identity=edit.signature and hash=before_hash
    ) then
      raise exception 'Existing Bulk IMEI routine differs: %',edit.signature;
    end if;
    definition:=replace(definition,chr(13),'');
    for fragment in
      select replace(value->>0,chr(13),'') as old_text,replace(value->>1,chr(13),'') as new_text
      from jsonb_array_elements(edit.changes)
    loop
      step_count:=cardinality(string_to_array(definition,fragment.old_text));
      if step_count is distinct from 2 then
        raise exception 'Bulk IMEI correction could not find one reviewed code block in %',edit.signature;
      end if;
      definition:=replace(definition,fragment.old_text,fragment.new_text);
    end loop;
    execute definition;
    after_hash:=md5(pg_get_functiondef(routine));
    update greenloop_private.bulk_final_grade_installation set hash=after_hash
    where identity=edit.signature and hash=before_hash;
    update greenloop_private.office_routines set original_hash=after_hash
    where to_regprocedure(implementation)=routine and original_hash=before_hash;
    if to_regclass('greenloop_private.chaman_bulk_return_installation') is not null then
      update greenloop_private.chaman_bulk_return_installation set hash=after_hash
      where identity=edit.signature and hash=before_hash;
    end if;
  end loop;
end;
$upgrade$;

create or replace function public.get_bulk_locked_final_bh_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when not has_function_privilege('anon','greenloop_private.bcg_battery_target(uuid,uuid)','EXECUTE')
    and not has_function_privilege('authenticated','greenloop_private.bcg_battery_target(uuid,uuid)','EXECUTE')
    and (
      select count(*)=2 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))
        and strpos(pg_get_functiondef(to_regprocedure(identity)),'can_correct_locked_final_bh')>0)
      from greenloop_private.bulk_final_grade_installation
      where identity in ('greenloop_private.bcg_row(jsonb)','greenloop_private.bcg_save(jsonb,text,text,uuid)')
    )
    then '20261123-bulk-locked-final-bh-1' end;
$version$;
revoke all on function public.get_bulk_locked_final_bh_version() from public;
grant execute on function public.get_bulk_locked_final_bh_version() to anon,authenticated;

do $verify$
begin
  if public.get_bulk_locked_final_bh_version() is distinct from '20261123-bulk-locked-final-bh-1' then
    raise exception 'Final BH correction could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_bulk_locked_final_bh_version() as installed_bulk_locked_final_bh_version;
