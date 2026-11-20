-- Route Box Entry writes to the selected open draft.
begin;
set local search_path = pg_catalog, public;

do $install$
declare
  api constant regprocedure := 'public.scan_imei_to_export_box(text)'::regprocedure;
  office_row greenloop_private.office_routines%rowtype;
  capability_row greenloop_private.capability_routines%rowtype;
  office_impl regprocedure;
  scanner_impl regprocedure;
  office_name text;
  scanner_name text;
  api_body text;
  office_body text;
  scanner_body text;
  expected_office_body text;
  scanner_prefix text;
  selector text[];
  ddl text;
  -- Recognize the reviewed oldest-open selector across indentation and line endings.
  -- Only this block changes. Keep the installed scanner's grade source and guards.
  selector_pattern constant text :=
    $piece$(select\s+box\.id\s*,\s*box\.box_number\s*,\s*box\.capacity\s*,\s*box\.box_status\s+$piece$ ||
    $piece$into\s+v_box_id\s*,\s*v_box_number\s*,\s*v_capacity\s*,\s*v_box_status\s+from\s+public\.export_boxes\s+box\s+)$piece$ ||
    $piece$(where\s+box\.box_status\s*=\s*'open'\s+order\s+by\s+box\.opened_at\s*,\s*box\.created_at\s+limit\s+1\s+for\s+update\s*;\s*$piece$ ||
    $piece$if\s+v_box_id\s+is\s+null\s+then\s+insert\s+into\s+public\.export_boxes\s+as\s+new_box\s*\(\s*box_number\s*,\s*created_by\s*\)\s*$piece$ ||
    $piece$values\s*\(\s*null\s*,\s*v_actor_id\s*\)\s*returning\s+new_box\.id\s*,\s*new_box\.box_number\s*,\s*new_box\.capacity\s*,\s*new_box\.box_status\s+$piece$ ||
    $piece$into\s+v_box_id\s*,\s*v_box_number\s*,\s*v_capacity\s*,\s*v_box_status\s*;\s*end\s+if\s*;)$piece$ ||
    $piece$(\s*select\s+count\(\*\)::integer\s+into\s+v_item_count)$piece$;
begin
  if to_regclass('greenloop_private.multiple_open_boxes_installation') is not null
    or to_regprocedure('public.get_multiple_open_boxes_version()') is not null then
    if to_regprocedure('public.get_multiple_open_boxes_version()') is null then
      raise exception 'Existing Multiple Open Boxes installation is incomplete.';
    end if;
    if public.get_multiple_open_boxes_version() is distinct from '20261120-multiple-open-export-boxes-1' then
      raise exception 'Existing Multiple Open Boxes installation failed verification.';
    end if;
  end if;

  select * into strict office_row
  from greenloop_private.office_routines where to_regprocedure(identity) = api;
  select * into strict capability_row
  from greenloop_private.capability_routines where to_regprocedure(identity) = api;
  office_impl := to_regprocedure(office_row.implementation);
  scanner_impl := to_regprocedure(capability_row.implementation);

  select format('%I.%I', n.nspname, p.proname), p.prosrc into strict office_name, office_body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.oid = office_impl and n.nspname = 'greenloop_private'
    and p.pronargs = 1 and p.proargtypes[0] = 'text'::regtype and p.prosecdef and p.proretset;
  select format('%I.%I', n.nspname, p.proname), replace(p.prosrc, chr(13), '') into strict scanner_name, scanner_body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.oid = scanner_impl and n.nspname = 'greenloop_private'
    and p.pronargs = 1 and p.proargtypes[0] = 'text'::regtype and p.proargnames[1]='p_imei'
    and p.prosecdef and p.proretset;

  if office_row.wrapped_hash is distinct from md5(pg_get_functiondef(api))
    or office_row.original_hash is distinct from md5(pg_get_functiondef(office_impl)) then
    raise exception 'Box Entry: existing scanner Office receipt mismatch.';
  end if;
  if capability_row.wrapped_hash is distinct from md5(pg_get_functiondef(api))
    or capability_row.original_hash is distinct from md5(pg_get_functiondef(scanner_impl)) then
    raise exception 'Box Entry: existing scanner capability receipt mismatch.';
  end if;
  if has_function_privilege('authenticated',office_impl,'EXECUTE') or has_function_privilege('anon',office_impl,'EXECUTE')
    or has_function_privilege('authenticated',scanner_impl,'EXECUTE') or has_function_privilege('anon',scanner_impl,'EXECUTE')
    or pg_get_function_result(scanner_impl) is distinct from pg_get_function_result(api) then
    raise exception 'Box Entry: existing scanner signature or permissions differ.';
  end if;

  select p.prosrc into strict api_body from pg_proc p where p.oid = api;
  expected_office_body := 'beginperformgreenloop_private.begin_capability(''scan_imei_to_export_box'',jsonb_build_object(''p_imei'',p_imei));'
    || 'beginreturnqueryselect*from'||scanner_name||'(p_imei);exceptionwhenothersthenperformgreenloop_private.end_capability();raise;end;'
    || 'performgreenloop_private.end_capability();return;end;';
  if regexp_replace(regexp_replace(api_body, $comments$--[^\r\n]*$comments$, '', 'g'), '\s+', '', 'g') is distinct from
      'beginperformgreenloop_private.require_office_network();returnqueryselect*from'||office_name||'($1);end;'
    or regexp_replace(regexp_replace(office_body, $comments$--[^\r\n]*$comments$, '', 'g'), '\s+', '', 'g') is distinct from expected_office_body then
    raise exception 'Box Entry: existing scanner Office and capability call chain differs.';
  end if;

  select matches into strict selector from regexp_matches(scanner_body, selector_pattern, 'g') matches;
  if (select count(*) from regexp_matches(scanner_body, $scan$\minsert\s+into\s+public\.export_boxes\M$scan$, 'gi')) <> 1
    or (select count(*) from regexp_matches(scanner_body, $scan$\mfrom\s+public\.export_boxes\M$scan$, 'gi')) <> 1
    or strpos(scanner_body, '16320261010') = 0
    or strpos(scanner_body, 'greenloop_require_entry') = 0
    or strpos(scanner_body, '''box_entry''') = 0 then
    raise exception 'Box Entry: existing scanner has a different draft selection or stock guard.';
  end if;

  ddl := replace(pg_get_functiondef(scanner_impl), chr(13), '');
  scanner_prefix := format('FUNCTION %s(%s)', scanner_name, pg_get_function_arguments(scanner_impl));
  if strpos(ddl, scanner_prefix) = 0 or strpos(ddl, selector[1]||selector[2]||selector[3]) = 0 then
    raise exception 'Box Entry: could not isolate the existing scanner draft selection.';
  end if;
  ddl := replace(ddl, scanner_prefix,'FUNCTION greenloop_private.scan_selected_export_box(p_imei text, p_box_id uuid)');
  execute replace(ddl, selector[1]||selector[2]||selector[3],
    selector[1]||$to$where box.id = p_box_id and box.box_status = 'open'
  for update;

  if v_box_id is null then
    raise exception 'The selected box is no longer open.' using errcode = '40001';
  end if;$to$||selector[3]);
exception
  when no_data_found then raise exception 'Box Entry: existing scanner mapping or draft selection is missing.';
  when too_many_rows then raise exception 'Box Entry: existing scanner mapping or draft selection is ambiguous.';
end;
$install$;
revoke all on function greenloop_private.scan_selected_export_box(text,uuid) from public,anon,authenticated;

create table if not exists greenloop_private.export_box_draft_requests (
  request_id uuid primary key,
  actor_id uuid not null,
  box_id uuid not null,
  force_new boolean not null
);
alter table greenloop_private.export_box_draft_requests enable row level security;
revoke all on greenloop_private.export_box_draft_requests from public,anon,authenticated;

create or replace function greenloop_private.open_export_box_drafts()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.pf_cap('export_boxes','view');
  if not greenloop_private.box_access('export_boxes') or
    not coalesce(public.has_role(array['super_admin','owner','manager','production','shipping']::public.app_role_key[]),false) then
    raise exception 'Box Entry permission required.' using errcode='42501';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(draft) order by draft.opened_at,draft.box_number,draft.box_id),'[]'::jsonb)
    from (
      select b.id box_id,b.box_number,b.opened_at,count(i.id)::integer item_count
      from public.export_boxes b
      join greenloop_private.box_workflow w on w.box_id=b.id
      left join public.export_box_items i on i.box_id=b.id
      where b.box_status in ('open','full') and w.state='draft' and w.saved_at is null
      group by b.id
    ) draft
  );
end;
$$;

create or replace function greenloop_private.create_export_box_draft(p_request_id uuid,p_force_new boolean)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  previous greenloop_private.export_box_draft_requests%rowtype;
  selected_box uuid;
  box_sequence text;
begin
  perform greenloop_private.pf_cap('export_boxes','scan');
  if not greenloop_private.box_access('export_boxes',true) or
    not coalesce(public.has_role(array['super_admin','owner','manager','production','shipping']::public.app_role_key[]),false) then
    raise exception 'Box Entry permission required.' using errcode='42501';
  end if;
  if p_request_id is null or p_force_new is null then
    raise exception 'A box creation request is required.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(16320261010);
  select * into previous from greenloop_private.export_box_draft_requests where request_id=p_request_id;
  if found then
    if previous.actor_id is distinct from auth.uid() or previous.force_new is distinct from p_force_new then
      raise exception 'This box creation request has already been used.' using errcode='22023';
    end if;
    return previous.box_id;
  end if;
  if not p_force_new then
    select b.id into selected_box
    from public.export_boxes b join greenloop_private.box_workflow w on w.box_id=b.id
    where b.box_status in ('open','full') and w.state='draft' and w.saved_at is null
    order by b.opened_at,b.box_number,b.id limit 1;
  end if;
  if selected_box is null then
    -- Same shared number sequence as the existing box factory.
    box_sequence := nextval('public.export_box_number_sequence'::regclass)::text;
    insert into public.export_boxes(box_number,capacity,created_by)
    values ('BOX-'||to_char(current_date,'YYYY')||'-'||lpad(box_sequence,greatest(4,length(box_sequence)),'0'),
      1000000,auth.uid()) returning id into selected_box;
  end if;
  insert into greenloop_private.export_box_draft_requests values(p_request_id,auth.uid(),selected_box,p_force_new);
  return selected_box;
end;
$$;

create or replace function greenloop_private.scan_export_box_draft(p_box_id uuid,p_revision integer,p_imeis text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  target public.export_boxes%rowtype;
  flow greenloop_private.box_workflow%rowtype;
  candidate text;
  existing_box text;
  scanned record;
  results jsonb := '[]';
  loaded integer := 0;
  seen text[] := '{}';
begin
  perform greenloop_private.pf_cap('export_boxes','scan');
  if not greenloop_private.box_access('export_boxes',true) or
    not coalesce(public.has_role(array['super_admin','owner','manager','production','shipping']::public.app_role_key[]),false) then
    raise exception 'Box Entry permission required.' using errcode='42501';
  end if;
  if coalesce(cardinality(p_imeis),0)=0 then
    raise exception 'Paste at least one IMEI.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(16320261010);
  select * into target from public.export_boxes where id=p_box_id for update;
  select * into flow from greenloop_private.box_workflow where box_id=p_box_id for update;
  if target.id is null or target.box_status <> 'open' or flow.state is distinct from 'draft' or flow.saved_at is not null then
    raise exception 'The selected box is saved or unavailable. Reopen Box Entry.' using errcode='22023';
  end if;
  if flow.revision is distinct from p_revision then
    raise exception 'This box changed. Check the refreshed list before scanning again.' using errcode='40001';
  end if;

  foreach candidate in array p_imeis loop
    begin
      if candidate is null or candidate !~ '^[0-9]{15}$' then
        raise exception 'Use a valid 15-digit IMEI.' using errcode='22023';
      end if;
      if candidate=any(seen) then
        raise exception 'Duplicate IMEI in pasted list.' using errcode='22023';
      end if;
      seen := array_append(seen,candidate);

      select b.box_number into existing_box
      from public.devices d join public.export_box_items i on i.device_id=d.id
      join public.export_boxes b on b.id=i.box_id where d.imei_1=candidate;
      if existing_box is not null then
        raise exception 'This IMEI is already in %.',existing_box using errcode='22023';
      end if;

      -- Apply the original entry scope and secondary-IMEI rule. A failed item
      -- rolls back its own scope and writes before reporting its reason.
      perform greenloop_private.begin_capability('scan_imei_to_export_box',jsonb_build_object('p_imei',candidate));
      select * into scanned from greenloop_private.scan_selected_export_box(candidate,p_box_id);
      perform greenloop_private.end_capability();
      if scanned.box_id is distinct from p_box_id then
        raise exception 'The selected box changed. Reopen Box Entry.' using errcode='40001';
      end if;
      loaded := loaded+1;
      results := results||jsonb_build_array(jsonb_build_object('imei',candidate,'ok',true,'serial_no',scanned.serial_no));
    exception when sqlstate '22023' or sqlstate '23505' or sqlstate '55000' or sqlstate 'P0001' then
      results := results||jsonb_build_array(jsonb_build_object('imei',candidate,'ok',false,'message',sqlerrm));
    end;
  end loop;
  return public.get_box_workflow_v1(p_box_id)||jsonb_build_object('loaded',loaded,'results',results);
end;
$$;

create or replace function public.list_open_export_box_drafts_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.open_export_box_drafts();
end;
$$;

create or replace function public.create_open_export_box_draft_v1(p_request_id uuid,p_force_new boolean)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.create_export_box_draft(p_request_id,p_force_new);
end;
$$;

create or replace function public.scan_imeis_to_selected_export_box_v1(p_box_id uuid,p_revision integer,p_imeis text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform greenloop_private.require_office_network();
  return greenloop_private.scan_export_box_draft(p_box_id,p_revision,p_imeis);
end;
$$;

revoke all on function greenloop_private.open_export_box_drafts(),
  greenloop_private.create_export_box_draft(uuid,boolean),
  greenloop_private.scan_export_box_draft(uuid,integer,text[]) from public,anon,authenticated;
revoke all on function public.list_open_export_box_drafts_v1(),
  public.create_open_export_box_draft_v1(uuid,boolean),
  public.scan_imeis_to_selected_export_box_v1(uuid,integer,text[]) from public,anon,authenticated;
grant execute on function public.list_open_export_box_drafts_v1(),
  public.create_open_export_box_draft_v1(uuid,boolean),
  public.scan_imeis_to_selected_export_box_v1(uuid,integer,text[]) to authenticated;

insert into greenloop_private.office_routines (identity,implementation,original_hash,wrapped_hash)
select api,impl,md5(pg_get_functiondef(impl::regprocedure)),md5(pg_get_functiondef(api::regprocedure))
from (values
  ('public.list_open_export_box_drafts_v1()','greenloop_private.open_export_box_drafts()'),
  ('public.create_open_export_box_draft_v1(uuid,boolean)','greenloop_private.create_export_box_draft(uuid,boolean)'),
  ('public.scan_imeis_to_selected_export_box_v1(uuid,integer,text[])','greenloop_private.scan_export_box_draft(uuid,integer,text[])')
) as installed(api,impl)
on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;

insert into greenloop_private.capability_rpc_rules values
  ('list_open_export_box_drafts_v1','{"page":"export_boxes","capability":"view","read":true}'),
  ('create_open_export_box_draft_v1','{"page":"export_boxes","capability":"scan"}'),
  ('scan_imeis_to_selected_export_box_v1','{"page":"export_boxes","capability":"scan"}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.multiple_open_boxes_installation(identity text primary key,hash text not null);
alter table greenloop_private.multiple_open_boxes_installation enable row level security;
revoke all on greenloop_private.multiple_open_boxes_installation from public,anon,authenticated;

create or replace function public.get_multiple_open_boxes_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
  select case when (select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
    from greenloop_private.multiple_open_boxes_installation)
  and not exists (
    select 1 from greenloop_private.multiple_open_boxes_installation s
    where s.identity like 'greenloop_private.%'
      and (has_function_privilege('anon',to_regprocedure(s.identity),'EXECUTE')
        or has_function_privilege('authenticated',to_regprocedure(s.identity),'EXECUTE'))
  )
  and not exists (
    select 1 from greenloop_private.multiple_open_boxes_installation s
    where s.identity like 'public.%_v1(%'
      and (has_function_privilege('anon',to_regprocedure(s.identity),'EXECUTE')
        or not has_function_privilege('authenticated',to_regprocedure(s.identity),'EXECUTE'))
  )
  and not exists (
    select 1 from (values ('export_box_draft_requests'),('multiple_open_boxes_installation')) t(name)
    left join pg_class c on c.oid=to_regclass('greenloop_private.'||t.name)
    where c.relrowsecurity is distinct from true
      or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  )
  and (
    select count(*)=3 and bool_and(
      coalesce(o.wrapped_hash=md5(pg_get_functiondef(to_regprocedure(o.identity))),false)
      and coalesce(o.original_hash=md5(pg_get_functiondef(to_regprocedure(o.implementation))),false)
    )
    from (values
      ('public.list_open_export_box_drafts_v1()','greenloop_private.open_export_box_drafts()'),
      ('public.create_open_export_box_draft_v1(uuid,boolean)','greenloop_private.create_export_box_draft(uuid,boolean)'),
      ('public.scan_imeis_to_selected_export_box_v1(uuid,integer,text[])','greenloop_private.scan_export_box_draft(uuid,integer,text[])')
    ) expected(api,impl)
    join greenloop_private.office_routines o
      on to_regprocedure(o.identity)=to_regprocedure(expected.api)
      and to_regprocedure(o.implementation)=to_regprocedure(expected.impl)
  )
  and (select count(*)=3 from greenloop_private.capability_rpc_rules where
    (rpc_name='list_open_export_box_drafts_v1' and rule='{"page":"export_boxes","capability":"view","read":true}')
    or (rpc_name in ('create_open_export_box_draft_v1','scan_imeis_to_selected_export_box_v1')
        and rule='{"page":"export_boxes","capability":"scan"}'))
  then '20261120-multiple-open-export-boxes-1' end;
$$;
revoke all on function public.get_multiple_open_boxes_version() from public,anon,authenticated;
grant execute on function public.get_multiple_open_boxes_version() to anon,authenticated;

insert into greenloop_private.multiple_open_boxes_installation
select identity,md5(pg_get_functiondef(identity::regprocedure))
from unnest(array[
  'greenloop_private.scan_selected_export_box(text,uuid)',
  'greenloop_private.open_export_box_drafts()',
  'greenloop_private.create_export_box_draft(uuid,boolean)',
  'greenloop_private.scan_export_box_draft(uuid,integer,text[])',
  'public.list_open_export_box_drafts_v1()',
  'public.create_open_export_box_draft_v1(uuid,boolean)',
  'public.scan_imeis_to_selected_export_box_v1(uuid,integer,text[])',
  'public.get_multiple_open_boxes_version()'
]) identity on conflict(identity) do update set hash=excluded.hash;

do $verify$
begin
  if public.get_multiple_open_boxes_version() is distinct from '20261120-multiple-open-export-boxes-1'
    or public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1' then
    raise exception 'Multiple Open Boxes failed installation verification.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;

select public.get_multiple_open_boxes_version() as installed_multiple_open_boxes_version;
