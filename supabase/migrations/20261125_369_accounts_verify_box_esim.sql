-- Show the shared eSIM-only classification on each phone awaiting box verification.
begin;
set local lock_timeout='5s';

do $install$
declare
  target regprocedure:=to_regprocedure('public.get_accounts_verify_box_detail_v1(uuid)');
  definition text;
  battery_field_pattern constant text:='''final_battery_health''[[:space:]]*,[[:space:]]*case';
  box_item_pattern constant text:='(join[[:space:]]+public[.]export_box_items[[:space:]]+item[[:space:]]+on[^\r\n]+item[.]box_id[[:space:]]*=[[:space:]]*p_box_id)[[:space:]]+left[[:space:]]+join[[:space:]]+lateral';
begin
  if to_regprocedure('public.get_ready_stock_esim_version()') is null then
    raise exception 'Install the Ready Stock eSIM update first.';
  end if;
  if public.get_ready_stock_esim_version() is distinct from '20261125-ready-stock-esim-1' then
    raise exception 'Install the verified Ready Stock eSIM update first.';
  end if;
  if target is null or public.get_accounts_box_final_bh_version() is distinct from '20261123-accounts-box-final-bh-1' then
    raise exception 'Existing Accounts Verify Box detail could not be verified.';
  end if;

  definition:=pg_get_functiondef(target);
  if strpos(definition,'''esim_only''')>0 then return; end if;
  if (select count(*) from regexp_matches(definition,battery_field_pattern,'g'))<>1
     or (select count(*) from regexp_matches(definition,box_item_pattern,'g'))<>1 then
    raise exception 'Existing Accounts Verify Box detail does not match the expected definition.';
  end if;
  definition:=regexp_replace(definition,battery_field_pattern,$field$
    'esim_only',greenloop_private.esim_stock_class(
      device.brand,device.device_platform::text,device.model,device.specification_region
    ) in ('esim_only_by_a_number','esim_only_by_model','likely_esim_only_by_region'),
    'final_battery_health',case$field$);
  definition:=regexp_replace(definition,box_item_pattern,$join$\1
  left join public.devices device on device.id=item.device_id
  left join lateral$join$);
  execute definition;
end;
$install$;

create or replace function public.get_accounts_verify_box_esim_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when public.get_ready_stock_esim_version()='20261125-ready-stock-esim-1'
    and public.get_accounts_box_final_bh_version()='20261123-accounts-box-final-bh-1'
    and exists (
      select 1 from pg_proc
      where oid=to_regprocedure('public.get_accounts_verify_box_detail_v1(uuid)')
        and strpos(prosrc,'''esim_only'',greenloop_private.esim_stock_class(')>0
        and strpos(prosrc,'device.id=item.device_id')>0
    )
    then '20261125-accounts-verify-box-esim-1' end;
$version$;
revoke all on function public.get_accounts_verify_box_esim_version() from public,anon,authenticated;
grant execute on function public.get_accounts_verify_box_esim_version() to anon,authenticated;

do $verify$ begin
  if public.get_accounts_verify_box_esim_version() is distinct from '20261125-accounts-verify-box-esim-1' then
    raise exception 'Accounts Verify Box eSIM update could not be verified.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_accounts_verify_box_esim_version() as installed_accounts_verify_box_esim_version;
