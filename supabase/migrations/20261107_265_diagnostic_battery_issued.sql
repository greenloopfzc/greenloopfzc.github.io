-- Diagnostic Battery issue is sufficient for Final BH 100; Initial BH is preserved.
-- No historical backfill or stock/part/permission changes.
begin;
do $$declare p record;begin
 if public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified QC automatic rules and access boundaries are required.';end if;
 select *into p from pg_proc where oid='greenloop_private.qca_battery_changed(uuid)'::regprocedure;
 if md5(replace(p.prosrc,E'\r\n',E'\n'))not in('aaa6587b9a5f811e7b25ace5d08b5d4e','0764140c4919c41645e5abee5997e80d')or not p.prosecdef or p.provolatile<>'s'
 or p.proconfig is distinct from array['search_path=pg_catalog, public']::text[]or p.prolang<>(select oid from pg_language where lanname='sql')
 then raise exception 'Diagnostic Battery helper differs from the reviewed installation.';end if;
 if to_regprocedure('public.get_diagnostic_battery_issued_version()')is not null then
  if public.get_diagnostic_battery_issued_version()is distinct from '20261107-diagnostic-battery-issued-1'then raise exception 'Existing Diagnostic Battery issue integrity differs.';end if;
 end if;
end;$$;
create or replace function greenloop_private.qca_battery_changed(p_step uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $issued$
 select exists(
  select 1 from public.job_work_order_steps f
  join public.job_work_orders w on w.id=f.work_order_id
  join public.jobs j on j.id=w.job_id and j.deleted_at is null
  join public.devices d on d.id=j.device_id and d.deleted_at is null
  join public.job_part_requests r on r.job_id=j.id and r.device_id=d.id and r.status<>'cancelled'
  join public.part_issue_transactions i on i.part_request_id=r.id
  where f.id=p_step and f.department='final_qc'and greenloop_private.pp_key(r.part_name)='diagnostic battery'
   and i.quantity_issued-i.quantity_returned-coalesce((select sum(ret.quantity)from greenloop_private.parts_flow_returns ret where ret.issue_id=i.id and ret.status='pending'),0)>0
 );
$issued$;
revoke all on function greenloop_private.qca_battery_changed(uuid)from public,anon,authenticated;
-- Update only this reviewed helper in its existing QC installation reference.
update greenloop_private.qc_auto_rules_installation set hash=md5(pg_get_functiondef('greenloop_private.qca_battery_changed(uuid)'::regprocedure))where identity='greenloop_private.qca_battery_changed(uuid)';
create table if not exists greenloop_private.diagnostic_battery_issued_installation(identity text primary key,hash text not null);
alter table greenloop_private.diagnostic_battery_issued_installation enable row level security;
revoke all on greenloop_private.diagnostic_battery_issued_installation from public,anon,authenticated;
create or replace function public.get_diagnostic_battery_issued_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.diagnostic_battery_issued_installation)
 and exists(select 1 from greenloop_private.qc_auto_rules_installation where identity='greenloop_private.qca_battery_changed(uuid)'and hash=md5(pg_get_functiondef('greenloop_private.qca_battery_changed(uuid)'::regprocedure)))
 and not has_function_privilege('anon','greenloop_private.qca_battery_changed(uuid)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.qca_battery_changed(uuid)','EXECUTE')
 and not has_table_privilege('anon','greenloop_private.diagnostic_battery_issued_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.diagnostic_battery_issued_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.diagnostic_battery_issued_installation'::regclass and relrowsecurity)
 then '20261107-diagnostic-battery-issued-1'end;
$$;
revoke all on function public.get_diagnostic_battery_issued_version()from public;
grant execute on function public.get_diagnostic_battery_issued_version()to anon,authenticated;
insert into greenloop_private.diagnostic_battery_issued_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.qca_battery_changed(uuid)','public.get_diagnostic_battery_issued_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_diagnostic_battery_issued_version()is distinct from '20261107-diagnostic-battery-issued-1'or public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'
 then raise exception 'Diagnostic Battery issued rule failed verification. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';commit;
select public.get_diagnostic_battery_issued_version()as installed_diagnostic_battery_issued_version;
