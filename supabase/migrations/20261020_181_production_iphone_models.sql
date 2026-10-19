-- Approved Daily Production model choices. GB and grades remain separate.
begin;
do $$begin
 if public.get_closing_stock_version() is distinct from '20261019-closing-stock-1' then
  raise exception 'Install the verified Closing Stock update first.';
 end if;
end;$$;

create table if not exists greenloop_private.production_iphone_models_installation(
 model_name text primary key,
 option_id uuid not null references greenloop_private.closing_stock_options(id),
 installed_at timestamptz not null default clock_timestamp()
);
alter table greenloop_private.production_iphone_models_installation enable row level security;
revoke all on greenloop_private.production_iphone_models_installation from public,anon,authenticated;

do $models$
declare
 v_model_name text; model_key text; chosen_id uuid; existing_count integer;
begin
 -- Same lock used by Manage Choices; do not race an add/archive operation.
 perform pg_advisory_xact_lock(17920261019);
 foreach v_model_name in array array[
  'iPhone 13 mini','iPhone 13','iPhone 13 Pro','iPhone 13 Pro Max',
  'iPhone 14','iPhone 14 Plus','iPhone 14 Pro','iPhone 14 Pro Max',
  'iPhone 15','iPhone 15 Plus','iPhone 15 Pro','iPhone 15 Pro Max',
  'iPhone 16e','iPhone 16','iPhone 16 Plus','iPhone 16 Pro','iPhone 16 Pro Max',
  'iPhone 17e','iPhone 17','iPhone 17 Pro','iPhone 17 Pro Max',
  'iPhone Air','iPhone 18 Pro','iPhone 18 Pro Max'
 ] loop
  -- Reruns must respect choices later removed or renamed through Manage Choices.
  if exists(select 1 from greenloop_private.production_iphone_models_installation i where i.model_name=v_model_name) then continue;end if;
  model_key:=regexp_replace(regexp_replace(replace(lower(v_model_name),'+','plus'),'[\s._-]','','g'),'^(appleiphone|iphone|apple)','');
  select count(*) into existing_count from greenloop_private.closing_stock_options o
   where o.kind='model' and regexp_replace(regexp_replace(replace(lower(o.name),'+','plus'),'[\s._-]','','g'),'^(appleiphone|iphone|apple)','')=model_key;
  -- Prefer the exact existing name, then an active alias. Keep all stock IDs.
  select o.id into chosen_id from greenloop_private.closing_stock_options o
   where o.kind='model' and regexp_replace(regexp_replace(replace(lower(o.name),'+','plus'),'[\s._-]','','g'),'^(appleiphone|iphone|apple)','')=model_key
   order by (lower(o.name)=lower(v_model_name)) desc,o.active desc,o.id limit 1 for update;
  if chosen_id is null then
   insert into greenloop_private.closing_stock_options(kind,name) values('model',v_model_name) returning id into chosen_id;
  else
   update greenloop_private.closing_stock_options set name=v_model_name,active=true where id=chosen_id;
  end if;
  if existing_count>1 then raise notice 'Existing aliases for % retained with their separate history; no extra model created.',v_model_name;end if;
  insert into greenloop_private.production_iphone_models_installation(model_name,option_id) values(v_model_name,chosen_id);
 end loop;
end;$models$;

-- Only an installation version is public. Choices use existing page permissions.
create or replace function public.get_production_iphone_models_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_closing_stock_version()='20261019-closing-stock-1'
 and (select count(*)=24 and count(distinct i.option_id)=24 and bool_and(o.kind='model')
      from greenloop_private.production_iphone_models_installation i
      join greenloop_private.closing_stock_options o on o.id=i.option_id)
 and (select relrowsecurity
      and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      from pg_class where oid='greenloop_private.production_iphone_models_installation'::regclass)
 then '20261020-production-iphone-models-1' end;
$$;
revoke all on function public.get_production_iphone_models_version() from public;
grant execute on function public.get_production_iphone_models_version() to anon,authenticated;
do $$begin
 if public.get_production_iphone_models_version() is distinct from '20261020-production-iphone-models-1' then
  raise exception 'iPhone model choices verification failed. Installation rolled back.';
 end if;
end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_iphone_models_version() as installed_production_iphone_models_version;
