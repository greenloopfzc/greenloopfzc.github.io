-- Split pending prices by color for the three color-dependent part families.
begin;
set local lock_timeout = '5s';

do $install$
declare
  reader regprocedure := 'greenloop_private.ppp_units()'::regprocedure;
  definition text := pg_get_functiondef(reader);
  prior_hash text := md5(definition);
  new_hash text;
  old_color constant text := '''color_key'',greenloop_private.ppp_norm(color)';
  old_group constant text := $old$md5(jsonb_build_array(u->'supplier_id',u->'batch_id',u->'invoice_number',u->'model_key',u->'part_key',u->'source',u->'currency')::text)$old$;
begin
  if not exists (select 1 from greenloop_private.pending_parts_prices_installation
      where to_regprocedure(identity) = reader and hash = prior_hash)
    or not exists (select 1 from greenloop_private.stock_consistency_installation
      where to_regprocedure(identity) = reader and hash = prior_hash) then
    raise exception 'The installed Pending Parts Prices reader could not be verified.';
  end if;
  if strpos(definition, '-- pending-parts-price-color-375') > 0 then return; end if;

  definition := replace(definition, chr(13), '');
  if cardinality(string_to_array(definition, old_color)) <> 2
    or cardinality(string_to_array(definition, old_group)) <> 2 then
    raise exception 'The installed Pending Parts Prices grouping differs from the reviewed definition.';
  end if;

  -- Keep exact part variants separate. The normalized name only decides
  -- whether the existing phone color belongs in this pricing group.
  definition := replace(definition, old_color, $color$'color_key',
    case when regexp_replace(greenloop_private.ppp_norm(part_name), '[^a-z0-9]', '', 'g') in
      ('housing', 'housing4g', 'housing5g', 'housingesim', 'housingwithoutbackcover',
       'backglass', 'chargingflex')
    then greenloop_private.ppp_norm(color) end$color$);
  -- Include the color only for the eligible parts and keep ordinary group IDs.
  definition := replace(definition, old_group, $group$md5((jsonb_build_array(
    u->'supplier_id',u->'batch_id',u->'invoice_number',u->'model_key',u->'part_key',u->'source',u->'currency')
    -- pending-parts-price-color-375
    || case when u->>'color_key' is null then '[]'::jsonb
            else jsonb_build_array(u->'color_key') end)::text)$group$);
  execute definition;

  new_hash := md5(pg_get_functiondef(reader));
  update greenloop_private.pending_parts_prices_installation set hash = new_hash
    where to_regprocedure(identity) = reader and hash = prior_hash;
  update greenloop_private.stock_consistency_installation set hash = new_hash
    where to_regprocedure(identity) = reader and hash = prior_hash;
end;
$install$;

create or replace function public.get_pending_parts_price_color_version()
returns text language sql stable security definer set search_path = pg_catalog, public as $version$
  select case when exists (select 1 from greenloop_private.pending_parts_prices_installation
      where to_regprocedure(identity) = 'greenloop_private.ppp_units()'::regprocedure
        and hash = md5(pg_get_functiondef(to_regprocedure(identity)))
        and strpos(pg_get_functiondef(to_regprocedure(identity)), '-- pending-parts-price-color-375') > 0
        and not has_function_privilege('anon', to_regprocedure(identity), 'EXECUTE')
        and not has_function_privilege('authenticated', to_regprocedure(identity), 'EXECUTE'))
    and exists (select 1 from greenloop_private.stock_consistency_installation
      where to_regprocedure(identity) = 'greenloop_private.ppp_units()'::regprocedure
        and hash = md5(pg_get_functiondef(to_regprocedure(identity))))
    then '20261126-pending-parts-price-color-1' end;
$version$;
revoke all on function public.get_pending_parts_price_color_version() from public, anon, authenticated;
grant execute on function public.get_pending_parts_price_color_version() to anon, authenticated;

do $verify$
begin
  if public.get_pending_parts_price_color_version() is distinct from '20261126-pending-parts-price-color-1' then
    raise exception 'Pending Parts Prices color grouping could not be verified.';
  end if;
end;
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_pending_parts_price_color_version() as installed_pending_parts_price_color_version;
