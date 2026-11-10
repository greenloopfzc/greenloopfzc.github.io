-- One physical Ready Stock count for Dashboard and sidebar. No stock rows change.
do $drc_install$begin
do $$begin
 if public.get_content_protection_version()is distinct from '20261109-content-protection-1'
 or public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'
 or public.get_issuance_access_version()is distinct from '20261109-issuance-access-1'
 or public.get_imei_badge_verification_version()is distinct from '20261107-imei-badge-verification-1'
 or public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'
 then raise exception 'Verified Content Protection, sidebar and direct Ready Stock installations are required.';end if;
 if to_regprocedure('public.get_dashboard_ready_counts_version()')is not null then
  if public.get_dashboard_ready_counts_version()is distinct from '20261110-dashboard-ready-counts-1'then raise exception 'Existing Dashboard Ready Stock integrity differs.';end if;
 end if;
end;$$;
create or replace function greenloop_private.drc_ready_count()returns bigint language sql stable security definer set search_path=pg_catalog,public as $$
 select count(distinct d.id)from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null
 where j.deleted_at is null and j.current_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
 and exists(select 1 from greenloop_private.qdr_ready_outcomes f where f.job_id=j.id and f.result='pass');
$$;
revoke all on function greenloop_private.drc_ready_count()from public,anon,authenticated;
do $patch$declare impl regprocedure;ddl text;h text;needle text;begin
 select to_regprocedure(implementation)into strict impl from greenloop_private.office_routines where to_regprocedure(identity)='public.get_overview_workflow_counts()'::regprocedure;
 select replace(pg_get_functiondef(oid),chr(13),''),md5(replace(prosrc,chr(13),''))into ddl,h from pg_proc where oid=impl;
 if position('greenloop-shared-ready-count-276'in ddl)=0 then
  if h is distinct from '00fcaa65299171140c2117672ef52942'then raise exception 'Reviewed Dashboard count source differs.';end if;
  needle:='''ready_stock'',(select count(*) from public.jobs j where j.deleted_at is null and j.current_status in (''qc_passed'',''production_pending'',''production_completed'',''ready_for_packing'',''ready_for_shipment'') and exists(select 1 from public.final_qc_inspections i where i.job_id=j.id and i.result=''pass''))';
  if position(needle in ddl)=0 then raise exception 'Reviewed Dashboard Ready Stock clause is missing.';end if;
  execute replace(replace(ddl,needle,'''ready_stock'',greenloop_private.drc_ready_count()'),'begin',E'-- greenloop-shared-ready-count-276\nbegin');
 end if;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
 select replace(pg_get_functiondef(oid),chr(13),''),md5(replace(prosrc,chr(13),''))into ddl,h from pg_proc where oid='greenloop_private.sbn_counts()'::regprocedure;
 if position('greenloop-shared-ready-count-276'in ddl)=0 then
  if h is distinct from '58cfe35582a9b155ac8b7358a9d31eb9'then raise exception 'Reviewed sidebar count source differs.';end if;
  needle:=E'  select count(distinct d.id)into n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null\n  where j.deleted_at is null and j.current_status in(''qc_passed'',''production_pending'',''production_completed'',''ready_for_packing'',''ready_for_shipment'')\n  and exists(select 1 from greenloop_private.qdr_ready_outcomes f where f.job_id=j.id and f.result=''pass'');';
  if position(needle in ddl)=0 then raise exception 'Reviewed sidebar Ready Stock clause is missing.';end if;
  execute replace(replace(ddl,needle,'  n:=greenloop_private.drc_ready_count();'),'declare ',E'-- greenloop-shared-ready-count-276\ndeclare ');
 end if;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))where to_regprocedure(implementation)='greenloop_private.sbn_counts()'::regprocedure;
 update greenloop_private.sidebar_counts_installation set hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))where kind='function'and to_regprocedure(identity)='greenloop_private.sbn_counts()'::regprocedure;
 if not found then raise exception 'Sidebar count verification row is missing.';end if;
 update greenloop_private.imei_pending_badge_installation set hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))where to_regprocedure(identity)='greenloop_private.sbn_counts()'::regprocedure;
 if not found then raise exception 'IMEI badge verification row is missing.';end if;
 update greenloop_private.imei_badge_verification_installation set hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))where to_regprocedure(identity)='greenloop_private.sbn_counts()'::regprocedure;
 if not found then raise exception 'IMEI badge integrity row is missing.';end if;
 update greenloop_private.issuance_access_installation set hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))where to_regprocedure(identity)='greenloop_private.sbn_counts()'::regprocedure;
 if not found then raise exception 'Issuance sidebar verification row is missing.';end if;
end;$patch$;
create table if not exists greenloop_private.dashboard_ready_counts_installation(identity text primary key,hash text not null);
alter table greenloop_private.dashboard_ready_counts_installation enable row level security;
revoke all on greenloop_private.dashboard_ready_counts_installation from public,anon,authenticated;
create or replace function public.get_dashboard_ready_counts_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.dashboard_ready_counts_installation)
 and not has_function_privilege('authenticated','greenloop_private.drc_ready_count()','EXECUTE')and not has_function_privilege('anon','greenloop_private.drc_ready_count()','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.dashboard_ready_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.dashboard_ready_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261110-dashboard-ready-counts-1'end;$$;
revoke all on function public.get_dashboard_ready_counts_version()from public;grant execute on function public.get_dashboard_ready_counts_version()to anon,authenticated;
insert into greenloop_private.dashboard_ready_counts_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.drc_ready_count()'::regprocedure,'greenloop_private.sbn_counts()'::regprocedure,'public.get_dashboard_ready_counts_version()'::regprocedure)or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_overview_workflow_counts()'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_dashboard_ready_counts_version()is distinct from '20261110-dashboard-ready-counts-1'
 or public.get_content_protection_version()is distinct from '20261109-content-protection-1'
 or public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'
 or public.get_issuance_access_version()is distinct from '20261109-issuance-access-1'
 or public.get_imei_badge_verification_version()is distinct from '20261107-imei-badge-verification-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Dashboard Ready Stock verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$drc_install$;
select public.get_dashboard_ready_counts_version()as installed_dashboard_ready_counts_version;
