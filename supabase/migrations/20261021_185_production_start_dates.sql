-- Label a 6 PM production period by its START date. Preserve saved counts,
-- original timestamps, closing-stock dates and the indexed legacy day function.
begin;
do $$ begin
 if public.get_production_period_version() is distinct from '20261021-production-periods-1' then raise exception 'Install the verified 6 PM Production update first.';end if;
end; $$;
create or replace function public.get_production_period_report_v2(
 p_from date default null,p_to date default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false
) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r jsonb;items jsonb;begin
 perform greenloop_private.closing_stock_require('production_report');
 if p_from<'2000-01-01'::date or p_to<'2000-01-01'::date or p_day<'2000-01-01'::date or p_from>'9999-12-30'::date or p_to>'9999-12-30'::date or p_day>'9999-12-30'::date then raise exception 'Choose valid production dates.' using errcode='22023';end if;
 -- Delegate calculation and search/sort/export guards to the verified reader.
 -- Its dates are end dates; the new API consistently accepts/returns start dates.
 r:=public.get_production_period_report_v1(p_from+1,p_to+1,p_day+1,p_query,p_sort,p_offset,p_download);
 if r->>'day' is null then
  select coalesce(jsonb_agg(value||jsonb_build_object('day',(value->>'day')::date-1) order by ordinality),'[]'::jsonb) into items from jsonb_array_elements(r->'rows') with ordinality;
 else items:=r->'rows';end if;
 return r||jsonb_build_object('rows',items,'date_basis','start','from',(r->>'from')::date-1,'to',(r->>'to')::date-1,'day',(r->>'day')::date-1,'current_day',(r->>'current_day')::date-1);
end; $$;
revoke all on function public.get_production_period_report_v2(date,date,date,text,text,integer,boolean) from public,anon;
grant execute on function public.get_production_period_report_v2(date,date,date,text,text,integer,boolean) to authenticated;
create table if not exists greenloop_private.production_start_date_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_start_date_installation enable row level security;
revoke all on greenloop_private.production_start_date_installation from public,anon,authenticated;
insert into greenloop_private.production_start_date_installation select 'public.get_production_period_report_v2(date,date,date,text,text,integer,boolean)',md5(pg_get_functiondef('public.get_production_period_report_v2(date,date,date,text,text,integer,boolean)'::regprocedure)) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_start_date_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_period_version()='20261021-production-periods-1'
 and (select count(*)=1 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.production_start_date_installation)
 and not has_function_privilege('anon','public.get_production_period_report_v2(date,date,date,text,text,integer,boolean)','EXECUTE')
 and has_function_privilege('authenticated','public.get_production_period_report_v2(date,date,date,text,text,integer,boolean)','EXECUTE')
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_start_date_installation'::regclass)
 then '20261021-production-start-dates-1' end;
$$;
revoke all on function public.get_production_start_date_version() from public;
grant execute on function public.get_production_start_date_version() to anon,authenticated;
do $$ begin if public.get_production_start_date_version() is distinct from '20261021-production-start-dates-1' then raise exception 'Production date verification failed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_production_start_date_version() as installed_production_start_date_version;
