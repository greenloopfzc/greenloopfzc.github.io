-- Grade D Housing is a default; a deliberately supplied parts list is authoritative.
begin;
do $$begin
 if public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'then raise exception 'Install the verified QC automatic rules first.';end if;
 if to_regprocedure('public.get_qc_choice_defaults_version()')is not null then if public.get_qc_choice_defaults_version()is distinct from '20261103-qc-choice-defaults-1'then raise exception 'Existing QC choice defaults need review.';end if;end if;
end;$$;
do $patch$declare
 impl regprocedure:='greenloop_private.qca_housing(text,jsonb)'::regprocedure;
 ddl text:=pg_get_functiondef(impl);
 old_condition text:=$old$upper(btrim(p_grade))='D'and not exists(select 1 from jsonb_array_elements(parts)x where greenloop_private.pp_key(x->>'part_name')='housing')$old$;
 new_condition text:=$new$upper(btrim(p_grade))='D'and jsonb_array_length(parts)=0 $new$;
begin
 if strpos(ddl,old_condition)>0 then
  ddl:=replace(ddl,old_condition,new_condition);
  ddl:=replace(ddl,'Automatically required for GL Grade D','Default Housing for GL Grade D');execute ddl;
 elsif strpos(ddl,new_condition)=0 then raise exception 'Grade D default helper differs from the reviewed version. Nothing was changed.';end if;
 update greenloop_private.qc_auto_rules_installation set hash=md5(pg_get_functiondef(impl))where to_regprocedure(identity)=impl;
 if not found then raise exception 'Grade D helper verification receipt is missing.';end if;
end;$patch$;
-- Private helper and existing entry functions retain their original ownership/grants.
create table if not exists greenloop_private.qc_choice_defaults_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_choice_defaults_installation enable row level security;
revoke all on greenloop_private.qc_choice_defaults_installation from public,anon,authenticated;
create or replace function public.get_qc_choice_defaults_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_auto_rules_version()='20261031-qc-auto-rules-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_choice_defaults_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.qc_choice_defaults_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.qc_choice_defaults_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.qc_choice_defaults_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.qca_housing(text,jsonb)','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.qca_housing(text,jsonb)','EXECUTE')
 then '20261103-qc-choice-defaults-1'end;
$$;
revoke all on function public.get_qc_choice_defaults_version()from public;
grant execute on function public.get_qc_choice_defaults_version()to anon,authenticated;
insert into greenloop_private.qc_choice_defaults_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.qca_housing(text,jsonb)'::regprocedure,'public.get_qc_choice_defaults_version()'::regprocedure)
on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_qc_choice_defaults_version()is distinct from '20261103-qc-choice-defaults-1'then raise exception 'QC choice defaults verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_choice_defaults_version()as installed_qc_choice_defaults_version;
