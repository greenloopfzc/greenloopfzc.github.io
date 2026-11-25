-- Extend the existing Ready Stock model reader with a SIM-type subset.
begin;
set local lock_timeout='5s';

do $install$
declare
  reader regprocedure:='greenloop_private.rsm_read(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text)'::regprocedure;
  api regprocedure:='public.get_ready_stock_models_v1(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text)'::regprocedure;
  definition text:=pg_get_functiondef(reader);
  previous_hash text:=md5(definition);
  next_hash text;
  edit record;
  previous_fragment text;
begin
  if to_regprocedure('greenloop_private.esim_stock_class(text,text,text,text)') is null then
    raise exception 'Install the Ready Stock e-Sim update first.';
  end if;
  if not exists (
      select 1 from greenloop_private.ready_models_installation
      where to_regprocedure(identity)=reader and hash=previous_hash
    ) or not exists (
      select 1 from greenloop_private.office_routines
      where to_regprocedure(identity)=api and to_regprocedure(implementation)=reader
        and original_hash=previous_hash and wrapped_hash=md5(pg_get_functiondef(api))
    ) then
    raise exception 'The installed Ready Stock Model Summary reader could not be verified.';
  end if;
  if strpos(definition,'-- model-breakdown-esim-374')>0 then return;end if;

  definition:=replace(definition,chr(13),'');
  for edit in select * from (values
    ($old$ if p_view='phones'then
  if jsonb_typeof(p_cell)$old$,
     $new$ -- model-breakdown-esim-374
 if p_view='phones' then
  if jsonb_typeof(p_cell)='object' and p_cell @> '{"esim":true}'::jsonb then
   if p_mode<>'current' or (p_cell-'esim'-'storage_gb')<>'{}'::jsonb
     or (p_cell?'storage_gb' and jsonb_typeof(p_cell->'storage_gb') not in ('number','null')) then
    raise exception 'Choose a valid Ready Stock e-Sim quantity.' using errcode='22023';
   end if;
  elsif jsonb_typeof(p_cell)$new$),
    ($old$d.storage_gb,d.color,
   lower($old$,
     $new$d.storage_gb,d.color,
   case when p_mode='current' then
     greenloop_private.esim_stock_class(d.brand,d.device_platform::text,d.model,d.specification_region)
       in ('esim_only_by_a_number','esim_only_by_model','likely_esim_only_by_region')
     else false end esim_only,
   lower($new$),
    ($old$),buckets as materialized(select nullif(r->>'storage_gb','')::integer storage_gb,count(*)quantity from selected group by$old$,
     $new$),buckets as materialized(select nullif(r->>'storage_gb','')::integer storage_gb,count(*) quantity,
   count(*) filter (where r @> '{"esim_only":true}') esim_quantity
   from selected group by$new$),
    ($old$phones as materialized(select r from selected where nullif(r->>'storage_gb','')::integer is not distinct from nullif(p_cell->>'storage_gb','')::integer and r->>'grade_key'=p_cell->>'grade_key')$old$,
     $new$phones as materialized(
   select r from selected where p_view='phones'
     and (not (p_cell?'storage_gb') or nullif(r->>'storage_gb','')::integer is not distinct from nullif(p_cell->>'storage_gb','')::integer)
     and case when p_cell @> '{"esim":true}' then r @> '{"esim_only":true}'
              else r->>'grade_key'=p_cell->>'grade_key' end
 )$new$),
    ($old$'model_total',(select count(*)from selected),'total'$old$,
     $new$'model_total',(select count(*)from selected),
 'model_esim_total',(select count(*) from selected where r @> '{"esim_only":true}'),'total'$new$)
  ) as changes(previous,revised) loop
    previous_fragment:=replace(edit.previous,chr(13),'');
    if cardinality(string_to_array(definition,previous_fragment))<>2 then
      raise exception 'The Model Summary reader differs at: %',left(edit.previous,65);
    end if;
    definition:=replace(definition,previous_fragment,replace(edit.revised,chr(13),''));
  end loop;
  execute definition;
  next_hash:=md5(pg_get_functiondef(reader));

  update greenloop_private.ready_models_installation set hash=next_hash
    where to_regprocedure(identity)=reader and hash=previous_hash;
  update greenloop_private.office_routines set original_hash=next_hash
    where to_regprocedure(implementation)=reader and original_hash=previous_hash;
end;
$install$;

create or replace function public.get_ready_model_esim_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
    select 1 from greenloop_private.ready_models_installation
    where to_regprocedure(identity)='greenloop_private.rsm_read(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text)'::regprocedure
      and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and strpos(pg_get_functiondef(to_regprocedure(identity)),'-- model-breakdown-esim-374')>0
      and not has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')
      and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')
  ) and exists (
    select 1 from greenloop_private.office_routines
    where to_regprocedure(identity)='public.get_ready_stock_models_v1(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text)'::regprocedure
      and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))
      and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))
  ) then '20261125-ready-model-esim-1' end;
$version$;
revoke all on function public.get_ready_model_esim_version() from public,anon,authenticated;
grant execute on function public.get_ready_model_esim_version() to anon,authenticated;

do $verify$
begin
  if public.get_ready_model_esim_version() is distinct from '20261125-ready-model-esim-1' then
    raise exception 'Ready Stock Model Summary e-Sim could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_ready_model_esim_version() as installed_ready_model_esim_version;
