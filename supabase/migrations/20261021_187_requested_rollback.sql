-- Requested rollback: retain 6 PM production periods and their start-date labels.
-- Disable only the later Stock Out feature; retain TV employee selection.
-- Business entries and historical logs are retained in private storage.
begin;
do $$begin
 if public.get_production_start_date_version() is distinct from '20261021-production-start-dates-1' or public.get_damage_tv_employees_version() is distinct from '20261021-damage-tv-employees-1' then raise exception 'Install the verified 6 PM production, start-date and TV employee-selection updates first.';end if;
end;$$;

create table if not exists greenloop_private.requested_rollback_access_backup(
 user_id uuid primary key,capabilities jsonb not null,recorded_at timestamptz not null default clock_timestamp()
);
alter table greenloop_private.requested_rollback_access_backup enable row level security;
revoke all on greenloop_private.requested_rollback_access_backup from public,anon,authenticated;
insert into greenloop_private.requested_rollback_access_backup(user_id,capabilities)
 select user_id,capabilities from greenloop_private.user_page_capabilities on conflict(user_id) do nothing;

-- Remove only the new Stock Out actions; keep prior grants and grade/report access.
do $$declare definition text;begin
 definition:=pg_get_functiondef('greenloop_private.closing_stock_catalog()'::regprocedure);
 if strpos(definition,'stock_out_entry')>0 then
  definition:=regexp_replace(definition,'\{"key":"stock_out_entry"[^}]*\},','','g');
  if strpos(definition,'stock_out_entry')>0 then raise exception 'Unexpected Stock Out catalog. Rollback stopped.';end if;
  execute definition;
 end if;
end;$$;
select greenloop_private.closing_stock_catalog();
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.page_capability_catalog c set capabilities=(select coalesce(jsonb_agg(x order by ord),'[]') from jsonb_array_elements(c.capabilities) with ordinality a(x,ord) where x->>'key' not in('stock_out_view','stock_out_edit','stock_out_delete')) where page_key='reports';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
update greenloop_private.user_page_capabilities u set capabilities=(
 select jsonb_object_agg(k,case when k in('daily_production','reports') then
  (select coalesce(jsonb_agg(x order by ord),'[]') from jsonb_array_elements(v) with ordinality a(x,ord) where x#>>'{}' not in('stock_out_entry','stock_out_view','stock_out_edit','stock_out_delete')) else v end)
 from jsonb_each(u.capabilities) e(k,v)
);

-- Old cached clients cannot call the retired actions. No records are deleted.
do $$declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=any(array[
  'get_production_stock_out_context_v1','save_production_stock_out_v1','get_production_stock_out_entries_v1','get_production_stock_out_changes_v1','correct_production_stock_out_v1','get_production_period_report_v3','get_production_stock_out_version'
 ]) loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);end loop;
end;$$;

create or replace function public.get_requested_rollback_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_start_date_version()='20261021-production-start-dates-1'
 and public.get_damage_tv_employees_version()='20261021-damage-tv-employees-1'
 and not exists(select 1 from greenloop_private.page_capability_catalog c cross join lateral jsonb_array_elements(c.capabilities)x where x->>'key' in('stock_out_entry','stock_out_view','stock_out_edit','stock_out_delete'))
 and not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=any(array['get_production_stock_out_context_v1','save_production_stock_out_v1','get_production_stock_out_entries_v1','get_production_stock_out_changes_v1','correct_production_stock_out_v1','get_production_period_report_v3','get_production_stock_out_version']) and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.requested_rollback_access_backup'::regclass)
 then '20261021-requested-rollback-1' end;
$$;
revoke all on function public.get_requested_rollback_version() from public;
grant execute on function public.get_requested_rollback_version() to anon,authenticated;
do $$begin if public.get_requested_rollback_version() is distinct from '20261021-requested-rollback-1' then raise exception 'Requested rollback verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_requested_rollback_version() as installed_requested_rollback_version;
