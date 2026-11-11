-- Read-only replacement pairing in IMEI Search. No business/history records change.
DO $rih_install$ BEGIN EXECUTE $rih_ddl$
do $$begin
 if public.get_replacement_original_stock_version()is distinct from '20261111-replacement-original-stock-1'
 or public.get_imei_activity_journey_version()is distinct from '20261109-imei-activity-1'
 then raise exception 'Verify Original Stock Replacement and IMEI Activity before installing replacement history.';end if;
 if to_regprocedure('public.get_imei_replacement_history_version()')is not null then
  if public.get_imei_replacement_history_version()is distinct from '20261111-imei-replacement-history-1'then raise exception 'Existing replacement history integrity needs review.';end if;
 end if;
end;$$;
create or replace function greenloop_private.rih_read(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d public.devices%rowtype;output jsonb;begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('imei_search','view');
 if p_imei is null or btrim(p_imei)!~'^[0-9]{15}$'then raise exception 'Choose one valid 15-digit IMEI.'using errcode='22023';end if;
 select *into d from public.devices where deleted_at is null and btrim(p_imei)in(imei_1,imei_2);
 if d.id is null then return jsonb_build_object('found',false,'rows','[]'::jsonb);end if;
 with pairs as(
  select p.return_id,p.original_imei old_imei,p.new_imei,p.model,p.storage_gb,p.color,p.created_at matched_at,
   p.receipt_id,l.replacement_job_id,l.replacement_device_id,l.root_batch_id
  from greenloop_private.srma_pairs p
  join public.supplier_returns r on r.id=p.return_id
  left join greenloop_private.srp_phone_links l on l.return_id=p.return_id
  where p.original_imei=d.imei_1 or p.new_imei=d.imei_1 or r.device_id=d.id or l.replacement_device_id=d.id
  union all
  select l.return_id,coalesce(a.original_imei,r.imei_1),nd.imei_1,nd.model,nd.storage_gb,nd.color,l.linked_at,
   a.receipt_id,l.replacement_job_id,l.replacement_device_id,l.root_batch_id
  from greenloop_private.srp_phone_links l
  join greenloop_private.srp_allocations a on a.return_id=l.return_id
  join public.supplier_returns r on r.id=l.return_id
  join public.devices nd on nd.id=l.replacement_device_id and nd.deleted_at is null
  where(r.device_id=d.id or l.replacement_device_id=d.id)
   and not exists(select 1 from greenloop_private.srma_pairs p where p.return_id=l.return_id)
 ),roots as materialized(select *from greenloop_private.sc_receipts())
 select coalesce(jsonb_agg(jsonb_build_object(
  'return_id',p.return_id,'old_imei',p.old_imei,'new_imei',p.new_imei,
  'direction',case when p.new_imei=d.imei_1 then 'replacement_received'else 'returned_replaced'end,
  'matched_at',p.matched_at,'returned_at',coalesce(r.handed_over_at,r.requested_at),'received_at',a.received_at,
  'return_reference',a.original_snapshot->>'return_reference',
  'model',coalesce(nd.model,p.model),'storage_gb',coalesce(nd.storage_gb,p.storage_gb),'color',coalesce(nd.color,p.color),
  'entered',j.id is not null,'batch_number',s.batch_number,'receipt_quantity',s.received_quantity,'invoice_number',s.invoice_number,
  'supplier_code',case when s.supplier_code is not null then regexp_replace(s.supplier_code,'-\([0-9]+\)$','')||case when s.received_quantity is not null then '-('||s.received_quantity::text||')'else ''end end
 )order by p.matched_at,p.return_id),'[]'::jsonb)into output
 from pairs p join greenloop_private.srp_receipts a on a.id=p.receipt_id
 join public.supplier_returns r on r.id=p.return_id
 left join public.devices nd on nd.id=p.replacement_device_id and nd.deleted_at is null
 left join public.jobs j on j.id=p.replacement_job_id and j.deleted_at is null and nd.id is not null
 left join roots s on s.parent_batch_id is null and(a.original_batch_id=s.batch_id or a.original_batch_id=any(s.descendant_ids))
 where p.new_imei is not null;
 return jsonb_build_object('found',true,'imei',d.imei_1,'rows',output);
end;$$;
revoke all on function greenloop_private.rih_read(text)from public,anon,authenticated;
create or replace function public.get_imei_replacement_history_v1(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.rih_read(p_imei);end;$$;
revoke all on function public.get_imei_replacement_history_v1(text)from public,anon,authenticated;grant execute on function public.get_imei_replacement_history_v1(text)to authenticated;
insert into greenloop_private.office_routines select 'public.get_imei_replacement_history_v1(text)','greenloop_private.rih_read(text)',md5(pg_get_functiondef('greenloop_private.rih_read(text)'::regprocedure)),md5(pg_get_functiondef('public.get_imei_replacement_history_v1(text)'::regprocedure))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_imei_replacement_history_v1','{"page":"imei_search","capability":"view","read":true}'),('get_imei_replacement_history_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.rih_installation(identity text primary key,hash text not null);
alter table greenloop_private.rih_installation enable row level security;revoke all on greenloop_private.rih_installation from public,anon,authenticated;
create or replace function public.get_imei_replacement_history_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.rih_installation)
 and has_function_privilege('authenticated','public.get_imei_replacement_history_v1(text)','EXECUTE')and not has_function_privilege('anon','public.get_imei_replacement_history_v1(text)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rih_read(text)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rih_read(text)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.rih_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.rih_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.rih_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_imei_replacement_history_v1'and rule='{"page":"imei_search","capability":"view","read":true}'::jsonb)
 then '20261111-imei-replacement-history-1'end;$$;
revoke all on function public.get_imei_replacement_history_version()from public;grant execute on function public.get_imei_replacement_history_version()to anon,authenticated;
insert into greenloop_private.rih_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rih_read(text)','public.get_imei_replacement_history_v1(text)','public.get_imei_replacement_history_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_imei_replacement_history_version()is distinct from '20261111-imei-replacement-history-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Replacement history verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';
$rih_ddl$;END;$rih_install$;
select public.get_imei_replacement_history_version()as installed_imei_replacement_history_version;
