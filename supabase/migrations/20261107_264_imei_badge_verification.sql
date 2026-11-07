-- Fast local integrity marker; deployment verifies each foundation separately.
-- No stock, phones, returns, histories or account permissions are changed.
begin;
do $verify$
declare p record;
begin
 if public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified IMEI badge foundations are required.';end if;
 if(select count(*)<>2 or not bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_pending_badge_installation)
 then raise exception 'IMEI badge integrity differs. No changes applied.';end if;
 if(select md5(replace(prosrc,E'\r\n',E'\n'))from pg_proc where oid='greenloop_private.sbn_counts()'::regprocedure)is distinct from '8e534ffcb0f44cb69e495275ef82f718'
 then raise exception 'IMEI badge helper differs from the reviewed installation.';end if;
 select *into p from pg_proc where oid='public.get_imei_pending_badge_version()'::regprocedure;
 if md5(replace(p.prosrc,E'\r\n',E'\n'))not in('18cc71fb1fe3b49913a0bd74eb1aacc0','b61d4bce503bd805410151de458fa9bd')or not p.prosecdef or p.provolatile<>'s'
 or p.proconfig is distinct from array['search_path=pg_catalog, public']::text[]
 or p.prolang<>(select oid from pg_language where lanname='sql')
 then raise exception 'IMEI badge marker differs from the reviewed installation.';end if;
 if to_regprocedure('public.get_imei_badge_verification_version()')is not null then
  if public.get_imei_badge_verification_version()is distinct from '20261107-imei-badge-verification-1'then raise exception 'Existing IMEI verification integrity differs.';end if;
 end if;
end;$verify$;
create or replace function public.get_imei_pending_badge_version()returns text language sql stable security definer set search_path=pg_catalog,public as $local$
 select case when true
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_pending_badge_installation)
 and not has_table_privilege('anon','greenloop_private.imei_pending_badge_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.imei_pending_badge_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.imei_pending_badge_installation'::regclass and relrowsecurity)
 then '20261107-imei-pending-badge-1'end;
$local$;
-- Only the reviewed marker's own hash changes; the runtime count helper is untouched.
update greenloop_private.imei_pending_badge_installation set hash=md5(pg_get_functiondef('public.get_imei_pending_badge_version()'::regprocedure))where identity='public.get_imei_pending_badge_version()';
create table if not exists greenloop_private.imei_badge_verification_installation(identity text primary key,hash text not null);
alter table greenloop_private.imei_badge_verification_installation enable row level security;
revoke all on greenloop_private.imei_badge_verification_installation from public,anon,authenticated;
create or replace function public.get_imei_badge_verification_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_imei_pending_badge_version()='20261107-imei-pending-badge-1'
 and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_badge_verification_installation)
 and not has_function_privilege('anon','greenloop_private.sbn_counts()','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.sbn_counts()','EXECUTE')
 and has_function_privilege('authenticated','public.get_sidebar_notification_counts_v1()','EXECUTE')
 and not has_function_privilege('anon','public.get_sidebar_notification_counts_v1()','EXECUTE')
 and exists(select 1 from greenloop_private.office_routines where identity='public.get_sidebar_notification_counts_v1()'and implementation='greenloop_private.sbn_counts()'and original_hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure))and wrapped_hash=md5(pg_get_functiondef('public.get_sidebar_notification_counts_v1()'::regprocedure)))
 and not has_table_privilege('anon','greenloop_private.imei_badge_verification_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.imei_badge_verification_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.imei_badge_verification_installation'::regclass and relrowsecurity)
 then '20261107-imei-badge-verification-1'end;
$$;
revoke all on function public.get_imei_badge_verification_version()from public;
grant execute on function public.get_imei_badge_verification_version()to anon,authenticated;
insert into greenloop_private.imei_badge_verification_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.sbn_counts()','public.get_imei_pending_badge_version()','public.get_imei_badge_verification_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_imei_badge_verification_version()is distinct from '20261107-imei-badge-verification-1'then raise exception 'IMEI badge verification repair failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_imei_pending_badge_version()as installed_imei_pending_badge_version,public.get_imei_badge_verification_version()as installed_imei_badge_verification_version;
