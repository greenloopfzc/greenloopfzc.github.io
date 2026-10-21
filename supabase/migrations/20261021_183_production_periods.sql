-- Production-only reporting uses saved timestamps; existing calendar stock remains intact.
begin;
do $$begin if public.get_production_corrections_version() is distinct from '20261020-production-corrections-1' then raise exception 'Install Production Corrections first.';end if;end;$$;
create table if not exists greenloop_private.production_period_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_period_installation enable row level security;
revoke all on greenloop_private.production_period_installation from public,anon,authenticated;

create or replace function greenloop_private.closing_stock_catalog() returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare caps jsonb;begin
 select '[{"key":"view","label":"Open Daily Production","write":false},{"key":"entry","label":"Daily Data Entry / Save box counts","write":true},{"key":"voice_entry","label":"Voice Entry (requires Daily Data Entry)","write":false},{"key":"total_stock","label":"Total Stock report (all grades)","write":false},{"key":"production_report","label":"Daily Production (all grades; 6 PM cutoff)","write":false},{"key":"date_report","label":"Date-wise stock report","write":false},{"key":"manage_options","label":"Add / remove Model, GB and Grade","write":true},{"key":"search","label":"Search / Report date","write":false},{"key":"sort","label":"Sort table headings","write":false},{"key":"download","label":"Download permitted reports","write":false}]'::jsonb||coalesce(jsonb_agg(jsonb_build_object('key',greenloop_private.closing_grade_key(id),'label','Grade '||name||' report','write',false) order by lower(name)),'[]') into caps from greenloop_private.closing_stock_options where kind='grade';
 update greenloop_private.page_capability_catalog set capabilities=caps where page_key='daily_production';
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
end;$$;
-- Snapshot effective grants before adding the opt-in capability for existing staff.
do $$declare u record;begin
 for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
  insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
 end loop;
end;$$;
select greenloop_private.closing_stock_catalog();
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
do $$declare u record;begin
 for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where not greenloop_private.damage_tv_only(p.id) and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p.id and r.role_key::text in ('owner','super_admin')) loop
  if (u.caps->'daily_production')?'view' and not (u.caps->'daily_production')?'production_report' then
   update greenloop_private.user_page_capabilities set capabilities=jsonb_set(capabilities,'{daily_production}',coalesce(capabilities->'daily_production','[]'::jsonb)||'["production_report"]'::jsonb) where user_id=u.id;
  end if;
 end loop;
end;$$;

-- The date identifies the END of a period: D-1 6:00 PM through D 6:00 PM UAE.
-- Start is inclusive; end is exclusive. Exactly 6:00 PM starts the next period.
create or replace function greenloop_private.production_period_day(p_at timestamptz) returns date language sql immutable strict set search_path=pg_catalog as $$
 select ((p_at at time zone 'Asia/Dubai')-interval '18 hours')::date+1;
$$;
create index if not exists closing_stock_audit_period on greenloop_private.closing_stock_audit(greenloop_private.production_period_day(recorded_at),model_id,gb_id,grade_id) where undone_at is null;

create or replace function greenloop_private.production_period_rows(p_from date,p_to date)
returns table(period_day date,model_id uuid,gb_id uuid,grade_id uuid,model text,gb text,grade text,production bigint)
language sql stable security definer set search_path=pg_catalog,public as $$
 with counted as (
  select greenloop_private.production_period_day(a.recorded_at) as day,a.model_id,a.gb_id,a.grade_id,sum(a.count_quantity)::bigint quantity,1 priority
  from greenloop_private.closing_stock_audit a where a.undone_at is null and greenloop_private.production_period_day(a.recorded_at)<=p_to
  group by 1,a.model_id,a.gb_id,a.grade_id
 ), snapshots as (
  select distinct on(day,model_id,gb_id,grade_id) * from (
   select * from counted
   union all
   -- Legacy balances have only their saved closing date. Keep that date as baseline.
   select stock_date,model_id,gb_id,grade_id,quantity::bigint,0 from greenloop_private.closing_stock_daily where stock_source='legacy' and stock_date<=p_to
  ) x order by day,model_id,gb_id,grade_id,priority desc
 ), changes as (
  select *,greatest(quantity-lag(quantity,1,0::bigint) over(partition by model_id,gb_id,grade_id order by day),0)::bigint increase from snapshots
 )
 select x.day,x.model_id,x.gb_id,x.grade_id,m.name,b.name,g.name,x.increase from changes x
 join greenloop_private.closing_stock_options m on m.id=x.model_id join greenloop_private.closing_stock_options b on b.id=x.gb_id join greenloop_private.closing_stock_options g on g.id=x.grade_id
 where x.day between p_from and p_to and x.increase>0;
$$;

create or replace function public.get_production_period_report_v1(p_from date default null,p_to date default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();current_day date:=greenloop_private.production_period_day(stamp);d_from date;d_to date;items jsonb;stats jsonb;total integer;lim integer;
begin
 perform greenloop_private.closing_stock_require('production_report');
 d_from:=coalesce(p_from,current_day);d_to:=coalesce(p_to,current_day);
 if d_from is distinct from current_day or d_to is distinct from current_day or (p_day is not null and p_day is distinct from current_day) or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d_from<'2000-01-01'::date or d_to<d_from or d_to>current_day or d_to-d_from>366 or (p_day is not null and p_day not between d_from and d_to) or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in ('default','date_asc','date_desc','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','production_asc','production_desc') then raise exception 'Choose a valid production date range of up to 367 days.' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 if p_day is null then
  with f as (select * from greenloop_private.production_period_rows(d_from,d_to) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),days as (
   select d::date as day,coalesce(sum(f.production),0)::bigint production,count(distinct f.model_id)::integer models from generate_series(d_from::timestamp,d_to::timestamp,'1 day') d left join f on f.period_day=d::date group by d
  ),ranked as (select *,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='date_asc' then day end asc,day desc) rn from days)
  select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',coalesce(sum(production),0),'days',count(*)) from days) into total,items,stats from ranked r;
 else
  with f as (select * from greenloop_private.production_period_rows(p_day,p_day) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),ranked as (
   select model_id,gb_id,grade_id,model,gb,grade,production,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,lower(model),gb,grade,model_id,gb_id,grade_id) rn from f
  ) select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',coalesce(sum(production),0),'models',count(distinct model_id)) from f) into total,items,stats from ranked r;
 end if;
 if p_download and total>10000 then raise exception 'Narrow the filters to export at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('rows',items,'total',total,'stats',stats,'from',d_from,'to',d_to,'day',p_day,'current_day',current_day,'server_now',stamp,'current_period_end',(current_day+time '18:00') at time zone 'Asia/Dubai','period_start',case when p_day is not null then ((p_day-1)+time '18:00') at time zone 'Asia/Dubai' end,'period_end',case when p_day is not null then (p_day+time '18:00') at time zone 'Asia/Dubai' end);
end;$$;

do $$declare f record;begin
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('production_period_day','production_period_rows','get_production_period_report_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
  insert into greenloop_private.production_period_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$$;
create or replace function public.get_production_period_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_corrections_version()='20261020-production-corrections-1'
 and (select count(*)=3 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.production_period_installation)
 and (select relrowsecurity and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_period_installation'::regclass)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"production_report","write":false}]'::jsonb)
 then '20261021-production-periods-1' end;
$$;
revoke all on function public.get_production_period_version() from public;grant execute on function public.get_production_period_version() to anon,authenticated;
do $$begin if public.get_production_period_version() is distinct from '20261021-production-periods-1' then raise exception 'Production period verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_production_period_version() as installed_production_period_version;
