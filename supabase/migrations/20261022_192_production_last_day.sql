-- Read-only completed production day, independent of the current-day zero reset.
begin;
do $$begin if public.get_production_choice_deletion_version() is distinct from '20261022-production-choice-deletion-1' then raise exception 'Install verified Production Choice Deletion first.';end if;end;$$;

do $$declare u record;definition text;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"last_day_report"}]') then
  for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
   insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
  end loop;
  definition:=pg_get_functiondef('greenloop_private.closing_stock_catalog()'::regprocedure);
  definition:=replace(definition,'{"key":"production_report","label":"Daily Production (all grades; 6 PM cutoff)","write":false}',
   '{"key":"production_report","label":"Daily Production (all grades; 6 PM cutoff)","write":false},{"key":"last_day_report","label":"Last Day Total Stock (all grades; completed 6 PM day)","write":false}');
  if strpos(definition,'last_day_report')=0 then raise exception 'Unexpected production permission catalog. Installation stopped.';end if;
  execute definition;
  perform greenloop_private.closing_stock_catalog();
  -- Existing all-grade production viewers keep this read-only completed-day view.
  -- Grade-only viewers are not expanded to all grades.
  for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
   if not greenloop_private.damage_tv_only(u.id) and (u.caps->'daily_production')?'view' and (u.caps->'daily_production')?'production_report' and not(u.caps->'daily_production')?'last_day_report' then
    update greenloop_private.user_page_capabilities set capabilities=jsonb_set(capabilities,'{daily_production}',(capabilities->'daily_production')||'["last_day_report"]') where user_id=u.id;
   end if;
  end loop;
 end if;
end;$$;
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='greenloop_private.closing_stock_catalog()'::regprocedure;
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='greenloop_private.closing_stock_catalog()'::regprocedure;
update greenloop_private.production_choice_deletion_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity<>'audit_trigger' and to_regprocedure(identity)='greenloop_private.closing_stock_catalog()'::regprocedure;

create or replace function public.get_last_day_production_v1(p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();current_day date:=greenloop_private.production_period_day(stamp)-1;
 last_day date:=current_day-1;d date:=coalesce(p_day,last_day);items jsonb;stats jsonb;grades jsonb;n integer;lim integer;
begin
 perform greenloop_private.closing_stock_require('last_day_report');
 if d is distinct from last_day or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d<'2000-01-01'::date or d>last_day or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in('default','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','production_asc','production_desc') then raise exception 'Choose a completed production date (6 PM to the following 6 PM UAE).' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 with f as(select * from greenloop_private.counted_period_rows(d,d) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),ranked as(
  select *,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,lower(model),gb,grade,model_id,gb_id,grade_id) rn from f)
 select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),
  (select jsonb_build_object('production',coalesce(sum(production),0),'models',count(distinct model_id)) from f),
  (select coalesce(jsonb_agg(to_jsonb(g) order by lower(grade)),'[]') from(select grade_id,grade,sum(production) production from f group by grade_id,grade)g)
 into n,items,stats,grades from ranked r;
 if p_download and n>10000 then raise exception 'Narrow the search to export at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('rows',items,'total',n,'stats',stats,'grade_totals',grades,'day',d,'date',d,'current_day',current_day,'last_completed_day',last_day,'date_basis','start','calculation_basis','period_entries',
  'period_start',(d+time '18:00') at time zone 'Asia/Dubai','period_end',((d+1)+time '18:00') at time zone 'Asia/Dubai','server_now',stamp,'current_period_end',((current_day+1)+time '18:00') at time zone 'Asia/Dubai');
end;$$;
revoke all on function public.get_last_day_production_v1(date,text,text,integer,boolean) from public,anon;
grant execute on function public.get_last_day_production_v1(date,text,text,integer,boolean) to authenticated;

create table if not exists greenloop_private.production_last_day_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_last_day_installation enable row level security;
revoke all on greenloop_private.production_last_day_installation from public,anon,authenticated;
insert into greenloop_private.production_last_day_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in('greenloop_private.closing_stock_catalog()'::regprocedure,'public.get_last_day_production_v1(date,text,text,integer,boolean)'::regprocedure)
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_last_day_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_choice_deletion_version()='20261022-production-choice-deletion-1'
 and (select count(*)=2 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.production_last_day_installation)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"last_day_report","write":false}]')
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_last_day_installation'::regclass)
 then '20261022-production-last-day-1' end;
$$;
revoke all on function public.get_production_last_day_version() from public;
grant execute on function public.get_production_last_day_version() to anon,authenticated;
do $$begin if public.get_production_last_day_version() is distinct from '20261022-production-last-day-1' then raise exception 'Last Day Production verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_last_day_version() as installed_production_last_day_version;
