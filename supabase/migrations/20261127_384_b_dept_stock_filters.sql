-- Include the exact intake receipt in the existing authorised B-DEPT snapshot.
do $install$
declare
  api regprocedure := 'public.get_b_dept_rows_v1()'::regprocedure;
  reader regprocedure;
  definition text;
  previous_hash text;
  next_hash text;
  anchor constant text := 'to_jsonb(r)||jsonb_build_object(''supplier_name''';
  replacement constant text := 'to_jsonb(r)||jsonb_build_object(''receiving_batch_id'',j.receiving_batch_id,''supplier_name''';
begin
  select to_regprocedure(o.implementation) into strict reader
  from greenloop_private.office_routines o where to_regprocedure(o.identity)=api;
  definition:=pg_get_functiondef(reader);
  previous_hash:=md5(definition);
  if not exists (select 1 from greenloop_private.office_routines o
    where to_regprocedure(o.identity)=api and o.original_hash=previous_hash
      and o.wrapped_hash=md5(pg_get_functiondef(api))) then
    raise exception 'The existing B-DEPT reader could not be verified.';
  end if;
  if strpos(definition,replacement)=0 then
    if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
      raise exception 'The existing B-DEPT phone snapshot does not match the expected reader.';
    end if;
    execute replace(definition,anchor,replacement);
    next_hash:=md5(pg_get_functiondef(reader));
    update greenloop_private.office_routines o set original_hash=next_hash
      where to_regprocedure(o.implementation)=reader and o.original_hash=previous_hash;
    update greenloop_private.b_dept_installation b set hash=next_hash
      where to_regprocedure(b.identity)=reader and b.hash=previous_hash;
  end if;

  execute $ddl$
    create or replace function public.get_b_dept_stock_filters_version()
    returns text language sql stable security definer set search_path=pg_catalog,public as $version$
      select case when exists (
        select 1 from greenloop_private.office_routines o join pg_proc p on p.oid=to_regprocedure(o.implementation)
        where to_regprocedure(o.identity)='public.get_b_dept_rows_v1()'::regprocedure
          and strpos(p.prosrc,'''receiving_batch_id'',j.receiving_batch_id')>0
          and o.original_hash=md5(pg_get_functiondef(p.oid))
          and o.wrapped_hash=md5(pg_get_functiondef(to_regprocedure(o.identity)))
          and not has_function_privilege('authenticated',p.oid,'EXECUTE')
          and not has_function_privilege('anon',p.oid,'EXECUTE')
      ) then '20261127-b-dept-stock-filters-1' end;
    $version$;
  $ddl$;
  revoke all on function public.get_b_dept_stock_filters_version() from public,anon,authenticated;
  grant execute on function public.get_b_dept_stock_filters_version() to anon,authenticated;
  if public.get_b_dept_stock_filters_version() is distinct from '20261127-b-dept-stock-filters-1' then
    raise exception 'B-DEPT stock filters could not be verified.';
  end if;
  notify pgrst,'reload schema';
end;
$install$;
select public.get_b_dept_stock_filters_version() as installed_b_dept_stock_filters_version;
