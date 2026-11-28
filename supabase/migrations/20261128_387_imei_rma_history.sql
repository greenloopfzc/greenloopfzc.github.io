-- Add the saved RMA event identity to the existing protected journey.
begin;

do $install$
declare
  sig constant regprocedure := 'greenloop_private.jst_history(jsonb)'::regprocedure;
  event_anchor constant text := $anchor$select e.event_type,e.event_data->>'box_number'into event_kind,box from public.device_events e where e.id::text=split_part(r->>'id',':',2)and e.device_id=d.id;$anchor$;
  export_check constant text := $anchor$elsif event_kind='box_accounts_verified'or split_part$anchor$;
  export_label constant text := $anchor$label:=case when key='export'then 'Verified export'else 'Verified export history'end;$anchor$;
  before_ddl text := pg_get_functiondef(sig);
  updated text;
  before_hash text := md5(before_ddl);
  after_hash text;
  tracked record;
begin
  if public.get_customer_rma_version() is distinct from '20261128-customer-rma-1'
    or not exists (select 1 from greenloop_private.journey_status_installation
      where to_regprocedure(identity)=sig and hash=before_hash) then
    raise exception 'Verified Customer RMA and IMEI Journey installs are required.';
  end if;
  if position('''rma_event'',event_kind' in before_ddl)>0 then
    return;
  end if;
  if (length(before_ddl)-length(replace(before_ddl,event_anchor,'')))/length(event_anchor)<>1
    or (length(before_ddl)-length(replace(before_ddl,export_check,'')))/length(export_check)<>1
    or (length(before_ddl)-length(replace(before_ddl,export_label,'')))/length(export_label)<>1 then
    raise exception 'The IMEI Journey event definition changed.';
  end if;
  updated:=replace(before_ddl,event_anchor,event_anchor||$event$
   if event_kind in ('opening_stock_marked_rma','customer_rma_received','customer_rma_reexported') then
    r:=r||jsonb_build_object('rma_event',event_kind,'title',case event_kind
      when 'opening_stock_marked_rma' then 'Opening Stock marked as RMA'
      when 'customer_rma_received' then 'RMA received for Initial QC'
      else 'RMA re-export verified' end);
   end if;$event$);
  updated:=replace(updated,export_check,
    $replace$elsif event_kind in ('box_accounts_verified','customer_rma_reexported') or split_part$replace$);
  updated:=replace(updated,export_label,
    $replace$label:=case when event_kind='customer_rma_reexported' then 'RMA re-export verified' when key='export' then 'Verified export' else 'Verified export history' end;$replace$);
  execute updated;
  after_hash:=md5(pg_get_functiondef(sig));
  for tracked in
    select c.table_name,c.column_name hash_column,i.column_name identity_column
    from information_schema.columns c
    join information_schema.columns i using(table_schema,table_name)
    where c.table_schema='greenloop_private' and c.table_name like '%installation'
      and c.column_name in ('hash','definition_hash')
      and i.column_name in ('identity','object_identity','function_identity')
  loop
    execute format('update greenloop_private.%I set %I=$1 where to_regprocedure(%I)=$2 and %I=$3',
      tracked.table_name,tracked.hash_column,tracked.identity_column,tracked.hash_column)
      using after_hash,sig,before_hash;
  end loop;
end;
$install$;

create or replace function public.get_imei_rma_history_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $body$
  select case when public.get_customer_rma_version()='20261128-customer-rma-1'
    and exists (select 1 from greenloop_private.journey_status_installation
      where to_regprocedure(identity)='greenloop_private.jst_history(jsonb)'::regprocedure
        and hash=md5(pg_get_functiondef(to_regprocedure(identity))))
    and position('''rma_event'',event_kind' in pg_get_functiondef('greenloop_private.jst_history(jsonb)'::regprocedure))>0
  then '20261128-imei-rma-history-1' end;
$body$;
revoke all on function public.get_imei_rma_history_version() from public,anon,authenticated;
grant execute on function public.get_imei_rma_history_version() to anon,authenticated;

do $verify$
begin
  if public.get_imei_rma_history_version() is distinct from '20261128-imei-rma-history-1' then
    raise exception 'IMEI RMA history did not verify.';
  end if;
end;
$verify$;

notify pgrst,'reload schema';
commit;
select public.get_imei_rma_history_version() as installed_imei_rma_history_version;
