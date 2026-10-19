-- Browser voice fills drafts only. Saving remains the existing manual stock action.
begin;
do $$begin if public.get_closing_stock_version() is distinct from '20261019-closing-stock-1' then raise exception 'Install the verified Closing Stock update first.';end if;end;$$;
create table if not exists greenloop_private.production_voice_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_voice_installation enable row level security;
revoke all on greenloop_private.production_voice_installation from public,anon,authenticated;
-- Freeze existing effective access before expanding the catalog. Voice is opt-in.
do $$declare r record;begin
 for r in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
  insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(r.id,r.caps)
  on conflict(user_id) do nothing;
 end loop;
end;$$;
create or replace function greenloop_private.closing_stock_catalog() returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare caps jsonb;begin
 select '[{"key":"view","label":"Open Daily Production","write":false},{"key":"entry","label":"Daily Data Entry / Save box counts","write":true},{"key":"voice_entry","label":"Voice Entry (requires Daily Data Entry)","write":false},{"key":"total_stock","label":"Total Stock report (all grades)","write":false},{"key":"manage_options","label":"Add / remove Model, GB and Grade","write":true},{"key":"search","label":"Search / Report date","write":false},{"key":"sort","label":"Sort table headings","write":false},{"key":"download","label":"Download permitted reports","write":false}]'::jsonb||coalesce(jsonb_agg(jsonb_build_object('key',greenloop_private.closing_grade_key(id),'label','Grade '||name||' report','write',false) order by lower(name)),'[]') into caps from greenloop_private.closing_stock_options where kind='grade';
 update greenloop_private.page_capability_catalog set capabilities=caps where page_key='daily_production';
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
end;$$;

select greenloop_private.closing_stock_catalog();
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
create or replace function public.get_production_voice_access_v1() returns boolean
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.closing_stock_require('entry');
 perform greenloop_private.closing_stock_require('voice_entry');
 return true;
end;$$;
revoke all on function public.get_production_voice_access_v1() from public,anon,authenticated;
grant execute on function public.get_production_voice_access_v1() to authenticated;
do $$declare f text;begin
 foreach f in array array['greenloop_private.closing_stock_catalog()','public.get_production_voice_access_v1()'] loop
  insert into greenloop_private.production_voice_installation values(f,md5(pg_get_functiondef(to_regprocedure(f)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$$;
create or replace function public.get_production_voice_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_closing_stock_version()='20261019-closing-stock-1'
 and (select count(*)=2 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.production_voice_installation)
 and not has_function_privilege('anon','public.get_production_voice_access_v1()','EXECUTE')
 and has_function_privilege('authenticated','public.get_production_voice_access_v1()','EXECUTE')
 and (select relrowsecurity and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') from pg_class where oid='greenloop_private.production_voice_installation'::regclass)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"voice_entry","write":false}]'::jsonb)
 then '20261020-production-voice-1' end;
$$;
revoke all on function public.get_production_voice_version() from public;
grant execute on function public.get_production_voice_version() to anon,authenticated;
do $$begin if public.get_production_voice_version() is distinct from '20261020-production-voice-1' then raise exception 'Production Voice verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_production_voice_version() as installed_production_voice_version;
