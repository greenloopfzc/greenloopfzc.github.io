begin;
set local lock_timeout = '5s';

-- Scan responses and reopened drafts use the same scoped box reader.
do $draft$
declare
  api constant regprocedure := 'public.get_box_workflow_v1(uuid,text)'::regprocedure;
  field_anchor constant text := 'end esim_only,';
  json_anchor constant text := $needle$else to_jsonb(t)-'esim_only' end order by t.serial_no$needle$;
  reader regprocedure;
  definition text;
  previous_hash text;
  updated_hash text;
begin
  if public.get_customer_rma_version() is distinct from '20261128-customer-rma-1'
    or public.get_box_entry_esim_bulk_verify_version() is distinct from '20261127-box-entry-esim-bulk-verify-1' then
    raise exception 'The Customer RMA and Box Entry eSIM updates are required.';
  end if;
  select to_regprocedure(o.implementation) into strict reader
  from greenloop_private.office_routines o
  where to_regprocedure(o.identity)=api and o.wrapped_hash=md5(pg_get_functiondef(api));
  definition:=pg_get_functiondef(reader);
  previous_hash:=md5(definition);
  if position('-- box-entry-rma-388' in definition)>0 then return; end if;

  if (length(definition)-length(replace(definition,field_anchor,'')))/length(field_anchor)<>1
    or (length(definition)-length(replace(definition,json_anchor,'')))/length(json_anchor)<>1 then
    raise exception 'The existing draft box phone snapshot differs from the reviewed definition.';
  end if;
  definition:=replace(definition,field_anchor,field_anchor||$field$
    -- box-entry-rma-388
    case when v_flow.state='draft' then exists (
      select 1 from greenloop_private.customer_rma_cases rma
      where rma.job_id=i.job_id and rma.device_id=i.device_id
    ) end is_rma,
$field$);
  definition:=replace(definition,json_anchor,
    $json$else to_jsonb(t)-array['esim_only','is_rma'] end order by t.serial_no$json$);
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

create or replace function public.get_box_entry_rma_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case
    when public.get_box_entry_esim_bulk_verify_version()='20261127-box-entry-esim-bulk-verify-1'
      and public.get_customer_rma_version()='20261128-customer-rma-1'
      and exists (
        select 1 from greenloop_private.office_routines o
        join pg_proc p on p.oid=to_regprocedure(o.implementation)
        where to_regprocedure(o.identity)='public.get_box_workflow_v1(uuid,text)'::regprocedure
          and position('-- box-entry-rma-388' in p.prosrc)>0
      )
    then '20261128-box-entry-rma-1'
  end;
$version$;
revoke all on function public.get_box_entry_rma_version() from public,anon,authenticated;
grant execute on function public.get_box_entry_rma_version() to anon,authenticated;

do $verify$
begin
  if public.get_box_entry_rma_version() is distinct from '20261128-box-entry-rma-1' then
    raise exception 'Box Entry e-Sim/RMA did not verify.';
  end if;
end;
$verify$;

notify pgrst,'reload schema';
commit;
select public.get_box_entry_rma_version() as installed_box_entry_rma_version;
