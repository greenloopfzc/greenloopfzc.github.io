-- Align the IMEI badge with the actual IMEI Entry pending receipt list.
-- No stock quantities, phone records, returns, permissions or histories change.
begin;
do $patch$
declare p record;definition text;reviewed text;
begin
 if public.get_sidebar_counts_version()is distinct from '20261107-sidebar-counts-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Sidebar Counts and its stock/access foundations are required.';end if;
 if to_regprocedure('public.get_imei_pending_badge_version()')is not null then
  if public.get_imei_pending_badge_version()is distinct from '20261107-imei-pending-badge-1'then raise exception 'Existing IMEI badge installation differs. No changes applied.';end if;
 end if;
 select *into p from pg_proc where oid='greenloop_private.sbn_counts()'::regprocedure;
 reviewed:=replace(p.prosrc,E'\r\n',E'\n');
 if md5(reviewed)not in('1987f835cd5ba8ecf9630f3d64c25763','8e534ffcb0f44cb69e495275ef82f718')or p.provolatile<>'s'or not p.prosecdef
 or p.proconfig is distinct from array['search_path=pg_catalog, public']::text[]
 or p.prolang<>(select oid from pg_language where lanname='plpgsql')
 then raise exception 'Sidebar count routine differs from the reviewed installation. No changes applied.';end if;
 if md5(reviewed)='1987f835cd5ba8ecf9630f3d64c25763'then
  definition:=replace(pg_get_functiondef(p.oid),E'\r\n',E'\n');
  definition:=replace(definition,$old$  select coalesce(sum(greatest(0,b.planned_quantity-coalesce(x.n,0))),0)into n from public.receiving_batches b
  left join lateral(select count(distinct d.id)n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.receiving_batch_id=b.id and j.deleted_at is null)x on true;$old$,$new$  -- Use the same eligible receipts and return-adjusted balance as the IMEI Entry selector.
  select coalesce(sum(remaining_quantity),0)into n from public.get_open_stock_entry_batches_with_lines();$new$);
  execute definition;
 end if;
 if(select md5(replace(prosrc,E'\r\n',E'\n'))from pg_proc where oid=p.oid)is distinct from '8e534ffcb0f44cb69e495275ef82f718'then raise exception 'IMEI badge count replacement failed. Installation rolled back.';end if;
 -- Update only the reviewed helper's two existing definition references.
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(p.oid))
 where identity='public.get_sidebar_notification_counts_v1()'and implementation='greenloop_private.sbn_counts()';
 if not found then raise exception 'Sidebar office registration is missing.';end if;
 update greenloop_private.sidebar_counts_installation set hash=md5(pg_get_functiondef(p.oid))
 where kind='function'and identity='greenloop_private.sbn_counts()';
 if not found then raise exception 'Sidebar definition reference is missing.';end if;
end;$patch$;
create table if not exists greenloop_private.imei_pending_badge_installation(identity text primary key,hash text not null);
alter table greenloop_private.imei_pending_badge_installation enable row level security;
revoke all on greenloop_private.imei_pending_badge_installation from public,anon,authenticated;
create or replace function public.get_imei_pending_badge_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_sidebar_counts_version()='20261107-sidebar-counts-1'
 and public.get_complete_stock_lists_version()='20261105-complete-stock-lists-1'
 and public.get_page_capabilities_version()='20261016-page-capabilities-1'
 and public.get_office_access_version()='20261024-office-access-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_pending_badge_installation)
 and not has_table_privilege('anon','greenloop_private.imei_pending_badge_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.imei_pending_badge_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.imei_pending_badge_installation'::regclass and relrowsecurity)
 then '20261107-imei-pending-badge-1'end;
$$;
revoke all on function public.get_imei_pending_badge_version()from public;
grant execute on function public.get_imei_pending_badge_version()to anon,authenticated;
insert into greenloop_private.imei_pending_badge_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.sbn_counts()','public.get_imei_pending_badge_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_imei_pending_badge_version()is distinct from '20261107-imei-pending-badge-1'then raise exception 'IMEI badge verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
commit;
select public.get_imei_pending_badge_version()as installed_imei_pending_badge_version;
