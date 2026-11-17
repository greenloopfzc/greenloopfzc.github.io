-- Avoid constructing complete phone/plan lists for shared sidebar counters.
begin;
do $$begin
 if public.get_parts_usage_report_version()is distinct from '20261116-parts-usage-report-1'or not exists(select 1 from greenloop_private.sidebar_counts_installation where kind='function'and identity='greenloop_private.sbn_counts()'and hash=md5(pg_get_functiondef('greenloop_private.sbn_counts()'::regprocedure)))then raise exception 'Install the verified sidebar and original-stock prerequisites first.';end if;
 if to_regprocedure('public.get_shared_loading_performance_version()')is not null then if public.get_shared_loading_performance_version()is distinct from '20261117-shared-loading-performance-1'then raise exception 'Existing shared loading update integrity differs.';end if;end if;
end;$$;
create temporary table rb318_before(identity text,hash text)on commit drop;
do $patch$declare sig text;old text;updated text;begin
 select implementation into sig from greenloop_private.office_routines where to_regprocedure(identity)='public.get_open_stock_entry_batches_with_lines()'::regprocedure;
 if sig is null or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(implementation)=to_regprocedure(sig)and original_hash=md5(pg_get_functiondef(to_regprocedure(sig)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Stock entry read boundary could not be verified.';end if;
 old:=pg_get_functiondef(sig::regprocedure);insert into rb318_before values(sig,md5(old));
 if position('data offset 0'in old)=0 then
  updated:=regexp_replace(old,'greenloop_private\.supplier_return_batch\(b\.id\)\s+data\s*\)\s*x','greenloop_private.supplier_return_batch(b.id) data offset 0) x','g');
  if old=updated or position('data offset 0'in updated)=0 then raise exception 'Stock entry calculation changed. Nothing installed.';end if;execute updated;
 end if;
 sig:='greenloop_private.sbn_counts()';old:=pg_get_functiondef(sig::regprocedure);insert into rb318_before values(sig,md5(old));
 if position('greenloop-lean-sidebar-318'in old)=0 then
  updated:=replace(old,$old$select coalesce(sum(remaining_quantity),0)into n from public.get_open_stock_entry_batches_with_lines();$old$,$new$-- greenloop-lean-sidebar-318
  if not public.is_active_staff()or not(public.has_page_access('imei_entry')or public.has_page_access('stock_received'))then raise exception 'Stock Received or IMEI Entry view permission is required.'using errcode='42501';end if;
  select coalesce(sum(remaining),0)into n from(
   select (greenloop_private.supplier_return_batch(b.id)->>'remaining_quantity')::integer remaining
   from public.receiving_batches b join public.stock_channels c on c.id=b.stock_channel_id join public.suppliers s on s.id=b.supplier_id
   where b.planned_quantity is not null and c.is_active and s.is_active and s.deleted_at is null offset 0
  )x where remaining>0;$new$);
  updated:=regexp_replace(updated,'select count\(\*\)into n from greenloop_private\.qcis_rows\(null\);',$new$select count(*)into n from greenloop_private.qc_saved_issuance s join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id
   join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance';$new$,'g');
  if updated=old or position('greenloop-lean-sidebar-318'in updated)=0 or position('greenloop_private.qcis_rows(null)'in updated)>0 or position('sum(remaining_quantity)'in updated)>0 then raise exception 'Sidebar counting boundary differs. Nothing installed.';end if;execute updated;
 end if;
end;$patch$;
do $$declare b record;t record;c record;begin
 for b in select *from rb318_before loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
 end loop;end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 end loop;
end;$$;
create table if not exists greenloop_private.shared_loading_installation(identity text primary key,hash text not null);alter table greenloop_private.shared_loading_installation enable row level security;revoke all on greenloop_private.shared_loading_installation from public,anon,authenticated;
create or replace function public.get_shared_loading_performance_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_usage_report_version()='20261116-parts-usage-report-1'and not has_function_privilege('authenticated','greenloop_private.sbn_counts()','EXECUTE')and not has_function_privilege('anon','greenloop_private.sbn_counts()','EXECUTE')
 and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.shared_loading_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.shared_loading_installation'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.shared_loading_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.shared_loading_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261117-shared-loading-performance-1'end;$$;
revoke all on function public.get_shared_loading_performance_version()from public;grant execute on function public.get_shared_loading_performance_version()to anon,authenticated;
insert into greenloop_private.shared_loading_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from rb318_before on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.shared_loading_installation values('public.get_shared_loading_performance_version()',md5(pg_get_functiondef('public.get_shared_loading_performance_version()'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_shared_loading_performance_version()is distinct from '20261117-shared-loading-performance-1'then raise exception 'Shared loading verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_shared_loading_performance_version()as installed_shared_loading_performance_version;
