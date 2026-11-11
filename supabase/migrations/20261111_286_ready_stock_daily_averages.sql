-- Additive read-only averages; existing business records and daily counts stay intact.
begin;
do $$begin
 if public.get_ready_stock_daily_activity_version()is distinct from '20261111-ready-stock-daily-1'then raise exception 'Verified Ready Stock Daily support is required.';end if;
 if to_regprocedure('public.get_ready_stock_daily_averages_version()')is not null then if public.get_ready_stock_daily_averages_version()is distinct from '20261111-ready-stock-averages-1'then raise exception 'Existing Ready Stock averages require review.';end if;end if;
end;$$;
create or replace function greenloop_private.rsa_average(p_day date)returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
 with days as materialized(select p_day-i as activity_date from generate_series(1,30)i where extract(dow from p_day-i)<>0),
 facts as materialized(select d.activity_date,f.kind,f.device_id from days d cross join lateral greenloop_private.rsd_facts(d.activity_date)f),
 totals as(select(select count(*)from days)days,count(*)filter(where kind='ready')ready,count(*)filter(where kind='export')export from facts)
 select jsonb_build_object('from',p_day-30,'to',p_day-1,'window_days',30,'exclude_sundays',true,'days',days,'ready_total',ready,'export_total',export,'ready_daily',round(ready::numeric/nullif(days,0),2),'export_daily',round(export::numeric/nullif(days,0),2))from totals;
$$;
revoke all on function greenloop_private.rsa_average(date)from public,anon,authenticated;
create or replace function greenloop_private.rsa_metrics(p_date date)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 perform greenloop_private.require_office_network();
 -- Existing daily reader enforces role, view, historical-date search and TV rules.
 result:=greenloop_private.rsd_read(p_date,null,0,50);
 return result||jsonb_build_object('average',greenloop_private.rsa_average((result->>'date')::date));
end;$$;
revoke all on function greenloop_private.rsa_metrics(date)from public,anon,authenticated;
create or replace function public.get_ready_stock_daily_metrics_v1(p_date date default null)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.rsa_metrics(p_date);end;$$;
revoke all on function public.get_ready_stock_daily_metrics_v1(date)from public,anon,authenticated;
grant execute on function public.get_ready_stock_daily_metrics_v1(date)to authenticated;
insert into greenloop_private.office_routines select 'public.get_ready_stock_daily_metrics_v1(date)','greenloop_private.rsa_metrics(date)',md5(pg_get_functiondef('greenloop_private.rsa_metrics(date)'::regprocedure)),md5(pg_get_functiondef('public.get_ready_stock_daily_metrics_v1(date)'::regprocedure))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_ready_stock_daily_metrics_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_ready_stock_daily_averages_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.ready_average_installation(identity text primary key,hash text not null);
alter table greenloop_private.ready_average_installation enable row level security;revoke all on greenloop_private.ready_average_installation from public,anon,authenticated;
create or replace function public.get_ready_stock_daily_averages_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.ready_average_installation)
 and has_function_privilege('authenticated','public.get_ready_stock_daily_metrics_v1(date)','EXECUTE')and not has_function_privilege('anon','public.get_ready_stock_daily_metrics_v1(date)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsa_average(date)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsa_average(date)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsa_metrics(date)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsa_metrics(date)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.ready_average_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.ready_average_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.ready_average_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_ready_stock_daily_metrics_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 then '20261111-ready-stock-averages-1'end;
$$;
revoke all on function public.get_ready_stock_daily_averages_version()from public;grant execute on function public.get_ready_stock_daily_averages_version()to anon,authenticated;
insert into greenloop_private.ready_average_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rsa_average(date)','greenloop_private.rsa_metrics(date)','public.get_ready_stock_daily_metrics_v1(date)','public.get_ready_stock_daily_averages_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_ready_stock_daily_averages_version()is distinct from '20261111-ready-stock-averages-1'or public.get_ready_stock_daily_activity_version()is distinct from '20261111-ready-stock-daily-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Ready Stock averages failed verification. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_ready_stock_daily_averages_version()as installed_ready_stock_daily_averages_version;
