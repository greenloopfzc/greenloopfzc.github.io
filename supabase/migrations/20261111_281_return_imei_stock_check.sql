-- Additive, read-only preflight for the Return Stock preparation list.
-- The existing atomic save remains the final authority; no business rows change.
begin;
do $prerequisite$ begin
 if public.get_bulk_final_grade_version() is distinct from '20261110-bulk-final-grade-1' then
  raise exception 'Install the previous Bulk Final Grade update first.' using errcode='55000';
 end if;
end; $prerequisite$;

create or replace function greenloop_private.rsic_check(p_batch_id uuid,p_imeis text[])
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $check$
declare b public.receiving_batches%rowtype; d public.devices%rowtype; j public.jobs%rowtype;
 r public.supplier_returns%rowtype; actual public.receiving_batches%rowtype;
 v text; canonical text; seen text[]:='{}'; result jsonb:='[]'; state text; why text; matches integer;
begin
 perform greenloop_private.require_supplier_return_access('request');
 if not public.has_page_capability_v1('supplier_returns','entry') then
  raise exception 'Stock Return entry permission is required.' using errcode='42501';
 end if;
 if p_batch_id is null or p_imeis is null or cardinality(p_imeis) not between 1 and 1000
  or exists(select 1 from unnest(p_imeis)x where x is null or x!~'^[0-9]{15}$') then
  raise exception 'Choose stock and provide 1 to 1000 complete IMEIs.' using errcode='22023';
 end if;
 select * into b from public.receiving_batches where id=p_batch_id;
 if b.id is null or b.planned_quantity is null or not exists(select 1 from public.suppliers where id=b.supplier_id and deleted_at is null) then
  raise exception 'Select an available supplier receipt.' using errcode='22023';
 end if;
 foreach v in array p_imeis loop
  d:=null;j:=null;r:=null;actual:=null;canonical:=v;state:='unrecorded';why:='IMEI not recorded. Receipt ownership cannot be confirmed; checked again on Save.';
  select count(*) into matches from public.devices where imei_1=v or imei_2=v;
  select * into d from public.devices where imei_1=v or imei_2=v order by created_at desc,id limit 1;
  if d.id is not null then
   canonical:=d.imei_1;
   select * into j from public.jobs where device_id=d.id and deleted_at is null order by received_at desc,created_at desc,id desc limit 1;
   select * into actual from public.receiving_batches where id=j.receiving_batch_id;
   state:='matched';why:='Selected stock matched. Final return eligibility is checked on Save.';
   if matches<>1 then state:='blocked';why:='IMEI matches multiple saved phones. Correct the records before returning.';
   elsif d.deleted_at is not null then state:='blocked';why:='This IMEI belongs to a deleted phone.';
   elsif j.id is null then state:='blocked';why:='No active job records this phone stock.';
   elsif j.receiving_batch_id is distinct from b.id or j.supplier_id is distinct from b.supplier_id then
    state:='wrong_stock';why:='Different stock. This IMEI does not belong to the selected supplier receipt.';
   elsif j.ownership_type<>'company_owned' or j.closed_at is not null or j.current_status::text in('shipped','returned_to_customer','rma_completed','scrap','supplier_return_requested','return_pending','returned_to_supplier') then
    state:='blocked';why:='Phone is already returned, on hold, closed or unavailable for a new return.';
   elsif exists(select 1 from public.export_box_items where device_id=d.id) then
    state:='blocked';why:='Remove this phone from its export box before returning it.';
   end if;
  end if;
  select * into r from public.supplier_returns where archived_at is null and status in('requested','approved','returned')
   and ((d.id is not null and device_id=d.id)or imei_1=v or imei_1=canonical) order by requested_at desc,id desc limit 1;
  if r.id is not null then
   if actual.id is null then select * into actual from public.receiving_batches where id=r.batch_id;end if;
   if state<>'wrong_stock' then state:='blocked';why:='This phone already has an active supplier return.';end if;
  end if;
  if canonical=any(seen) then state:='blocked';why:='Same physical phone already appears in this list (IMEI 1 / IMEI 2).';end if;
  seen:=array_append(seen,canonical);
  result:=result||jsonb_build_array(jsonb_build_object('imei',v,'canonical_imei',canonical,'batch_id',actual.id,
   'batch_number',actual.batch_number,'received_quantity',actual.planned_quantity,
   'status',state,'reason',why,'allowed',state in('matched','unrecorded')));
 end loop;
 return jsonb_build_object('batch_id',b.id,'rows',result);
end; $check$;

create or replace function public.check_stock_return_imeis_v1(p_batch_id uuid,p_imeis text[])
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $wrapper$
begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.rsic_check(p_batch_id,p_imeis);
end; $wrapper$;
revoke all on function greenloop_private.rsic_check(uuid,text[])from public,anon,authenticated;
revoke all on function public.check_stock_return_imeis_v1(uuid,text[])from public,anon,authenticated;
grant execute on function public.check_stock_return_imeis_v1(uuid,text[])to authenticated;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
values('public.check_stock_return_imeis_v1(uuid,text[])','greenloop_private.rsic_check(uuid,text[])',
 md5(pg_get_functiondef('greenloop_private.rsic_check(uuid,text[])'::regprocedure)),md5(pg_get_functiondef('public.check_stock_return_imeis_v1(uuid,text[])'::regprocedure)))
on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)
values('check_stock_return_imeis_v1','{"page":"supplier_returns","capability":"entry","read":true}')
on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.return_imei_stock_check_installation(identity text primary key,hash text not null);
alter table greenloop_private.return_imei_stock_check_installation enable row level security;
revoke all on greenloop_private.return_imei_stock_check_installation from public,anon,authenticated;
create or replace function public.get_return_imei_stock_check_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.return_imei_stock_check_installation)
 and not has_function_privilege('anon','public.check_stock_return_imeis_v1(uuid,text[])','execute')
 and has_function_privilege('authenticated','public.check_stock_return_imeis_v1(uuid,text[])','execute')
 and not has_function_privilege('anon','greenloop_private.rsic_check(uuid,text[])','execute')
 and not has_function_privilege('authenticated','greenloop_private.rsic_check(uuid,text[])','execute')
 and not has_table_privilege('authenticated','greenloop_private.return_imei_stock_check_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.return_imei_stock_check_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.return_imei_stock_check_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.office_routines where identity='public.check_stock_return_imeis_v1(uuid,text[])'and implementation='greenloop_private.rsic_check(uuid,text[])'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='check_stock_return_imeis_v1'and rule='{"page":"supplier_returns","capability":"entry","read":true}'::jsonb)
 then '20261111-return-imei-stock-check-1'else null end;
$version$;
revoke all on function public.get_return_imei_stock_check_version()from public;
grant execute on function public.get_return_imei_stock_check_version()to anon,authenticated;
insert into greenloop_private.return_imei_stock_check_installation(identity,hash)
select x,md5(pg_get_functiondef(to_regprocedure(x)))from unnest(array['greenloop_private.rsic_check(uuid,text[])','public.check_stock_return_imeis_v1(uuid,text[])','public.get_return_imei_stock_check_version()'])x
on conflict(identity)do update set hash=excluded.hash;
do $verify$ begin
 if public.get_return_imei_stock_check_version() is distinct from '20261111-return-imei-stock-check-1'
  or public.get_bulk_final_grade_version() is distinct from '20261110-bulk-final-grade-1'
  or public.get_office_access_version() is distinct from '20261024-office-access-1'
  or public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1'then
  raise exception 'Return IMEI stock check integrity failed. Installation rolled back.';
 end if;
 notify pgrst,'reload schema';
end; $verify$;
commit;
select public.get_return_imei_stock_check_version()as installed_return_imei_stock_check_version;
