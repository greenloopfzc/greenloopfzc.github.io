-- Compact own-user saved-entry receipts. No stock, dates or permissions change.
begin;
do $$begin if public.get_production_last_day_visibility_version() is distinct from '20261023-production-last-day-visibility-1' then raise exception 'Install verified Last Day Visibility first.';end if;end;$$;

create or replace function public.get_my_recent_production_entries_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare items jsonb;begin
 perform greenloop_private.closing_stock_require('entry');
 select coalesce(jsonb_agg(to_jsonb(x) order by recorded_at desc,id desc),'[]') into items from(
  select a.id,a.request_id,m.name model,b.name gb,g.name grade,a.count_quantity quantity,a.recorded_at,greenloop_private.production_period_day(a.recorded_at)-1 production_day
  from greenloop_private.closing_stock_audit a join greenloop_private.closing_stock_options m on m.id=a.model_id join greenloop_private.closing_stock_options b on b.id=a.gb_id join greenloop_private.closing_stock_options g on g.id=a.grade_id
  where a.actor_id=auth.uid() and a.undone_at is null order by a.recorded_at desc,a.id desc limit 2
 )x;
 return jsonb_build_object('rows',items);
end;$$;

create or replace function public.save_period_stock_v1(p_request uuid,p_model uuid,p_gb uuid,p_grade uuid,p_day date,p_quantity integer,p_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare r jsonb;d date;q bigint;receipt jsonb;begin
 perform greenloop_private.closing_stock_require('entry');perform pg_advisory_xact_lock(17920261019);
 r:=public.save_closing_stock_v1(p_request,p_model,p_gb,p_grade,p_day,p_quantity,p_revision);
 select greenloop_private.production_period_day(recorded_at)-1 into d from greenloop_private.closing_stock_audit where request_id=p_request;
 select coalesce(sum(quantity),0) into q from greenloop_private.counted_period_rows(d,d) where model_id=p_model and gb_id=p_gb and grade_id=p_grade;
 select jsonb_build_object('id',a.id,'request_id',a.request_id,'model',m.name,'gb',b.name,'grade',g.name,'quantity',a.count_quantity,'recorded_at',a.recorded_at,'production_day',greenloop_private.production_period_day(a.recorded_at)-1) into receipt
 from greenloop_private.closing_stock_audit a join greenloop_private.closing_stock_options m on m.id=a.model_id join greenloop_private.closing_stock_options b on b.id=a.gb_id join greenloop_private.closing_stock_options g on g.id=a.grade_id
 where a.request_id=p_request and a.actor_id=auth.uid() and a.undone_at is null;
 return r||jsonb_build_object('quantity',q,'production_day',d,'date_basis','start','calculation_basis','period_entries','entry',receipt);
end;$$;
revoke all on function public.get_my_recent_production_entries_v1(),public.save_period_stock_v1(uuid,uuid,uuid,uuid,date,integer,bigint) from public,anon;
grant execute on function public.get_my_recent_production_entries_v1(),public.save_period_stock_v1(uuid,uuid,uuid,uuid,date,integer,bigint) to authenticated;
update greenloop_private.production_period_totals_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='public.save_period_stock_v1(uuid,uuid,uuid,uuid,date,integer,bigint)'::regprocedure;
create index if not exists closing_stock_audit_own_recent on greenloop_private.closing_stock_audit(actor_id,recorded_at desc,id desc) where undone_at is null;

create table if not exists greenloop_private.production_recent_entries_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_recent_entries_installation enable row level security;
revoke all on greenloop_private.production_recent_entries_installation from public,anon,authenticated;
insert into greenloop_private.production_recent_entries_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in('public.get_my_recent_production_entries_v1()'::regprocedure,'public.save_period_stock_v1(uuid,uuid,uuid,uuid,date,integer,bigint)'::regprocedure)
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_recent_entries_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_last_day_visibility_version()='20261023-production-last-day-visibility-1'
 and (select count(*)=2 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')) from greenloop_private.production_recent_entries_installation)
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_recent_entries_installation'::regclass)
 then '20261023-production-recent-entries-1' end;
$$;
revoke all on function public.get_production_recent_entries_version() from public;
grant execute on function public.get_production_recent_entries_version() to anon,authenticated;
do $$begin if public.get_production_recent_entries_version() is distinct from '20261023-production-recent-entries-1' then raise exception 'Recent Production Entries verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_recent_entries_version() as installed_production_recent_entries_version;
