-- Scope cache invalidation to its singleton key. Keep database safe-update checks enabled.
begin;
do $$declare checked jsonb;r record;impl regprocedure;ddl text;old_sql text:='update greenloop_private.qc_work_usage_cache set built_at=''-infinity'';';new_sql text:='update greenloop_private.qc_work_usage_cache set built_at=''-infinity'' where singleton = true;';begin
 checked:=public.get_installation_verification_version();
 if checked->'versions'->'get_full_imei_workflow_version'->>'version'is distinct from '20261029-full-imei-workflow-1'then raise exception 'Verified Full IMEI Workflow Correction is required before the save fix.';end if;
 select *into r from greenloop_private.office_routines where to_regprocedure(identity)='public.save_full_imei_workflow_v1(uuid,text,jsonb,text,text)'::regprocedure;
 impl:=to_regprocedure(r.implementation);
 if impl is null or r.original_hash is distinct from md5(pg_get_functiondef(impl))or not exists(select 1 from greenloop_private.full_imei_workflow_installation where to_regprocedure(identity)=impl and hash=md5(pg_get_functiondef(impl)))then raise exception 'Correction save implementation could not be verified. Nothing was changed.';end if;
 ddl:=pg_get_functiondef(impl);
 if strpos(ddl,old_sql)>0 then
  if(length(ddl)-length(replace(ddl,old_sql,'')))/length(old_sql)<>1 then raise exception 'Unexpected cache update definition. Nothing was changed.';end if;
  execute replace(ddl,old_sql,new_sql);
 elsif strpos(ddl,new_sql)=0 then raise exception 'The known cache update could not be located. Nothing was changed.';end if;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where identity=r.identity;
 update greenloop_private.full_imei_workflow_installation set hash=md5(pg_get_functiondef(impl))where to_regprocedure(identity)=impl;
end;$$;
create table if not exists greenloop_private.full_imei_save_fix_installation(identity text primary key,hash text not null);
alter table greenloop_private.full_imei_save_fix_installation enable row level security;
revoke all on greenloop_private.full_imei_save_fix_installation from public,anon,authenticated;
create or replace function public.get_full_imei_save_fix_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_installation_verification_version()->'versions'->'get_full_imei_workflow_version'->>'version'='20261029-full-imei-workflow-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.full_imei_save_fix_installation)
 and exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)='public.save_full_imei_workflow_v1(uuid,text,jsonb,text,text)'::regprocedure and strpos(pg_get_functiondef(to_regprocedure(implementation)),'update greenloop_private.qc_work_usage_cache set built_at=''-infinity'' where singleton = true;')>0)
 and exists(select 1 from pg_class where oid='greenloop_private.full_imei_save_fix_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.full_imei_save_fix_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.full_imei_save_fix_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261029-full-imei-save-fix-1'end;
$$;
revoke all on function public.get_full_imei_save_fix_version()from public;
grant execute on function public.get_full_imei_save_fix_version()to anon,authenticated;
insert into greenloop_private.full_imei_save_fix_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid='public.get_full_imei_save_fix_version()'::regprocedure or p.oid=(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.save_full_imei_workflow_v1(uuid,text,jsonb,text,text)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_full_imei_save_fix_version()is distinct from '20261029-full-imei-save-fix-1'then raise exception 'Full IMEI correction save fix verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_full_imei_save_fix_version()as installed_full_imei_save_fix_version;
