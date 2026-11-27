begin;
set local lock_timeout = '5s';

-- Draft reads and scanner responses share this existing snapshot.
do $draft$
declare
  api regprocedure := 'public.get_box_workflow_v1(uuid,text)'::regprocedure;
  reader regprocedure;
  definition text;
  previous_hash text;
  updated_hash text;
  part_anchor constant text := 'i.final_grade,i.scanned_at,';
  json_anchor constant text := 'jsonb_agg(to_jsonb(t) order by t.serial_no)';
begin
  if to_regprocedure('greenloop_private.esim_stock_class(text,text,text,text)') is null then
    raise exception 'Install the Ready Stock eSIM update first.';
  end if;
  select to_regprocedure(o.implementation) into strict reader
  from greenloop_private.office_routines o where to_regprocedure(o.identity)=api;
  definition:=pg_get_functiondef(reader);
  previous_hash:=md5(definition);
  if not exists (select 1 from greenloop_private.office_routines o
    where to_regprocedure(o.identity)=api and o.original_hash=previous_hash
      and o.wrapped_hash=md5(pg_get_functiondef(api))) then
    raise exception 'The existing Box Entry reader definition could not be verified.';
  end if;
  if strpos(definition,'-- box-entry-esim-383')>0 then return; end if;
  if (length(definition)-length(replace(definition,part_anchor,'')))/length(part_anchor)<>1
    or (length(definition)-length(replace(definition,json_anchor,'')))/length(json_anchor)<>1 then
    raise exception 'The Box Entry reader does not match the expected phone snapshot.';
  end if;
  definition:=replace(definition,part_anchor,part_anchor||$field$
    -- box-entry-esim-383
    case when v_flow.state='draft' then coalesce(greenloop_private.esim_stock_class(
      d.brand,d.device_platform::text,d.model,d.specification_region
    ) in ('esim_only_by_a_number','esim_only_by_model','likely_esim_only_by_region'),false) end esim_only,
$field$);
  definition:=replace(definition,json_anchor,$json$
    jsonb_agg(case when v_flow.state='draft' then to_jsonb(t) else to_jsonb(t)-'esim_only' end order by t.serial_no)
$json$);
  execute definition;
  updated_hash:=md5(pg_get_functiondef(reader));
  update greenloop_private.office_routines o set original_hash=updated_hash
    where to_regprocedure(o.implementation)=reader and original_hash=previous_hash;
  update greenloop_private.qc_direct_ready_installation q set hash=updated_hash
    where to_regprocedure(q.identity)=reader and q.hash=previous_hash;
  update greenloop_private.accounts_stock_installation a set hash=updated_hash
    where to_regprocedure(a.identity)=reader and a.hash=previous_hash;
  update greenloop_private.box_workflow_installation b set hash=updated_hash
    where to_regprocedure(b.identity)=reader and b.hash=previous_hash;
end;
$draft$;

create or replace function public.verify_boxes_v1(p_box_ids uuid[],p_revisions integer[],p_customer_id uuid)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $verify$
declare
  selected_count integer:=coalesce(cardinality(p_box_ids),0);
  box record;
begin
  perform greenloop_private.require_box_review_cap('accounts','view');
  perform greenloop_private.require_box_review_cap('accounts','verify');
  if selected_count not between 1 and 50 or cardinality(p_revisions) is distinct from selected_count
    or array_ndims(p_box_ids)<>1 or array_ndims(p_revisions)<>1
    or exists(select 1 from unnest(p_box_ids,p_revisions) s(id,rev) where s.id is null or s.rev is null or s.rev<0)
    or selected_count<>(select count(distinct id) from unnest(p_box_ids) as s(id)) then
    raise exception 'Select 1 to 50 different boxes from the current Accounts list.' using errcode='22023';
  end if;
  if p_customer_id is null then
    raise exception 'Select a customer for the selected boxes.' using errcode='22023';
  end if;

  -- Every selected box must still be awaiting review at its displayed revision.
  -- The existing verification API supplies the same role, stock and audit behavior.
  perform pg_advisory_xact_lock(16320261010);
  perform 1 from public.export_boxes b join greenloop_private.box_workflow w on w.box_id=b.id
    where b.id=any(p_box_ids) order by b.id for update of b,w;
  for box in select s.id,s.rev,b.box_number,w.state,w.revision,w.printed_revision,w.printed_at
    from unnest(p_box_ids,p_revisions) s(id,rev)
    left join public.export_boxes b on b.id=s.id
    left join greenloop_private.box_workflow w on w.box_id=s.id
    order by s.id
  loop
    if box.state is distinct from 'accounts' or box.revision is distinct from box.rev then
      raise exception '% changed or is no longer awaiting verification. Refresh and select the boxes again.',
        coalesce(box.box_number,'A selected box') using errcode='40001';
    end if;
    if box.printed_revision is distinct from box.rev or box.printed_at is null then
      raise exception 'Print and confirm the updated box % before verification.',box.box_number using errcode='22023';
    end if;
  end loop;
  for box in select s.id,s.rev from unnest(p_box_ids,p_revisions) s(id,rev) order by s.id loop
    if public.verify_box_v2(box.id,box.rev,p_customer_id) is distinct from true then
      raise exception 'A selected box could not be verified.';
    end if;
  end loop;
  return selected_count;
end;
$verify$;
revoke all on function public.verify_boxes_v1(uuid[],integer[],uuid) from public,anon,authenticated;
grant execute on function public.verify_boxes_v1(uuid[],integer[],uuid) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('verify_boxes_v1','{"page":"accounts","capability":"verify"}'),
  ('get_box_entry_esim_bulk_verify_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create or replace function public.get_box_entry_esim_bulk_verify_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
      select 1 from greenloop_private.office_routines o
      join pg_proc p on p.oid=to_regprocedure(o.implementation)
      where to_regprocedure(o.identity)='public.get_box_workflow_v1(uuid,text)'::regprocedure
        and o.original_hash=md5(pg_get_functiondef(p.oid))
        and strpos(p.prosrc,'-- box-entry-esim-383')>0
    )
    and has_function_privilege('authenticated','public.verify_boxes_v1(uuid[],integer[],uuid)','execute')
    and not has_function_privilege('anon','public.verify_boxes_v1(uuid[],integer[],uuid)','execute')
    and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='verify_boxes_v1'
      and rule='{"page":"accounts","capability":"verify"}'::jsonb)
    then '20261127-box-entry-esim-bulk-verify-1' end;
$version$;
revoke all on function public.get_box_entry_esim_bulk_verify_version() from public,anon,authenticated;
grant execute on function public.get_box_entry_esim_bulk_verify_version() to anon,authenticated;

do $check$ begin
  if public.get_box_entry_esim_bulk_verify_version() is distinct from '20261127-box-entry-esim-bulk-verify-1' then
    raise exception 'Box Entry eSIM and bulk verification could not be verified.';
  end if;
end; $check$;
notify pgrst,'reload schema';
commit;
select public.get_box_entry_esim_bulk_verify_version() as installed_box_entry_esim_bulk_verify_version;
