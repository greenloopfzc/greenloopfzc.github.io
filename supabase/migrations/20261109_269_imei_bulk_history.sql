-- Read-only paginated IMEI list with the same canonical journey stage.
begin;
do $$begin
 if to_regprocedure('public.get_imei_bulk_history_version()')is not null then if public.get_imei_bulk_history_version()is distinct from '20261109-imei-bulk-history-1'then raise exception 'Existing IMEI bulk history integrity differs.';end if;end if;
 if public.get_installation_component_engine_version()is distinct from '20261107-installation-components-1'or public.get_imei_activity_journey_version()is distinct from '20261109-imei-activity-1'then raise exception 'Verified IMEI Activity support is required.';end if;
end;$$;
create or replace function greenloop_private.ibh_list(p_imeis text[],p_offset integer,p_limit integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare output jsonb;names boolean;start_at integer:=greatest(0,coalesce(p_offset,0));take integer:=least(50,greatest(1,coalesce(p_limit,50)));
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('imei_search','search');perform greenloop_private.require_record_search_access();
 if coalesce(cardinality(p_imeis),0)=0 or exists(select 1 from unnest(p_imeis)x where x is null or x!~'^[0-9]{15}$')then raise exception 'Paste valid 15-digit IMEIs.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with requested as materialized(select x imei,min(ord)ord from unnest(p_imeis)with ordinality u(x,ord)group by x),
 page as(select *from requested order by ord offset start_at limit take),
 phones as(
 select p.ord,jsonb_build_object('searched_imei',p.imei,'found',d.id is not null,'kind','device','id',d.id,'identifier',d.imei_1,'imei_1',d.imei_1,'imei_2',d.imei_2,'device_number',d.device_number,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,
 'current_status',coalesce(j.current_status::text,d.current_status::text),'current_stage',case when d.id is not null then greenloop_private.jst_stage(coalesce(j.current_status::text,d.current_status::text),j.id,d.id)end,
 'batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'planned_quantity',b.planned_quantity,
 'supplier_code',case when s.supplier_code is not null then regexp_replace(s.supplier_code,'-\([0-9]+\)$','')||case when b.planned_quantity is not null then '-('||b.planned_quantity::text||')'else ''end end,
 'supplier_name',case when names then s.company_name end)row
 from page p
 left join lateral(select x.*from public.devices x where x.deleted_at is null and(p.imei=x.imei_1 or p.imei=x.imei_2)order by(x.imei_1=p.imei)desc,x.id limit 1)d on true
 left join lateral(select x.*from public.jobs x where x.device_id=d.id and x.deleted_at is null order by x.received_at desc nulls last,x.created_at desc,x.id limit 1)j on true
 left join public.receiving_batches b on b.id=j.receiving_batch_id
 left join public.suppliers s on s.id=coalesce(j.supplier_id,b.supplier_id))
 select jsonb_build_object('rows',coalesce((select jsonb_agg(row order by ord)from phones),'[]'::jsonb),'total',(select count(*)from requested),'offset',start_at)into output;
 return output;
end;$$;
revoke all on function greenloop_private.ibh_list(text[],integer,integer)from public,anon,authenticated;
create or replace function public.get_imei_bulk_history_list_v1(p_imeis text[],p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.ibh_list(p_imeis,p_offset,p_limit);end;$$;
revoke all on function public.get_imei_bulk_history_list_v1(text[],integer,integer)from public,anon,authenticated;
grant execute on function public.get_imei_bulk_history_list_v1(text[],integer,integer)to authenticated;
insert into greenloop_private.office_routines values('public.get_imei_bulk_history_list_v1(text[],integer,integer)','greenloop_private.ibh_list(text[],integer,integer)',md5(pg_get_functiondef('greenloop_private.ibh_list(text[],integer,integer)'::regprocedure)),md5(pg_get_functiondef('public.get_imei_bulk_history_list_v1(text[],integer,integer)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_imei_bulk_history_list_v1','{"page":"imei_search","capability":"search","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.imei_bulk_history_installation(identity text primary key,hash text not null);
alter table greenloop_private.imei_bulk_history_installation enable row level security;
revoke all on greenloop_private.imei_bulk_history_installation from public,anon,authenticated;
create or replace function public.get_imei_bulk_history_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_bulk_history_installation)
 and has_function_privilege('authenticated','public.get_imei_bulk_history_list_v1(text[],integer,integer)','EXECUTE')and not has_function_privilege('anon','public.get_imei_bulk_history_list_v1(text[],integer,integer)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.ibh_list(text[],integer,integer)','EXECUTE')and not has_function_privilege('anon','greenloop_private.ibh_list(text[],integer,integer)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.imei_bulk_history_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.imei_bulk_history_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.imei_bulk_history_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_imei_bulk_history_list_v1'and rule='{"page":"imei_search","capability":"search","read":true}'::jsonb)
 then '20261109-imei-bulk-history-1'end;
$$;
revoke all on function public.get_imei_bulk_history_version()from public;grant execute on function public.get_imei_bulk_history_version()to anon,authenticated;
insert into greenloop_private.imei_bulk_history_installation select x,md5(pg_get_functiondef(x::regprocedure))from unnest(array['greenloop_private.ibh_list(text[],integer,integer)','public.get_imei_bulk_history_list_v1(text[],integer,integer)','public.get_imei_bulk_history_version()'])x on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_imei_bulk_history_version()is distinct from '20261109-imei-bulk-history-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'IMEI bulk history installation failed verification. No changes installed.';end if;
end;$$;
notify pgrst,'reload schema';commit;
select public.get_imei_bulk_history_version()as installed_imei_bulk_history_version;
