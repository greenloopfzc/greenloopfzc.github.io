-- Glass and Glass (Glass Damage) are the same required part in grade analysis.
begin;
do $$declare prior text;begin
 prior:=md5(pg_get_functiondef('greenloop_private.sga_key(text)'::regprocedure));
 if not exists(select 1 from greenloop_private.sga_installation where to_regprocedure(identity)='greenloop_private.sga_key(text)'::regprocedure and hash=prior)then raise exception 'Grade analysis part matching changed. Review it before installing this fix.';end if;
 perform set_config('greenloop.grade_glass_before',prior,true);
end;$$;
create or replace function greenloop_private.sga_key(v text)returns text language sql immutable set search_path=pg_catalog as $$
 select case when k in('glassglassdamage','glassdamagedglass')then 'glass'else k end from(select regexp_replace(lower(coalesce(btrim(v),'')),'[^a-z0-9]','','g')k)s;
$$;
revoke all on function greenloop_private.sga_key(text)from public,anon,authenticated;
-- Refresh only the previously verified seal for this single changed helper.
update greenloop_private.sga_installation set hash=md5(pg_get_functiondef('greenloop_private.sga_key(text)'::regprocedure))where to_regprocedure(identity)='greenloop_private.sga_key(text)'::regprocedure and hash=current_setting('greenloop.grade_glass_before');
create or replace function public.get_grade_glass_alias_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when greenloop_private.sga_key('Glass')='glass'and greenloop_private.sga_key('Glass (Glass Damage)')='glass'
 and greenloop_private.sga_key('Glass (Damaged Glass)')='glass'
 and greenloop_private.sga_key('Back Glass')='backglass'
 and exists(select 1 from greenloop_private.sga_installation where to_regprocedure(identity)='greenloop_private.sga_key(text)'::regprocedure and hash=md5(pg_get_functiondef('greenloop_private.sga_key(text)'::regprocedure)))
 and not has_function_privilege('authenticated','greenloop_private.sga_key(text)','EXECUTE')and not has_function_privilege('anon','greenloop_private.sga_key(text)','EXECUTE')
 then '20261112-grade-glass-alias-1'end;
$$;
revoke all on function public.get_grade_glass_alias_version()from public;
grant execute on function public.get_grade_glass_alias_version()to anon,authenticated;
do $$begin if public.get_grade_glass_alias_version()is distinct from '20261112-grade-glass-alias-1'then raise exception 'Grade Glass alias verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_grade_glass_alias_version()as installed_grade_glass_alias_version;
