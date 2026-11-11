-- Add the canonical current stage to Return Stock's existing read-only check.
begin;
do $prerequisite$ begin
 if public.get_return_imei_stock_check_version()is distinct from '20261111-return-imei-stock-check-1'then
  raise exception 'Install the previous Return Stock IMEI Check update first.'using errcode='55000';
 end if;
end; $prerequisite$;
create or replace function greenloop_private.rsic_stage(p_batch_id uuid,p_imeis text[])
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $stage$
declare data jsonb;x jsonb;result jsonb:='[]';d public.devices%rowtype;j public.jobs%rowtype;r public.supplier_returns%rowtype;stage text;
begin
 -- Reuse the exact existing receipt, alias, bound and entry checks.
 data:=greenloop_private.rsic_check(p_batch_id,p_imeis);
 for x in select value from jsonb_array_elements(data->'rows')loop
  d:=null;j:=null;r:=null;stage:='Not recorded';
  select *into d from public.devices where imei_1=x->>'canonical_imei'order by created_at desc,id limit 1;
  if d.id is not null then
   select *into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1;
   stage:=coalesce(greenloop_private.jst_stage(coalesce(j.current_status::text,d.current_status::text),j.id,d.id),'Not recorded');
   if d.deleted_at is not null then stage:='Deleted record';end if;
  end if;
  select *into r from public.supplier_returns where archived_at is null and status in('requested','approved','returned')
   and((d.id is not null and device_id=d.id)or imei_1=x->>'imei'or imei_1=x->>'canonical_imei')order by requested_at desc,id desc limit 1;
  if r.id is not null then stage:=case r.status when 'returned'then 'Returned to Supplier'when 'approved'then 'Return Pending'else 'Supplier Return Requested'end;end if;
  if x->>'reason'='IMEI matches multiple saved phones. Correct the records before returning.'then stage:='Ambiguous record';end if;
  result:=result||jsonb_build_array(x||jsonb_build_object('current_stage',stage));
 end loop;
 return data||jsonb_build_object('rows',result);
end;$stage$;
create or replace function public.check_stock_return_imeis_v2(p_batch_id uuid,p_imeis text[])
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $wrapper$
begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.rsic_stage(p_batch_id,p_imeis);
end; $wrapper$;
revoke all on function greenloop_private.rsic_stage(uuid,text[])from public,anon,authenticated;
revoke all on function public.check_stock_return_imeis_v2(uuid,text[])from public,anon,authenticated;
grant execute on function public.check_stock_return_imeis_v2(uuid,text[])to authenticated;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
values('public.check_stock_return_imeis_v2(uuid,text[])','greenloop_private.rsic_stage(uuid,text[])',
 md5(pg_get_functiondef('greenloop_private.rsic_stage(uuid,text[])'::regprocedure)),md5(pg_get_functiondef('public.check_stock_return_imeis_v2(uuid,text[])'::regprocedure)))
on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)
values('check_stock_return_imeis_v2','{"page":"supplier_returns","capability":"entry","read":true}')
on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.return_imei_stage_installation(identity text primary key,hash text not null);
alter table greenloop_private.return_imei_stage_installation enable row level security;
revoke all on greenloop_private.return_imei_stage_installation from public,anon,authenticated;
create or replace function public.get_return_imei_stage_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.return_imei_stage_installation)
 and not has_function_privilege('anon','public.check_stock_return_imeis_v2(uuid,text[])','execute')
 and has_function_privilege('authenticated','public.check_stock_return_imeis_v2(uuid,text[])','execute')
 and not has_function_privilege('anon','greenloop_private.rsic_stage(uuid,text[])','execute')
 and not has_function_privilege('authenticated','greenloop_private.rsic_stage(uuid,text[])','execute')
 and not has_table_privilege('authenticated','greenloop_private.return_imei_stage_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.return_imei_stage_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.return_imei_stage_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.office_routines where identity='public.check_stock_return_imeis_v2(uuid,text[])'and implementation='greenloop_private.rsic_stage(uuid,text[])'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='check_stock_return_imeis_v2'and rule='{"page":"supplier_returns","capability":"entry","read":true}'::jsonb)
 then '20261111-return-imei-stage-1'else null end;
$version$;
revoke all on function public.get_return_imei_stage_version()from public;
grant execute on function public.get_return_imei_stage_version()to anon,authenticated;
insert into greenloop_private.return_imei_stage_installation(identity,hash)
select x,md5(pg_get_functiondef(to_regprocedure(x)))from unnest(array['greenloop_private.rsic_stage(uuid,text[])','public.check_stock_return_imeis_v2(uuid,text[])','public.get_return_imei_stage_version()'])x
on conflict(identity)do update set hash=excluded.hash;
do $verify$ begin
 if public.get_return_imei_stage_version() is distinct from '20261111-return-imei-stage-1'
  or public.get_return_imei_stock_check_version() is distinct from '20261111-return-imei-stock-check-1'
  or public.get_office_access_version() is distinct from '20261024-office-access-1'
  or public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1'then
  raise exception 'Return IMEI stock check integrity failed. Installation rolled back.';
 end if;
 notify pgrst,'reload schema';
end; $verify$;
commit;
select public.get_return_imei_stage_version()as installed_return_imei_stage_version;
