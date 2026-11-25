-- Delete a reviewed, unverified box through the existing audited phone restore.
begin;
set local lock_timeout='5s';

do $check$ begin
  if to_regprocedure('greenloop_private.valid_deletion_code(text)') is null
    or to_regprocedure('public.get_deletion_code_version()') is null
    or to_regprocedure('public.delete_export_box_with_restore(uuid,text)') is null then
    raise exception 'Install the existing deletion code and box restore update first.';
  end if;
  if public.get_deletion_code_version() is distinct from '20261124-delete-code-1' then
    raise exception 'The existing deletion code update could not be verified.';
  end if;
end; $check$;

create index if not exists box_unverified_deletion_audit_idx
  on greenloop_private.box_workflow_audit (box_id,action)
  where action in ('unverified_box_deleted','verified_exported');

create or replace function public.delete_unverified_box_v1(
  p_box_id uuid,p_revision integer,p_state text,p_delete_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $delete$
declare
  box public.export_boxes%rowtype;
  workflow greenloop_private.box_workflow%rowtype;
  restored integer;
  phones jsonb;
  result jsonb;
begin
  perform greenloop_private.require_box_review_cap('export_boxes','view');
  perform greenloop_private.require_box_review_cap('export_boxes','delete');
  if not coalesce(public.has_role(array[
    'super_admin','owner','manager','production','shipping'
  ]::public.app_role_key[]),false) then
    raise exception 'You do not have permission to delete export boxes.' using errcode='42501';
  end if;
  if p_box_id is null or p_revision is null or p_state is null or p_state not in ('accounts','recheck') then
    raise exception 'Open a Pending Verification or Recheck box first.' using errcode='22023';
  end if;

  -- Same serialization and row locks as verify, recheck, and scan.
  perform pg_advisory_xact_lock(16320261010);
  select * into box from public.export_boxes where id=p_box_id for update;
  if not found then
    select a.details->'result' into result from greenloop_private.box_workflow_audit a
    where a.box_id=p_box_id and a.action='unverified_box_deleted' and a.actor=auth.uid()
      and a.details->'revision'=to_jsonb(p_revision) and a.details->>'previous_state'=p_state;
    if result is null then
      raise exception 'Box is no longer available. Refresh Box Status.' using errcode='22023';
    end if;
    if not coalesce(greenloop_private.valid_deletion_code(p_delete_code),false) then
      raise exception 'Incorrect deletion code.' using errcode='42501';
    end if;
    return result;
  end if;

  select * into workflow from greenloop_private.box_workflow where box_id=p_box_id for update;
  if workflow.state is distinct from p_state or workflow.revision is distinct from p_revision
    or workflow.verified_at is not null or exists (
      select 1 from greenloop_private.box_workflow_audit
      where box_id=p_box_id and action='verified_exported'
    ) then
    raise exception 'Box changed or was verified. Reload Box Status before continuing.' using errcode='40001';
  end if;

  perform 1
  from public.export_box_items i
  join public.jobs j on j.id=i.job_id
  join public.devices d on d.id=i.device_id
  where i.box_id=p_box_id
  order by i.id
  for update of j,d;
  if exists (
    select 1 from public.export_box_items i
    join public.jobs j on j.id=i.job_id
    join public.devices d on d.id=i.device_id
    where i.box_id=p_box_id
      and (j.device_id<>d.id or j.deleted_at is not null or d.deleted_at is not null
           or j.current_status<>'accounts_pending' or d.current_status<>'accounts_pending')
  ) then
    raise exception 'A phone in this box changed stage. Reload Box Status before continuing.' using errcode='40001';
  end if;

  select coalesce(jsonb_agg(i.imei order by i.serial_no,i.id),'[]'::jsonb)
    into phones from public.export_box_items i where i.box_id=p_box_id;

  select deleted.restored_items into strict restored
    from public.delete_export_box_with_restore(p_box_id,p_delete_code) deleted;
  if restored is distinct from jsonb_array_length(phones) then
    raise exception 'The box phone count could not be reconciled. Nothing was deleted.';
  end if;

  result:=jsonb_build_object('deleted_box_number',box.box_number,'restored_items',restored);
  insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)
  values(p_box_id,box.box_number,'unverified_box_deleted',auth.uid(),
    jsonb_build_object('revision',p_revision,'previous_state',p_state,'imeis',phones,'result',result));
  return result;
end;
$delete$;
revoke all on function public.delete_unverified_box_v1(uuid,integer,text,text) from public,anon;
grant execute on function public.delete_unverified_box_v1(uuid,integer,text,text) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('delete_unverified_box_v1','{"page":"export_boxes","capability":"delete"}'),
  ('get_delete_unverified_box_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;

create or replace function public.get_delete_unverified_box_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when to_regprocedure('greenloop_private.valid_deletion_code(text)') is not null
    and to_regclass('greenloop_private.box_unverified_deletion_audit_idx') is not null
    and has_function_privilege('authenticated','public.delete_unverified_box_v1(uuid,integer,text,text)','EXECUTE')
    and not has_function_privilege('anon','public.delete_unverified_box_v1(uuid,integer,text,text)','EXECUTE')
    and exists (select 1 from pg_proc where oid=to_regprocedure('public.delete_unverified_box_v1(uuid,integer,text,text)')
      and prosecdef and strpos(prosrc,'public.delete_export_box_with_restore(')>0
      and strpos(prosrc,'pg_advisory_xact_lock(16320261010)')>0)
    then '20261125-delete-unverified-box-1' end;
$version$;
revoke all on function public.get_delete_unverified_box_version() from public,anon,authenticated;
grant execute on function public.get_delete_unverified_box_version() to anon,authenticated;

do $verify$ begin
  if public.get_delete_unverified_box_version() is distinct from '20261125-delete-unverified-box-1' then
    raise exception 'Could not verify unverified-box deletion.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_delete_unverified_box_version() as installed_delete_unverified_box_version;
