-- Every dashboard/report quantity is the sum of active saved box counts in
-- its UAE 6 PM-to-6 PM period. Saved entries, dates and history are not rewritten.
begin;
do $$begin if public.get_production_restore_version() is distinct from '20261021-production-restore-1' then raise exception 'Install the verified Production Restore update first.';end if;end;$$;

create or replace function greenloop_private.counted_period_rows(p_from date,p_to date)
returns table(period_day date,model_id uuid,gb_id uuid,grade_id uuid,model text,gb text,grade text,quantity bigint,production bigint)
language sql stable security definer set search_path=pg_catalog,public as $$
 with q as(select greenloop_private.production_period_day(a.recorded_at)-1 as day,a.model_id,a.gb_id,a.grade_id,sum(a.count_quantity)::bigint qty
 from greenloop_private.closing_stock_audit a where a.undone_at is null and greenloop_private.production_period_day(a.recorded_at) between p_from+1 and p_to+1
 group by 1,a.model_id,a.gb_id,a.grade_id)
 select q.day,q.model_id,q.gb_id,q.grade_id,m.name,b.name,g.name,q.qty,q.qty from q
 join greenloop_private.closing_stock_options m on m.id=q.model_id join greenloop_private.closing_stock_options b on b.id=q.gb_id join greenloop_private.closing_stock_options g on g.id=q.grade_id;
$$;

create or replace function public.get_period_stock_home_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();d date:=greenloop_private.production_period_day(stamp)-1;cards jsonb;opts jsonb;tot jsonb;begin
 perform greenloop_private.closing_stock_require('view');
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'quantity',coalesce(q.quantity,0),'capability',greenloop_private.closing_grade_key(o.id)) order by lower(o.name)),'[]') into cards
 from greenloop_private.closing_stock_options o left join(select grade_id,sum(quantity) quantity from greenloop_private.counted_period_rows(d,d) group by grade_id)q on q.grade_id=o.id
 where o.kind='grade' and public.has_page_capability_v1('daily_production',greenloop_private.closing_grade_key(o.id)) and exists(select 1 from greenloop_private.closing_stock_audit a where a.grade_id=o.id);
 if public.has_page_capability_v1('daily_production','entry') or public.has_page_capability_v1('daily_production','manage_options') then
  select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name)),'[]') into opts from greenloop_private.closing_stock_options o;
 else opts:='[]';end if;
 if public.has_page_capability_v1('daily_production','total_stock') then select jsonb_build_object('quantity',coalesce(sum(quantity),0)) into tot from greenloop_private.counted_period_rows(d,d);end if;
 return jsonb_build_object('today',d,'date_basis','start','calculation_basis','period_entries','cards',cards,'options',opts,'total',tot,'server_now',stamp,'current_period_end',((d+1)+time '18:00') at time zone 'Asia/Dubai');
end;$$;


create or replace function public.get_period_stock_selection_v1(p_model uuid,p_gb uuid,p_grade uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r jsonb;d date:=greenloop_private.production_period_day(statement_timestamp())-1;q bigint;begin
 r:=public.get_closing_stock_selection_v1(p_model,p_gb,p_grade);
 select coalesce(sum(quantity),0) into q from greenloop_private.counted_period_rows(d,d) where model_id=p_model and gb_id=p_gb and grade_id=p_grade;
 return r||jsonb_build_object('counted_today',q,'production_day',d,'date_basis','start','calculation_basis','period_entries');
end;$$;
create or replace function public.save_period_stock_v1(p_request uuid,p_model uuid,p_gb uuid,p_grade uuid,p_day date,p_quantity integer,p_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare r jsonb;d date;q bigint;begin
 perform greenloop_private.closing_stock_require('entry');perform pg_advisory_xact_lock(17920261019);
 r:=public.save_closing_stock_v1(p_request,p_model,p_gb,p_grade,p_day,p_quantity,p_revision);
 select greenloop_private.production_period_day(recorded_at)-1 into d from greenloop_private.closing_stock_audit where request_id=p_request;
 select coalesce(sum(quantity),0) into q from greenloop_private.counted_period_rows(d,d) where model_id=p_model and gb_id=p_gb and grade_id=p_grade;
 return r||jsonb_build_object('quantity',q,'production_day',d,'date_basis','start','calculation_basis','period_entries');
end;$$;
create or replace function public.undo_period_stock_v1(p_request uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.closing_stock_audit;begin
 perform greenloop_private.closing_stock_require('entry');perform pg_advisory_xact_lock(17920261019);
 if p_request is null then raise exception 'Choose your saved count.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-request:'||p_request,0));
 select * into a from greenloop_private.closing_stock_audit where request_id=p_request for update;
 if not found or a.actor_id<>auth.uid() then raise exception 'Only your own count can be undone.' using errcode='42501';end if;
 if a.undone_at is not null then return;end if;
 if greenloop_private.production_period_day(a.recorded_at)<>greenloop_private.production_period_day(clock_timestamp()) then raise exception 'Only counts from the current 6 PM production day can be undone. Use Reports for an older entry.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-pair:'||a.model_id||a.gb_id||a.grade_id,0));
 insert into greenloop_private.closing_stock_correction_log(entry_id,action,actor_id,actor_name,old_model_id,old_gb_id,old_grade_id,old_quantity)
 values(a.id,'delete',auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),a.model_id,a.gb_id,a.grade_id,a.count_quantity);
 update greenloop_private.closing_stock_audit set undone_at=clock_timestamp(),correction_revision=correction_revision+1 where id=a.id;
 perform greenloop_private.recalculate_closing_pair_day(a.model_id,a.gb_id,a.grade_id,a.stock_date);
end;$$;

create or replace function public.get_period_stock_report_v1(p_scope text,p_grade uuid default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();today date:=greenloop_private.production_period_day(stamp)-1;d date:=coalesce(p_day,today);items jsonb;stats jsonb;n integer;lim integer;begin
 perform greenloop_private.closing_stock_require('view');
 if p_scope='total' then perform greenloop_private.closing_stock_require('total_stock');elsif p_scope='grade' and p_grade is not null then perform greenloop_private.closing_stock_require(greenloop_private.closing_grade_key(p_grade));else raise exception 'Choose a permitted stock report.' using errcode='22023';end if;
 if p_day is not null or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d<'2000-01-01'::date or d>today or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in('default','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','quantity_asc','quantity_desc') then raise exception 'Choose valid production dates or filters.' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 with f as(select * from greenloop_private.counted_period_rows(d,d) where(p_scope='total' or grade_id=p_grade) and(coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0)),ranked as(
  select *,row_number() over(order by case when p_sort='quantity_asc' then quantity end asc,case when p_sort='quantity_desc' then quantity end desc,case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,lower(model),gb,grade,model_id,gb_id,grade_id) rn from f)
 select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('quantity',coalesce(sum(quantity),0),'models',count(distinct model_id)) from f) into n,items,stats from ranked r;
 if p_download and n>10000 then raise exception 'Narrow the filters to export at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('rows',items,'total',n,'stats',stats,'date',d,'today',today,'date_basis','start','calculation_basis','period_entries','period_start',(d+time '18:00') at time zone 'Asia/Dubai','period_end',((d+1)+time '18:00') at time zone 'Asia/Dubai','server_now',stamp,'current_period_end',((today+1)+time '18:00') at time zone 'Asia/Dubai');
end;$$;
create or replace function public.get_period_stock_dates_v1(p_from date,p_to date,p_scope text,p_grade uuid default null,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare today date:=greenloop_private.production_period_day(statement_timestamp())-1;items jsonb;begin
 perform greenloop_private.closing_stock_require('date_report');
 if p_scope='total' then perform greenloop_private.closing_stock_require('total_stock');elsif p_scope='grade' and p_grade is not null then perform greenloop_private.closing_stock_require(greenloop_private.closing_grade_key(p_grade));else raise exception 'Choose a permitted stock report.' using errcode='22023';end if;
 if p_from is null or p_to is null or p_from<'2000-01-01'::date or p_to<p_from or p_to>today or p_to-p_from>366 or p_offset is null or p_offset<0 then raise exception 'Choose a production date range of up to 367 days.' using errcode='22023';end if;
 with f as(select * from greenloop_private.counted_period_rows(p_from,p_to) where p_scope='total' or grade_id=p_grade),days as(select d::date as day,coalesce(sum(f.quantity),0)::bigint quantity,count(distinct f.model_id) models from generate_series(p_from::timestamp,p_to::timestamp,'1 day')d left join f on f.period_day=d::date group by d),paged as(select * from days order by day desc offset p_offset limit 50)
 select coalesce(jsonb_agg(to_jsonb(p) order by day desc),'[]') into items from paged p;
 return jsonb_build_object('rows',items,'total',p_to-p_from+1,'from',p_from,'to',p_to,'date_basis','start','calculation_basis','period_entries');
end;$$;

create or replace function public.get_entered_production_report_v1(p_from date default null,p_to date default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();current_day date:=greenloop_private.production_period_day(stamp)-1;d_from date;d_to date;items jsonb;stats jsonb;total integer;lim integer;
begin
 perform greenloop_private.closing_stock_require('production_report');
 d_from:=coalesce(p_from,current_day);d_to:=coalesce(p_to,current_day);
 if d_from is distinct from current_day or d_to is distinct from current_day or (p_day is not null and p_day is distinct from current_day) or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d_from<'2000-01-01'::date or d_to<d_from or d_to>current_day or d_to-d_from>366 or (p_day is not null and p_day not between d_from and d_to) or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in ('default','date_asc','date_desc','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','production_asc','production_desc') then raise exception 'Choose a valid production date range of up to 367 days.' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 if p_day is null then
  with f as (select * from greenloop_private.counted_period_rows(d_from,d_to) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),days as (
   select d::date as day,coalesce(sum(f.production),0)::bigint production,count(distinct f.model_id)::integer models from generate_series(d_from::timestamp,d_to::timestamp,'1 day') d left join f on f.period_day=d::date group by d
  ),ranked as (select *,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='date_asc' then day end asc,day desc) rn from days)
  select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',coalesce(sum(production),0),'days',count(*)) from days) into total,items,stats from ranked r;
 else
  with f as (select * from greenloop_private.counted_period_rows(p_day,p_day) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),ranked as (
   select model_id,gb_id,grade_id,model,gb,grade,production,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,lower(model),gb,grade,model_id,gb_id,grade_id) rn from f
  ) select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',coalesce(sum(production),0),'models',count(distinct model_id)) from f) into total,items,stats from ranked r;
 end if;
 if p_download and total>10000 then raise exception 'Narrow the filters to export at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('rows',items,'total',total,'stats',stats,'from',d_from,'to',d_to,'day',p_day,'current_day',current_day,'date_basis','start','calculation_basis','period_entries','server_now',stamp,'current_period_end',((current_day+1)+time '18:00') at time zone 'Asia/Dubai','period_start',case when p_day is not null then (p_day+time '18:00') at time zone 'Asia/Dubai' end,'period_end',case when p_day is not null then ((p_day+1)+time '18:00') at time zone 'Asia/Dubai' end);
end;$$;


create table if not exists greenloop_private.production_period_totals_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_period_totals_installation enable row level security;
revoke all on greenloop_private.production_period_totals_installation from public,anon,authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','greenloop_private') and p.proname in('counted_period_rows','get_period_stock_home_v1','get_period_stock_selection_v1','save_period_stock_v1','undo_period_stock_v1','get_period_stock_report_v1','get_period_stock_dates_v1','get_entered_production_report_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
  insert into greenloop_private.production_period_totals_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$$;
create or replace function public.get_production_period_totals_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_restore_version()='20261021-production-restore-1'
 and (select count(*)=8 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.production_period_totals_installation)
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_period_totals_installation'::regclass)
 then '20261021-production-period-totals-1' end;
$$;
revoke all on function public.get_production_period_totals_version() from public;
grant execute on function public.get_production_period_totals_version() to anon,authenticated;
do $$begin if public.get_production_period_totals_version() is distinct from '20261021-production-period-totals-1' then raise exception 'Production period totals verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_period_totals_version() as installed_production_period_totals_version;
