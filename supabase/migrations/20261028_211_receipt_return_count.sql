-- Completed supplier-return unit count on the existing authorized receipt search.
begin;
do $$begin
 if public.get_ready_stock_imeis_version()is distinct from '20261028-ready-stock-imeis-1'then raise exception 'Verified Ready Stock IMEIs update is required.';end if;
 if to_regprocedure('public.get_receipt_return_count_version()')is not null then
  if public.get_receipt_return_count_version()is distinct from '20261028-receipt-return-count-1'then raise exception 'Existing Receipt Return Count update needs review.';end if;
 end if;
end;$$;
create or replace function public.get_search_receipt_returns_v1(p_receipt_id uuid,p_offset integer default 0,p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;returned bigint;
begin
 perform greenloop_private.pf_cap('imei_search','view');
 -- Preserve the existing receipt access, partner-name masking and phone pagination.
 result:=public.get_search_receipt_v1(p_receipt_id,p_offset,p_limit);
 if coalesce((result->>'found')::boolean,false)then
  -- One row is one physical phone, including quantity-only/unentered returns.
  -- Match the active Stock Return report: pending, archived and deleted units are excluded.
  select count(*)into returned from public.supplier_returns r
   left join public.devices d on d.id=r.device_id
   left join public.jobs j on j.id=r.job_id
   where r.batch_id=p_receipt_id and r.status='returned'and r.archived_at is null
    and(r.device_id is null or(d.id is not null and d.deleted_at is null))
    and(r.job_id is null or(j.id is not null and j.deleted_at is null));
  result:=jsonb_set(result,'{receipt,returned_quantity}',to_jsonb(returned));
 end if;
 return result;
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_search_receipt_returns_v1','{"page":"imei_search","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_search_receipt_returns_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.receipt_return_count_installation(identity text primary key,hash text not null);
alter table greenloop_private.receipt_return_count_installation enable row level security;
revoke all on greenloop_private.receipt_return_count_installation from public,anon,authenticated;
insert into greenloop_private.receipt_return_count_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_search_receipt_returns_v1'on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_receipt_return_count_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_ready_stock_imeis_version()='20261028-ready-stock-imeis-1'
 and(select count(*)=1 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.receipt_return_count_installation)
 and not has_table_privilege('authenticated','greenloop_private.receipt_return_count_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.receipt_return_count_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261028-receipt-return-count-1'end;
$$;
revoke all on function public.get_receipt_return_count_version()from public;
grant execute on function public.get_receipt_return_count_version()to anon,authenticated;
do $$begin if public.get_receipt_return_count_version()is distinct from '20261028-receipt-return-count-1'then raise exception 'Receipt Return Count verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_receipt_return_count_version()as installed_receipt_return_count_version;
