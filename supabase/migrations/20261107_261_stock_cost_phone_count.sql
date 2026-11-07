-- Count distinct phones contributing priced net parts, per currency.
-- No business data, quantities, prices, selected permissions or report scopes change.
begin;
do $$declare p record;begin
 if public.get_stock_parts_cost_version()is distinct from '20261030-stock-parts-cost-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 then raise exception 'Install verified Stock Parts Cost and Complete Stock Lists first.';end if;
 select *into p from pg_proc where oid='greenloop_private.scp_totals(jsonb)'::regprocedure;
 if md5(replace(p.prosrc,E'\r\n',E'\n'))not in('809c6463025a63bf792801bf9303bfd4','6058055dd45139999247baf8880c4f71')
 or p.provolatile<>'i'or p.prosecdef or p.proconfig is distinct from array['search_path=pg_catalog']::text[]
 or p.prolang<>(select oid from pg_language where lanname='sql')
 then raise exception 'Stock cost totals differ from the reviewed installation. No changes applied.';end if;
end;$$;
create or replace function greenloop_private.scp_totals(lines jsonb)returns jsonb language sql immutable set search_path=pg_catalog as $$
 select coalesce(jsonb_agg(to_jsonb(t)order by currency),'[]')from(
 select count(distinct u->>'device_id')filter(where u->>'unit_price'is not null and(u->>'net_quantity')::numeric>0)costed_phones,
 u->>'currency'currency,sum((u->>'quantity')::numeric)quantity,sum((u->>'returned_quantity')::numeric)returned_quantity,
 sum((u->>'restocked_quantity')::numeric)restocked_quantity,
 sum((u->>'unclassified_return_quantity')::numeric)unclassified_return_quantity,
 sum(case when u->>'unit_price'is null then(u->>'net_quantity')::numeric else 0 end)pending_quantity,
 coalesce(sum((u->>'unit_price')::numeric*(u->>'quantity')::numeric),0)issued_value,
 coalesce(sum((u->>'unit_price')::numeric*(u->>'restocked_quantity')::numeric),0)restocked_value,
 coalesce(sum((u->>'unit_price')::numeric*(u->>'net_quantity')::numeric),0)recorded_cost,
 coalesce(sum((u->>'unit_price')::numeric*(u->>'damaged_quantity')::numeric),0)damaged_value,
 coalesce(sum((u->>'unit_price')::numeric*(u->>'faulty_quantity')::numeric),0)faulty_value
 from jsonb_array_elements(coalesce(lines,'[]'))u group by u->>'currency')t;
$$;
revoke all on function greenloop_private.scp_totals(jsonb)from public,anon,authenticated;
-- Only the reviewed totals helper changes; no blanket installation resealing.
update greenloop_private.stock_parts_cost_installation set hash=md5(pg_get_functiondef('greenloop_private.scp_totals(jsonb)'::regprocedure))where identity='greenloop_private.scp_totals(jsonb)';
create table if not exists greenloop_private.stock_cost_phone_count_installation(identity text primary key,hash text not null);
alter table greenloop_private.stock_cost_phone_count_installation enable row level security;
revoke all on greenloop_private.stock_cost_phone_count_installation from public,anon,authenticated;
create or replace function public.get_stock_cost_phone_count_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_stock_parts_cost_version()='20261030-stock-parts-cost-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.stock_cost_phone_count_installation)
 and not has_function_privilege('anon','greenloop_private.scp_totals(jsonb)','execute')
 and not has_function_privilege('authenticated','greenloop_private.scp_totals(jsonb)','execute')
 and not has_table_privilege('anon','greenloop_private.stock_cost_phone_count_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.stock_cost_phone_count_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.stock_cost_phone_count_installation'::regclass and relrowsecurity)
 then '20261107-stock-cost-phone-count-1'end;
$$;
revoke all on function public.get_stock_cost_phone_count_version()from public;
grant execute on function public.get_stock_cost_phone_count_version()to anon,authenticated;
insert into greenloop_private.stock_cost_phone_count_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.scp_totals(jsonb)','public.get_stock_cost_phone_count_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_stock_cost_phone_count_version()is distinct from '20261107-stock-cost-phone-count-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Stock cost phone count verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
commit;
select public.get_stock_cost_phone_count_version()as installed_stock_cost_phone_count_version;
