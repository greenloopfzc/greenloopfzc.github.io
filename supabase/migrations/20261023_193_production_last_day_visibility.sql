-- Only show the completed-day card while current-period stock is zero.
-- Return a boolean rather than exposing current quantities to Last Day-only users.
begin;
do $$begin if public.get_production_last_day_version() is distinct from '20261022-production-last-day-1' then raise exception 'Install verified Last Day Stock first.';end if;end;$$;

do $$declare definition text;begin
 definition:=pg_get_functiondef('public.get_last_day_production_v1(date,text,text,integer,boolean)'::regprocedure);
 if strpos(definition,'show_last_day_card')=0 then
  definition:=replace(definition,'''last_completed_day'',last_day,','''last_completed_day'',last_day,''show_last_day_card'',not exists(select 1 from greenloop_private.counted_period_rows(current_day,current_day) where quantity>0),');
  if strpos(definition,'show_last_day_card')=0 then raise exception 'Unexpected completed stock report. Installation stopped.';end if;
  execute definition;
 end if;
end;$$;
update greenloop_private.production_last_day_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='public.get_last_day_production_v1(date,text,text,integer,boolean)'::regprocedure;

create table if not exists greenloop_private.production_last_day_visibility_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_last_day_visibility_installation enable row level security;
revoke all on greenloop_private.production_last_day_visibility_installation from public,anon,authenticated;
insert into greenloop_private.production_last_day_visibility_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid='public.get_last_day_production_v1(date,text,text,integer,boolean)'::regprocedure
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_last_day_visibility_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_last_day_version()='20261022-production-last-day-1'
 and (select count(*)=1 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')) from greenloop_private.production_last_day_visibility_installation)
 and (select relrowsecurity and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_last_day_visibility_installation'::regclass)
 then '20261023-production-last-day-visibility-1' end;
$$;
revoke all on function public.get_production_last_day_visibility_version() from public;
grant execute on function public.get_production_last_day_visibility_version() to anon,authenticated;
do $$begin if public.get_production_last_day_visibility_version() is distinct from '20261023-production-last-day-visibility-1' then raise exception 'Last Day Stock visibility verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_last_day_visibility_version() as installed_production_last_day_visibility_version;
