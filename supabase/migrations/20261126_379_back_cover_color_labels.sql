-- Show the colors represented in a Back Cover price row.
-- Price group membership and reviewed issue tokens are unchanged.
begin;
set local lock_timeout = '5s';

do $install$
declare
  reader regprocedure := 'greenloop_private.ppp_report(jsonb,text)'::regprocedure;
  definition text := pg_get_functiondef(reader);
  prior_hash text := md5(definition);
  next_hash text;
  receipt regclass;
  receipt_name text;
  verified boolean;
  anchor constant text := $anchor$min(u->>'issued_day')first_issued_day,max(u->>'issued_day')last_issued_day,$anchor$;
  receipt_names constant text[] := array[
    'greenloop_private.pending_parts_prices_installation',
    'greenloop_private.stock_consistency_installation',
    'greenloop_private.stock_bulk_search_installation',
    'greenloop_private.workflow_read_load_installation'
  ];
begin
  foreach receipt_name in array receipt_names loop
    receipt := to_regclass(receipt_name);
    if receipt is null and receipt_name = 'greenloop_private.workflow_read_load_installation' then
      continue;
    end if;
    if receipt is null then raise exception 'The pending price report installation receipt is missing.'; end if;
    execute format('select exists (select 1 from %s where to_regprocedure(identity) = $1 and hash = $2)', receipt)
      into verified using reader, prior_hash;
    if not verified then raise exception 'The installed pending price report could not be verified.'; end if;
  end loop;
  if strpos(definition, '-- back-cover-color-labels-379') > 0 then return; end if;

  definition := replace(definition, chr(13), '');
  if cardinality(string_to_array(definition, anchor)) <> 2 then
    raise exception 'The installed pending price report differs from its reviewed definition.';
  end if;
  definition := replace(definition, anchor, anchor || $display$
  -- back-cover-color-labels-379
  jsonb_agg(distinct (u->>'color') order by (u->>'color'))
    filter (where u->>'part_key' = 'back cover') as display_colors,$display$);
  execute definition;
  next_hash := md5(pg_get_functiondef(reader));

  foreach receipt_name in array receipt_names loop
    receipt := to_regclass(receipt_name);
    if receipt is not null then
      execute format('update %s set hash = $1 where to_regprocedure(identity) = $2 and hash = $3', receipt)
        using next_hash, reader, prior_hash;
    end if;
  end loop;
end;
$install$;

create or replace function public.get_back_cover_color_labels_version()
returns text language sql stable security definer set search_path = pg_catalog, public as $version$
  select case when exists (
    select 1 from greenloop_private.pending_parts_prices_installation
    where to_regprocedure(identity) = 'greenloop_private.ppp_report(jsonb,text)'::regprocedure
      and hash = md5(pg_get_functiondef(to_regprocedure(identity)))
      and strpos(pg_get_functiondef(to_regprocedure(identity)), '-- back-cover-color-labels-379') > 0
      and not has_function_privilege('anon', to_regprocedure(identity), 'EXECUTE')
      and not has_function_privilege('authenticated', to_regprocedure(identity), 'EXECUTE')
  ) then '20261126-back-cover-color-labels-1' end;
$version$;
revoke all on function public.get_back_cover_color_labels_version() from public, anon, authenticated;
grant execute on function public.get_back_cover_color_labels_version() to anon, authenticated;

do $verify$
begin
  if public.get_back_cover_color_labels_version() is distinct from '20261126-back-cover-color-labels-1' then
    raise exception 'Back Cover color labels could not be verified.';
  end if;
end;
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_back_cover_color_labels_version() as installed_back_cover_color_labels_version;
