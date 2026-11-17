-- Identity-only read for scanner normalization; no stock/workflow writes.
do $scan_install$
begin
 if to_regprocedure('public.get_primary_imei_scans_version()')is not null then if public.get_primary_imei_scans_version()is distinct from '20261117-primary-imei-scans-1'then raise exception 'Existing primary IMEI scan update integrity differs.';end if;end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'The existing permission rules are not verified. Nothing installed.';end if;
 execute $definition$create or replace function public.get_scan_imei_identities_v1(p_imeis text[],p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare ambiguous text;result jsonb;
 begin
  perform greenloop_private.pf_cap(p_page,'view');
  if p_imeis is null or cardinality(p_imeis)not between 1 and 100 or exists(select 1 from unnest(p_imeis)v where v is null or v!~'^[0-9]{15}$')then raise exception 'Send between 1 and 100 exact IMEIs.'using errcode='22023';end if;
  select v into ambiguous from(select distinct unnest(p_imeis)v)x join public.devices d on d.deleted_at is null and(d.imei_1=x.v or d.imei_2=x.v)group by v having count(distinct d.id)>1 limit 1;
  if ambiguous is not null then raise exception 'This IMEI matches more than one phone. Review its saved identity before continuing.'using errcode='22023';end if;
  select coalesce(jsonb_agg(jsonb_build_object('scanned_imei',x.v,'imei',coalesce(d.imei_1,x.v),'found',d.id is not null,'device_id',d.id)order by x.n),'[]')into result
   from(select v,min(n)n from unnest(p_imeis)with ordinality a(v,n)group by v)x left join public.devices d on d.deleted_at is null and(d.imei_1=x.v or d.imei_2=x.v);
  return result;
 end;$body$;$definition$;
 revoke all on function public.get_scan_imei_identities_v1(text[],text)from public,anon,authenticated;
 grant execute on function public.get_scan_imei_identities_v1(text[],text)to authenticated;
 insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_scan_imei_identities_v1','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
 create table if not exists greenloop_private.primary_imei_scans_installation(identity text primary key,hash text not null);
 alter table greenloop_private.primary_imei_scans_installation enable row level security;
 revoke all on greenloop_private.primary_imei_scans_installation from public,anon,authenticated;
 execute $definition$create or replace function public.get_primary_imei_scans_version()returns text language sql stable security definer set search_path=pg_catalog,public as $body$
 select case when(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.primary_imei_scans_installation)
 and not has_function_privilege('anon','public.get_scan_imei_identities_v1(text[],text)','EXECUTE')and has_function_privilege('authenticated','public.get_scan_imei_identities_v1(text[],text)','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.primary_imei_scans_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.primary_imei_scans_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.primary_imei_scans_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_scan_imei_identities_v1'and rule='{"read":true}'::jsonb)
 and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))
 then '20261117-primary-imei-scans-1'end;$body$;$definition$;
 revoke all on function public.get_primary_imei_scans_version()from public;grant execute on function public.get_primary_imei_scans_version()to anon,authenticated;
 insert into greenloop_private.primary_imei_scans_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['public.get_scan_imei_identities_v1(text[],text)','public.get_primary_imei_scans_version()'])s on conflict(identity)do update set hash=excluded.hash;
 if public.get_primary_imei_scans_version()is distinct from '20261117-primary-imei-scans-1'then raise exception 'Primary IMEI scan verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$scan_install$;
select public.get_primary_imei_scans_version()as installed_primary_imei_scans_version;
