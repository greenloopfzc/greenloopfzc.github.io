-- Audited stock metadata edits preserve the phone's custody and packing workflow.
begin;

create table if not exists greenloop_private.bulk_metadata_scope (
  backend_pid integer not null,
  transaction_id bigint not null,
  actor_id uuid not null,
  device_id uuid not null,
  job_id uuid not null,
  request_id uuid not null,
  reason text not null,
  primary key (backend_pid,transaction_id)
);
alter table greenloop_private.bulk_metadata_scope enable row level security;
revoke all on table greenloop_private.bulk_metadata_scope from public,anon,authenticated;

create or replace function greenloop_private.bca_permit(p_relation text,p_before jsonb,p_after jsonb)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $permit$
  select case p_relation
    when 'devices' then
      p_before-array['model','storage_gb','color','battery_health','battery_health_unavailable','original_grade','gc_grade','updated_at']
      =p_after-array['model','storage_gb','color','battery_health','battery_health_unavailable','original_grade','gc_grade','updated_at']
    when 'jobs' then
      p_before-array['receiving_batch_id','supplier_id','supplier_grade','updated_at']
      =p_after-array['receiving_batch_id','supplier_id','supplier_grade','updated_at']
    when 'export_box_items' then
      p_before-array['model','storage_gb','color','final_grade']
      =p_after-array['model','storage_gb','color','final_grade']
    else false end
    and exists (
      select 1 from greenloop_private.bulk_metadata_scope s
      where s.backend_pid=pg_backend_pid() and s.transaction_id=txid_current()
        and s.actor_id=auth.uid()
        and case p_relation
          when 'devices' then p_before->>'id'=s.device_id::text
          when 'jobs' then p_before->>'id'=s.job_id::text
          when 'export_box_items' then p_before->>'job_id'=s.job_id::text and p_before->>'device_id'=s.device_id::text
          else false end
    );
$permit$;
revoke all on function greenloop_private.bca_permit(text,jsonb,jsonb) from public,anon,authenticated;

create or replace function greenloop_private.bca_sync_box(p_job uuid,p_device uuid,p_patch jsonb)
returns void language sql volatile security definer set search_path=pg_catalog,public as $sync$
  update public.export_box_items item set
    model=case when p_patch?'model' then device.model else item.model end,
    storage_gb=case when p_patch?'storage_gb' then device.storage_gb else item.storage_gb end,
    color=case when p_patch?'color' then device.color else item.color end,
    final_grade=case when p_patch?'final_grade' then p_patch->>'final_grade' else item.final_grade end
  from public.devices device
  where item.job_id=p_job and item.device_id=p_device and device.id=p_device
    and (p_patch?'model' and item.model is distinct from device.model
      or p_patch?'storage_gb' and item.storage_gb is distinct from device.storage_gb
      or p_patch?'color' and item.color is distinct from device.color
      or p_patch?'final_grade' and item.final_grade is distinct from p_patch->>'final_grade');

  -- A draft or pending print must use the amended packing details.
  update greenloop_private.box_workflow workflow
  set revision=workflow.revision+1,printed_revision=null,printed_at=null,printed_by=null
  where workflow.state in ('draft','accounts','recheck')
    and p_patch ?| array['model','storage_gb','color','final_grade','batch_id']
    and exists (select 1 from public.export_box_items item
      where item.box_id=workflow.box_id and item.job_id=p_job and item.device_id=p_device);
$sync$;
revoke all on function greenloop_private.bca_sync_box(uuid,uuid,jsonb) from public,anon,authenticated;

create or replace function greenloop_private.bca_box_item_audit(p_before jsonb,p_after jsonb)
returns void language sql volatile security definer set search_path=pg_catalog,public as $audit$
  insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)
  select box.id,box.box_number,'bulk_imei_metadata_corrected',s.actor_id,
         jsonb_build_object('request_id',s.request_id,'reason',s.reason,'before',p_before,'after',p_after)
  from greenloop_private.bulk_metadata_scope s
  join public.export_boxes box on box.id=(p_before->>'box_id')::uuid
  where s.backend_pid=pg_backend_pid() and s.transaction_id=txid_current() and s.actor_id=auth.uid()
    and s.device_id=(p_before->>'device_id')::uuid and s.job_id=(p_before->>'job_id')::uuid
    and p_before is distinct from p_after;
$audit$;
revoke all on function greenloop_private.bca_box_item_audit(jsonb,jsonb) from public,anon,authenticated;

-- Keep the existing receipts for known trigger definitions and reject unrelated changes.
do $triggers$
declare
  rule record;
  routine regprocedure;
  ddl text;
  before_hash text;
  after_hash text;
  normalized_guard text;
begin
  for rule in select * from (values
    ('greenloop_private.box_source_changed()', 'box_workflow_installation',
      $body$if tg_op='UPDATE' and greenloop_private.bca_permit(tg_table_name,to_jsonb(old),to_jsonb(new)) then return new;end if;$body$),
    ('greenloop_private.box_item_changed()', 'box_workflow_installation',
      $body$if tg_op='UPDATE' and greenloop_private.bca_permit(tg_table_name,to_jsonb(old),to_jsonb(new)) then
   perform greenloop_private.bca_box_item_audit(to_jsonb(old),to_jsonb(new));
   return new;
 end if;$body$),
    ('greenloop_private.chaman_guard()', 'chaman_installation',
      $body$if tg_op='UPDATE' and tg_table_name='jobs' and greenloop_private.bca_permit(tg_table_name,to_jsonb(old),to_jsonb(new)) then return new;end if;$body$)
  ) as rules(signature,receipt,guard) loop
    routine:=to_regprocedure(rule.signature);
    ddl:=pg_get_functiondef(routine);
    if ddl is null then raise exception 'Required stock guard is missing: %',rule.signature;end if;
    normalized_guard:=replace(rule.guard,chr(13),'');
    if strpos(replace(ddl,chr(13),''),normalized_guard)>0 then continue;end if;
    before_hash:=md5(ddl);
    if rule.receipt='box_workflow_installation' then
      if not exists (select 1 from greenloop_private.box_workflow_installation
          where identity=rule.signature and hash=before_hash) then
        raise exception 'Existing box guard differs: %',rule.signature;
      end if;
    elsif not exists (select 1 from greenloop_private.chaman_installation
        where identity=rule.signature and hash=before_hash) then
      raise exception 'Existing Chaman guard differs: %',rule.signature;
    end if;
    if cardinality(string_to_array(ddl,'begin'))<>2 then
      raise exception 'Stock guard entry differs: %',rule.signature;
    end if;
    execute replace(ddl,'begin','begin'||chr(10)||normalized_guard||chr(10));
    after_hash:=md5(pg_get_functiondef(routine));
    update greenloop_private.box_workflow_installation set hash=after_hash
    where identity=rule.signature and hash=before_hash;
    update greenloop_private.chaman_installation set hash=after_hash
    where identity=rule.signature and hash=before_hash;
    if to_regclass('greenloop_private.receipt_supplier_installation') is not null then
      update greenloop_private.receipt_supplier_installation set hash=after_hash
      where identity=rule.signature and hash=before_hash;
    end if;
  end loop;
end;
$triggers$;

-- Corrections without an operational target remain recorded on the job.
create table if not exists greenloop_private.bulk_recorded_values (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  values jsonb not null
);
alter table greenloop_private.bulk_recorded_values enable row level security;
revoke all on table greenloop_private.bulk_recorded_values from public,anon,authenticated;

create or replace function greenloop_private.bca_record(
  p_job uuid,p_patch jsonb,p_original jsonb,p_native_grade boolean,p_native_bh boolean,p_native_tech boolean,p_native_work boolean
) returns void language plpgsql security definer set search_path=pg_catalog,public as $record$
declare
  corrected jsonb:='{}';
  native_keys text[]:='{}';
  technician_name text;
  field text;
  items jsonb;
begin
  if p_patch?'final_grade' then
    if p_native_grade then native_keys:=array_append(native_keys,'final_grade');
    else corrected:=corrected||jsonb_build_object('final_grade',p_patch->'final_grade');end if;
  end if;
  if p_patch?'final_bh' then
    if p_native_bh then native_keys:=array_append(native_keys,'final_bh');
    else corrected:=corrected||jsonb_build_object('final_bh',p_patch->'final_bh');end if;
  end if;
  if p_patch?'technician_id' then
    select t.full_name into technician_name from public.technician_roster t
    where t.id=(p_patch->>'technician_id')::uuid and t.is_active;
    if not found then raise exception 'Choose an active technician.' using errcode='22023';end if;
    if p_native_tech then native_keys:=native_keys||array['technician_id','technician'];
    else corrected:=corrected||jsonb_build_object('technician_id',p_patch->'technician_id','technician',technician_name);end if;
  end if;
  foreach field in array array['parts','services'] loop
    continue when not p_patch?field;
    if p_native_work then
      native_keys:=array_append(native_keys,field);
    else
      items:=p_patch->field;
      if jsonb_typeof(items)<>'array' then raise exception 'Choose valid %.',field using errcode='22023';end if;
      if exists (select 1 from jsonb_array_elements(items) item
        where jsonb_typeof(item)<>'string' or length(item#>>'{}') not between 1 and 120)
        or exists (select 1 from jsonb_array_elements_text(items) name group by greenloop_private.pp_key(name) having count(*)>1)
      then raise exception 'Choose valid, unique %.',field using errcode='22023';end if;
      if exists (select 1 from jsonb_array_elements_text(items) selected(name)
        where not coalesce((p_original->field)?selected.name,false)
          and not (case field
            when 'parts' then exists (select 1 from public.entry_options
              where option_group='part_name' and is_active and option_value=selected.name)
            else exists (select 1 from greenloop_private.qc_service_options service where service.name=selected.name)
          end))
      then raise exception 'Choose recorded or listed %.',field using errcode='22023';end if;
      corrected:=corrected||jsonb_build_object(field,items);
    end if;
  end loop;
  if corrected='{}'::jsonb then
    update greenloop_private.bulk_recorded_values set values=values-native_keys
    where job_id=p_job and values ?| native_keys;
  else
    insert into greenloop_private.bulk_recorded_values as current(job_id,values) values(p_job,corrected)
    on conflict(job_id) do update set values=(current.values-native_keys)||excluded.values;
  end if;
end;
$record$;
revoke all on function greenloop_private.bca_record(uuid,jsonb,jsonb,boolean,boolean,boolean,boolean) from public,anon,authenticated;

do $bulk$
declare
  edit record;
  fragment record;
  ddl text;
  before_hash text;
  after_hash text;
  routine regprocedure;
begin
  if to_regprocedure('public.get_bulk_all_stage_corrections_version()') is not null then return;end if;
  if public.get_bulk_locked_final_bh_version() is distinct from '20261123-bulk-locked-final-bh-1' then
    raise exception 'Install the verified Bulk Final BH Correction first.';
  end if;

  for edit in select * from (values
    ('greenloop_private.bcg_row(jsonb)',jsonb_build_array(
      jsonb_build_array('battery record;', 'battery record;recorded jsonb;native_tech boolean;native_work boolean;'),
      jsonb_build_array('return p_row||jsonb_build_object(',
        $new$native_tech:=coalesce((p_row->>'can_change_technician')::boolean,false);
  native_work:=p_row->>'read_only_reason' is null and coalesce(p_row->>'work_mode','none')<>'none';
  select values into recorded from greenloop_private.bulk_recorded_values where job_id=(p_row->>'job_id')::uuid;
  recorded:=coalesce(recorded,'{}'::jsonb);
  if native_tech then recorded:=recorded-array['technician_id','technician'];end if;
  if native_work then recorded:=recorded-array['parts','services'];end if;
  if battery.id is not null then recorded:=recorded-'final_bh';end if;
  if target is not null then recorded:=recorded-'final_grade';end if;
  return p_row||jsonb_build_object('can_edit_all_values',true,'native_technician',native_tech,'native_work',native_work,$new$),
      jsonb_build_array($old$'battery',to_jsonb(battery)$old$, $new$'battery',to_jsonb(battery),'recorded',recorded$new$),
      jsonb_build_array($old$'final_bh',case when not coalesce(battery.unavailable,false) then battery.health end
   )$old$,
        $new$'final_bh',case when not coalesce(battery.unavailable,false) then battery.health end
   )||recorded$new$)
    )),
    ('greenloop_private.bcg_save(jsonb,text,text,uuid)',jsonb_build_array(
      jsonb_build_array('final_bh_only boolean;begin','final_bh_only boolean;native_tech boolean;native_work boolean;begin'),
      jsonb_build_array('perform pg_advisory_xact_lock(20420261026);','perform pg_advisory_xact_lock(16320261010);perform pg_advisory_xact_lock(20420261026);'),
      jsonb_build_array($old$if old->>'read_only_reason' is not null$old$,
                        $new$if old->>'read_only_reason' is not null and not coalesce((old->>'can_edit_all_values')::boolean,false)$new$),
      jsonb_build_array($old$or not(old->>'has_final_bh')::boolean$old$,''),
      jsonb_build_array($old$if not coalesce((old->>'has_final_grade')::boolean,false)then raise exception 'Final Grade correction requires an unboxed phone in Ready Stock with one verified outcome.'using errcode='22023';end if;$old$,''),
      jsonb_build_array($old$if not(old->>'can_change_receipt')::boolean then raise exception 'This phone already has downstream work. Use Full Workflow Correction for linked receipt changes.'using errcode='22023';end if;$old$,''),
      jsonb_build_array('perform greenloop_private.pf_context(true);',
        $new$perform greenloop_private.pf_context(true);
 insert into greenloop_private.bulk_metadata_scope values(pg_backend_pid(),txid_current(),auth.uid(),dev,job,p_request_id,btrim(p_reason));
 native_tech:=coalesce((old->>'native_technician')::boolean,false);
 native_work:=coalesce((old->>'native_work')::boolean,false);
 target:=greenloop_private.bcg_target(job,dev);
 select * into battery from greenloop_private.bcg_battery_target(job,dev);
 perform greenloop_private.bca_record(job,patch,old->'values',target is not null,battery.id is not null,native_tech,native_work);$new$),
      jsonb_build_array($old$if patch?'final_bh'then
 select * into battery from greenloop_private.bcg_battery_target(job,dev);$old$,
                        $new$if patch?'final_bh' and battery.id is not null then$new$),
      jsonb_build_array($old$if patch?'final_grade'then
 target:=greenloop_private.bcg_target(job,dev);$old$, $new$if patch?'final_grade' and target is not null then$new$),
      jsonb_build_array($old$if patch?'parts'or patch?'services'then perform greenloop_private.bci_work$old$,
                        $new$if native_work and (patch?'parts'or patch?'services') then perform greenloop_private.bci_work$new$),
      jsonb_build_array($old$if patch?'technician_id'and patch->'technician_id'is distinct from old->'values'->'technician_id'then$old$,
                        $new$if native_tech and patch?'technician_id'and patch->'technician_id'is distinct from old->'values'->'technician_id'then$new$),
      jsonb_build_array('nowrow:=greenloop_private.bcg_row',
        $new$perform greenloop_private.bca_sync_box(job,dev,patch);
 delete from greenloop_private.bulk_metadata_scope where backend_pid=pg_backend_pid() and transaction_id=txid_current();
 nowrow:=greenloop_private.bcg_row$new$)
    ))
  ) as edits(signature,replacements) loop
    routine:=to_regprocedure(edit.signature);
    ddl:=replace(pg_get_functiondef(routine),chr(13),'');
    before_hash:=md5(pg_get_functiondef(routine));
    for fragment in select replace(value->>0,chr(13),'') as old_text,replace(value->>1,chr(13),'') as new_text
      from jsonb_array_elements(edit.replacements) loop
      if cardinality(string_to_array(ddl,fragment.old_text)) is distinct from 2 then
        raise exception 'Reviewed Bulk IMEI code block differs in %: %',edit.signature,left(fragment.old_text,65);
      end if;
      ddl:=replace(ddl,fragment.old_text,fragment.new_text);
    end loop;
    execute ddl;
    after_hash:=md5(pg_get_functiondef(routine));
    update greenloop_private.bulk_final_grade_installation set hash=after_hash where identity=edit.signature and hash=before_hash;
    update greenloop_private.office_routines set original_hash=after_hash
    where to_regprocedure(implementation)=routine and original_hash=before_hash;
    if to_regclass('greenloop_private.chaman_bulk_return_installation') is not null then
      update greenloop_private.chaman_bulk_return_installation set hash=after_hash
      where identity=edit.signature and hash=before_hash;
    end if;
  end loop;
end;
$bulk$;

do $display$
declare
  sig text:='greenloop_private.itc_enrich(jsonb,uuid,uuid)';
  routine regprocedure:=to_regprocedure(sig);
  ddl text:=pg_get_functiondef(routine);
  before_hash text:=md5(ddl);
  after_hash text;
  anchor text:=$old$return jsonb_set(data,'{device}',$old$;
begin
  if strpos(ddl,'bulk_recorded_values')=0 then
    if not exists (select 1 from greenloop_private.imei_grade_audit_installation
        where identity=sig and hash=before_hash)
      or cardinality(string_to_array(ddl,anchor)) is distinct from 2 then
      raise exception 'Existing IMEI Search result source could not be verified.';
    end if;
    ddl:=replace(ddl,anchor,$new$if q.at is null then
  select (r.values->>'final_bh')::smallint,r.values->>'final_grade' into q.bh,q.grade
  from greenloop_private.bulk_recorded_values r where r.job_id=latest_job;
  if q.bh is not null or q.grade is not null then
    q.unavailable:=false;
    q.source:='Reports correction';
  end if;
 end if;
 return jsonb_set(data,'{device}',$new$);
    execute ddl;
    after_hash:=md5(pg_get_functiondef(routine));
    update greenloop_private.imei_grade_audit_installation set hash=after_hash where identity=sig and hash=before_hash;
    update greenloop_private.imei_qc_corrections_installation set hash=after_hash where identity=sig and hash=before_hash;
    update greenloop_private.imei_correction_sources_installation set hash=after_hash where identity=sig and hash=before_hash;
  end if;

  sig:='public.get_accounts_verify_box_detail_v1(uuid)';
  routine:=to_regprocedure(sig);
  ddl:=pg_get_functiondef(routine);
  if strpos(ddl,'bulk_recorded_values')=0 then
    anchor:=' ) battery on true;';
    if public.get_accounts_box_final_bh_version() is distinct from '20261123-accounts-box-final-bh-1'
      or strpos(ddl,anchor)=0
      or strpos(ddl,'then battery.health end')=0 then
      raise exception 'Existing Accounts Final BH result source could not be verified.';
    end if;
    execute replace(
      replace(ddl,'then battery.health end',
        $new$then case when battery.recorded_at is null
              then (recorded.values->>'final_bh')::smallint else battery.health end end$new$),
      anchor,
      ' ) battery on true left join greenloop_private.bulk_recorded_values recorded on recorded.job_id=item.job_id;'
    );
  end if;
end;
$display$;

create or replace function public.get_bulk_all_stage_corrections_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when public.get_bulk_locked_final_bh_version()='20261123-bulk-locked-final-bh-1'
    and strpos(pg_get_functiondef('greenloop_private.bcg_save(jsonb,text,text,uuid)'::regprocedure),'bca_sync_box')>0
    and strpos(pg_get_functiondef('greenloop_private.bcg_row(jsonb)'::regprocedure),'can_edit_all_values')>0
    and strpos(pg_get_functiondef('greenloop_private.box_item_changed()'::regprocedure),'bca_box_item_audit')>0
    and strpos(pg_get_functiondef('greenloop_private.chaman_guard()'::regprocedure),'bca_permit')>0
    and not exists (
      select 1 from unnest(array[
        'greenloop_private.bca_permit(text,jsonb,jsonb)',
        'greenloop_private.bca_sync_box(uuid,uuid,jsonb)',
        'greenloop_private.bca_box_item_audit(jsonb,jsonb)',
        'greenloop_private.bca_record(uuid,jsonb,jsonb,boolean,boolean,boolean,boolean)'
      ]) fn
      where has_function_privilege('anon',fn,'EXECUTE') or has_function_privilege('authenticated',fn,'EXECUTE')
    )
    then '20261123-bulk-all-stage-corrections-1' end;
$version$;
revoke all on function public.get_bulk_all_stage_corrections_version() from public;
grant execute on function public.get_bulk_all_stage_corrections_version() to anon,authenticated;

do $verify$
begin
  if public.get_bulk_all_stage_corrections_version() is distinct from '20261123-bulk-all-stage-corrections-1' then
    raise exception 'Bulk IMEI across stages could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_bulk_all_stage_corrections_version() as installed_bulk_all_stage_corrections_version;
