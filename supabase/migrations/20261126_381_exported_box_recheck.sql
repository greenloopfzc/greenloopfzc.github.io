begin;
set local lock_timeout = '5s';

do $dependencies$ begin
  if to_regprocedure('public.get_box_recheck_imei_controls_version()') is null then
    raise exception 'Install the Box Recheck IMEI controls update first.';
  end if;
  if public.get_box_recheck_imei_controls_version() is distinct from '20261125-box-recheck-imei-controls-1' then
    raise exception 'Install the Box Recheck IMEI controls update first.';
  end if;
end; $dependencies$;

-- Existing Edit grants do not imply permission to reopen a verified box.
do $install$
declare
  capability_function regprocedure := 'greenloop_private.user_capabilities(uuid)'::regprocedure;
  definition text := replace(pg_get_functiondef(capability_function), chr(13), '');
  previous_hash text := md5(pg_get_functiondef(capability_function));
  condition text := 'where level=''edit'' or c->>''key''=''view''';
  replacement text := $condition$where (level='edit' and (c->>'key' <> 'recheck_exported' or exists (
    select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
    where ur.user_id=p_user_id and r.role_key::text='super_admin'
  ))) or c->>'key'='view'$condition$;
begin
  if not exists (select 1 from greenloop_private.page_capability_catalog where page_key='stock_exported') then
    raise exception 'The Stock Exported permission catalog is missing.';
  end if;
  if strpos(definition, replacement)=0 then
    if (length(definition)-length(replace(definition,condition,'')))/length(condition)<>1 then
      raise exception 'Could not identify the current default page permissions.';
    end if;
    execute replace(definition,condition,replacement);
    update greenloop_private.page_capability_installation set hash=md5(pg_get_functiondef(capability_function))
      where identity=capability_function::text and hash=previous_hash;
    update greenloop_private.content_permissions_installation set hash=md5(pg_get_functiondef(capability_function))
      where identity=capability_function::text and hash=previous_hash;
  end if;

  if not exists (select 1 from greenloop_private.page_capability_catalog
                 where page_key='stock_exported' and capabilities @> '[{"key":"recheck_exported"}]') then
    update greenloop_private.page_capability_catalog
    set capabilities=capabilities || '[{"key":"recheck_exported","label":"Send exported boxes for recheck","write":true}]'
    where page_key='stock_exported';

    update greenloop_private.user_page_capabilities uc
    set capabilities=jsonb_set(uc.capabilities,'{stock_exported}',uc.capabilities->'stock_exported' || '["recheck_exported"]')
    where uc.capabilities->'stock_exported' ? 'view' and not uc.capabilities->'stock_exported' ? 'recheck_exported'
      and exists (select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
                  where ur.user_id=uc.user_id and r.role_key::text='super_admin');
  end if;
end;
$install$;

-- Box Entry already prohibits deletion of previously verified boxes. Expose
-- that decision on the rendered page without handing clients the audit rows.
create index if not exists box_unverified_deletion_audit_idx
  on greenloop_private.box_workflow_audit (box_id,action)
  where action in ('unverified_box_deleted','verified_exported');

do $box_reads$
declare
  target record;
  read_implementation regprocedure;
  definition text;
  previous_hash text;
  next_hash text;
begin
  for target in select * from (values
    ('public.get_box_status_v1(jsonb,integer,integer,text,text)',
     'jsonb_agg(to_jsonb(p)) from page_rows p',
     $list$jsonb_agg(to_jsonb(p) || jsonb_build_object('previously_verified',p.raw_state in ('accounts','recheck') and exists (
       select 1 from greenloop_private.box_workflow_audit a where a.box_id=p.id and a.action='verified_exported'
     ))) from page_rows p$list$),
    ('public.get_box_entry_review_v1(uuid)',
     $anchor$'recheck_count',w.recheck_count$anchor$,
     $detail$'recheck_count',w.recheck_count,'previously_verified',w.state in ('accounts','recheck') and exists (
       select 1 from greenloop_private.box_workflow_audit a where a.box_id=p_box_id and a.action='verified_exported'
     )$detail$)
  ) as t(signature,anchor,replacement) loop
    select to_regprocedure(o.implementation) into strict read_implementation from greenloop_private.office_routines o
    where to_regprocedure(o.identity)=to_regprocedure(target.signature);
    definition:=pg_get_functiondef(read_implementation);
    if strpos(definition,target.replacement)>0 then continue; end if;
    if (length(definition)-length(replace(definition,target.anchor,'')))/length(target.anchor)<>1 then
      raise exception 'Could not identify the Box Entry response for %.',target.signature;
    end if;
    previous_hash:=md5(definition);
    execute replace(definition,target.anchor,target.replacement);
    next_hash:=md5(pg_get_functiondef(read_implementation));
    update greenloop_private.office_routines o set original_hash=next_hash
      where to_regprocedure(o.implementation)=read_implementation and original_hash=previous_hash;
    update greenloop_private.qc_direct_ready_installation q set hash=next_hash
      where to_regprocedure(q.identity)=read_implementation and q.hash=previous_hash;
    if to_regclass('greenloop_private.stock_bulk_search_installation') is not null then
      update greenloop_private.stock_bulk_search_installation s set hash=next_hash
        where to_regprocedure(s.identity)=read_implementation and s.hash=previous_hash;
    end if;
  end loop;
end;
$box_reads$;

create or replace function public.request_exported_box_recheck_v1(
  p_box_id uuid, p_revision integer, p_reason text
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $recheck$
declare
  box public.export_boxes%rowtype;
  workflow greenloop_private.box_workflow%rowtype;
  actor uuid := auth.uid();
  reason text := btrim(coalesce(p_reason,''));
  box_entry_location uuid;
  outbound_location uuid;
  phone_count integer;
begin
  perform greenloop_private.require_box_review_cap('stock_exported','view');
  perform greenloop_private.require_box_review_cap('stock_exported','recheck_exported');
  if length(reason) not between 2 and 1000 then
    raise exception 'Enter the reason for Recheck (2 to 1000 characters).' using errcode='22023';
  end if;

  -- Serialize against Box Entry and Accounts verification.
  perform pg_advisory_xact_lock(16320261010);
  select * into box from public.export_boxes where id=p_box_id for update;
  select * into workflow from greenloop_private.box_workflow where box_id=p_box_id for update;
  if box.id is null or workflow.box_id is null then
    raise exception 'This box is no longer available. Reload Stock Exported.' using errcode='22023';
  end if;
  if p_revision is distinct from workflow.revision then
    raise exception 'Box changed. Reload Stock Exported before requesting Recheck.' using errcode='40001';
  end if;
  if workflow.state is distinct from 'exported' or workflow.verified_at is null then
    raise exception 'Only a box that Accounts verified can be returned from Stock Exported.' using errcode='22023';
  end if;

  select id into box_entry_location from public.locations where location_code='BOX-ENTRY' and is_active;
  select id into outbound_location from public.locations where location_code='OUTBOUND' and is_active;
  if box_entry_location is null or outbound_location is null then
    raise exception 'Box Entry and Outbound locations must be active.';
  end if;

  perform 1 from public.export_box_items i
    join public.jobs j on j.id=i.job_id join public.devices d on d.id=i.device_id
    where i.box_id=p_box_id order by i.id for update of i,j,d;
  get diagnostics phone_count = row_count;
  if phone_count=0 then
    raise exception 'This box has no phones to return for Recheck.' using errcode='22023';
  end if;
  if exists (
    select 1 from public.export_box_items i
    left join public.jobs j on j.id=i.job_id left join public.devices d on d.id=i.device_id
    where i.box_id=p_box_id and (
      j.id is null or d.id is null or j.device_id is distinct from d.id
      or j.deleted_at is not null or d.deleted_at is not null
      or j.current_status is distinct from 'shipped' or d.current_status is distinct from 'shipped'
      or j.current_location_id is distinct from outbound_location
      or d.current_location_id is distinct from outbound_location
    )
  ) then
    raise exception 'A phone in this box changed stage. Reload Stock Exported before continuing.' using errcode='40001';
  end if;

  perform greenloop_private.begin_capability('request_exported_box_recheck_v1','{}');
  update greenloop_private.box_workflow
  set state='recheck', revision=revision+1, printed_revision=null, printed_at=null, printed_by=null,
      recheck_reason=reason, recheck_at=now(), recheck_by=actor, recheck_count=recheck_count+1,
      verified_at=null, verified_by=null
  where box_id=p_box_id;

  insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by)
  select device_id,job_id,outbound_location,box_entry_location,'Exported box returned for Recheck',box.box_number,actor
  from public.export_box_items where box_id=p_box_id;

  update public.jobs j set current_status='accounts_pending', current_location_id=box_entry_location,
      closed_at=null, customer_id=null
  from public.export_box_items i where i.box_id=p_box_id and j.id=i.job_id;
  update public.devices d set current_status='accounts_pending', current_location_id=box_entry_location
  from public.export_box_items i where i.box_id=p_box_id and d.id=i.device_id;

  insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)
  values(p_box_id,box.box_number,'exported_recheck_requested',actor,jsonb_build_object(
    'reason',reason,'reviewed_revision',p_revision,'phone_count',phone_count,
    'previous_verified_at',workflow.verified_at,'previous_verified_by',workflow.verified_by,
    'previous_customer_id',workflow.customer_id,'previous_customer_code',workflow.customer_code
  ));
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
  select device_id,job_id,'box_returned_for_recheck','Exported box returned for Recheck',
    jsonb_build_object('box_number',box.box_number,'reason',reason,'next_status','accounts_pending'),actor
  from public.export_box_items where box_id=p_box_id;
  perform greenloop_private.end_capability();
  return true;
end;
$recheck$;
revoke all on function public.request_exported_box_recheck_v1(uuid,integer,text) from public,anon,authenticated;
grant execute on function public.request_exported_box_recheck_v1(uuid,integer,text) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('request_exported_box_recheck_v1','{"page":"stock_exported","capability":"recheck_exported"}'),
  ('get_exported_box_recheck_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;

update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
where identity='catalog';
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create or replace function public.get_exported_box_recheck_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when exists (select 1 from greenloop_private.page_capability_catalog where page_key='stock_exported'
      and capabilities @> '[{"key":"recheck_exported","write":true}]')
    and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='request_exported_box_recheck_v1'
      and rule='{"page":"stock_exported","capability":"recheck_exported"}')
    and has_function_privilege('authenticated','public.request_exported_box_recheck_v1(uuid,integer,text)','execute')
    and not has_function_privilege('anon','public.request_exported_box_recheck_v1(uuid,integer,text)','execute')
    and exists (select 1 from pg_proc where oid=to_regprocedure('public.request_exported_box_recheck_v1(uuid,integer,text)')
      and prosecdef and strpos(prosrc,'greenloop_private.begin_capability(')>0
      and strpos(prosrc,'pg_advisory_xact_lock(16320261010)')>0)
    then '20261126-exported-box-recheck-1' end;
$version$;
revoke all on function public.get_exported_box_recheck_version() from public,anon,authenticated;
grant execute on function public.get_exported_box_recheck_version() to anon,authenticated;

do $verify$ begin
  if public.get_exported_box_recheck_version() is distinct from '20261126-exported-box-recheck-1'
    or public.get_box_recheck_imei_controls_version() is distinct from '20261125-box-recheck-imei-controls-1' then
    raise exception 'Could not verify exported box Recheck.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_exported_box_recheck_version() as installed_exported_box_recheck_version;
