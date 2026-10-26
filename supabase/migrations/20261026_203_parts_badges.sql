-- Unique IMEI badges for pending Parts issue and return review.
begin;
do $$begin if public.get_parts_simple_version()is distinct from '20261026-parts-simple-1'then raise exception 'Verified Simple Parts workflow is required.';end if;if to_regprocedure('public.get_parts_badges_version()')is not null then if public.get_parts_badges_version()is distinct from '20261026-parts-badges-1'then raise exception 'Existing Parts badges need review.';end if;end if;end;$$;
create or replace function public.get_parts_pending_imei_counts_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare ordered bigint;returned bigint;begin
 perform greenloop_private.pf_cap('parts','view');
 select count(distinct d.id)::bigint into ordered from greenloop_private.parts_flow_orders o join greenloop_private.parts_flow_requests m on m.order_id=o.id join public.job_part_requests r on r.id=m.request_id join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null where o.completed_at is null and o.cycle=greenloop_private.pf_cycle(o.job_id)and j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and r.status<>'cancelled'and r.quantity_requested>r.quantity_issued;
 select count(distinct imei)::bigint into returned from greenloop_private.pp_returns()where status='pending';
 return jsonb_build_object('ordered',ordered,'returned',returned);
end;$$;
-- Signal only the shared public token. No private return rows are published.
drop trigger if exists parts_badge_signal on greenloop_private.parts_flow_returns;
create constraint trigger parts_badge_signal after insert or update or delete on greenloop_private.parts_flow_returns deferrable initially deferred for each row execute function greenloop_private.signal_workflow_change();

insert into greenloop_private.capability_rpc_rules values('get_parts_pending_imei_counts_v1','{"page":"parts","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_parts_pending_imei_counts_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;for f in select p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and false loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);end loop;
end;$wrap$;
create table if not exists greenloop_private.parts_badges_installation(identity text primary key,hash text not null);
alter table greenloop_private.parts_badges_installation enable row level security;revoke all on greenloop_private.parts_badges_installation from public,anon,authenticated;
insert into greenloop_private.parts_badges_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where(p.pronamespace='public'::regnamespace and p.proname='get_parts_pending_imei_counts_v1')or p.oid in(select to_regprocedure(r.implementation)from greenloop_private.office_routines r join pg_proc f on f.oid=to_regprocedure(r.identity)where f.proname='get_parts_pending_imei_counts_v1')on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_parts_badges_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_simple_version()='20261026-parts-simple-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_badges_installation)
 and not has_table_privilege('authenticated','greenloop_private.parts_badges_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.parts_badges_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.parts_badges_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 and(select count(*)=1 from pg_trigger where tgrelid='greenloop_private.parts_flow_returns'::regclass and tgname='parts_badge_signal'and tgfoid='greenloop_private.signal_workflow_change()'::regprocedure and tgenabled='O'and tgdeferrable and tginitdeferred)
 then '20261026-parts-badges-1'end;$$;
revoke all on function public.get_parts_badges_version()from public;grant execute on function public.get_parts_badges_version()to anon,authenticated;
do $$begin if public.get_parts_badges_version()is distinct from '20261026-parts-badges-1'then raise exception 'Parts badges verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_parts_badges_version()as installed_parts_badges_version;
