-- Original company receipt quantities, independently of later IMEI entry/replacements.
do $received_install$
begin
 if public.get_ready_stock_daily_averages_version()is distinct from '20261111-ready-stock-averages-1'then raise exception 'Verified Ready Stock daily averages are required.';end if;
 if to_regprocedure('public.get_ready_stock_received_daily_version()')is not null then if public.get_ready_stock_received_daily_version()is distinct from '20261117-ready-stock-received-daily-1'then raise exception 'Existing received-stock daily update integrity differs.';end if;end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Existing permission rules are not verified.';end if;
 execute $definition$create or replace function greenloop_private.rsr_receipts(p_from date,p_to date)returns table(batch_id uuid,receipt_day date,quantity bigint)language sql stable security definer set search_path=pg_catalog,public as $body$
 select b.id,(b.received_at at time zone 'Asia/Dubai')::date,b.planned_quantity::bigint from public.receiving_batches b
 where b.planned_quantity is not null and b.planned_quantity>=0
 and b.received_at>=(p_from::timestamp at time zone 'Asia/Dubai')and b.received_at<((p_to+1)::timestamp at time zone 'Asia/Dubai')and b.received_at<=now()
 and not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id);$body$;$definition$;
 revoke all on function greenloop_private.rsr_receipts(date,date)from public,anon,authenticated;
 execute $definition$create or replace function public.get_ready_stock_daily_metrics_v2(p_date date default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare result jsonb;selected_day date;received bigint;average_total bigint;days integer;
 begin
  result:=public.get_ready_stock_daily_metrics_v1(p_date);selected_day:=(result->>'date')::date;days:=(result->'average'->>'days')::integer;
  select coalesce(sum(quantity)filter(where r.receipt_day=selected_day),0),coalesce(sum(quantity)filter(where r.receipt_day<selected_day and extract(dow from r.receipt_day)<>0),0)into received,average_total from greenloop_private.rsr_receipts(selected_day-30,selected_day)r;
  return result||jsonb_build_object('received_count',received,'average',(result->'average')||jsonb_build_object('received_total',average_total,'received_daily',round(average_total::numeric/nullif(days,0),2)));
 end;$body$;$definition$;
 execute $definition$create or replace function public.get_ready_stock_received_activity_v1(p_date date default null,p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare selected_day date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);names boolean;result jsonb;
 begin
  perform greenloop_private.pf_cap('ready_stock','view');
  if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
  if selected_day<>(now()at time zone 'Asia/Dubai')::date then perform greenloop_private.pf_cap('ready_stock','search');end if;
  if selected_day>(now()at time zone 'Asia/Dubai')::date or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Choose a valid date and 50-receipt page.'using errcode='22023';end if;
  names:=coalesce(public.get_my_partner_name_access(),false);
  with facts as materialized(select *from greenloop_private.rsr_receipts(selected_day,selected_day)),selected as(select *from facts order by batch_id offset p_offset limit p_limit),rows as(
   select f.batch_id,b.batch_number,b.invoice_number,f.quantity,b.received_at,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name,b.planned_quantity
   from selected f join public.receiving_batches b on b.id=f.batch_id left join public.suppliers s on s.id=b.supplier_id)
  select jsonb_build_object('date',selected_day,'timezone','Asia/Dubai','kind','received','offset',p_offset,'limit',p_limit,'received_count',(select coalesce(sum(quantity),0)from facts),'total',(select count(*)from facts),'rows',coalesce((select jsonb_agg(to_jsonb(r)order by batch_id)from rows r),'[]'::jsonb))into result;
  return result;
 end;$body$;$definition$;
 revoke all on function public.get_ready_stock_daily_metrics_v2(date),public.get_ready_stock_received_activity_v1(date,integer,integer)from public,anon,authenticated;
 grant execute on function public.get_ready_stock_daily_metrics_v2(date),public.get_ready_stock_received_activity_v1(date,integer,integer)to authenticated;
 insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_ready_stock_daily_metrics_v2','{"page":"ready_stock","capability":"view","read":true}'),('get_ready_stock_received_activity_v1','{"page":"ready_stock","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
 create table if not exists greenloop_private.ready_received_daily_installation(identity text primary key,hash text not null);
 alter table greenloop_private.ready_received_daily_installation enable row level security;
 revoke all on greenloop_private.ready_received_daily_installation from public,anon,authenticated;
 execute $definition$create or replace function public.get_ready_stock_received_daily_version()returns text language sql stable security definer set search_path=pg_catalog,public as $body$
 select case when public.get_ready_stock_daily_averages_version()='20261111-ready-stock-averages-1'
 and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.ready_received_daily_installation)
 and not exists(select 1 from greenloop_private.ready_received_daily_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='greenloop_private'::regnamespace and(has_function_privilege('anon',p.oid,'EXECUTE')or has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and not has_function_privilege('anon','public.get_ready_stock_daily_metrics_v2(date)','EXECUTE')and has_function_privilege('authenticated','public.get_ready_stock_daily_metrics_v2(date)','EXECUTE')
 and not has_function_privilege('anon','public.get_ready_stock_received_activity_v1(date,integer,integer)','EXECUTE')and has_function_privilege('authenticated','public.get_ready_stock_received_activity_v1(date,integer,integer)','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.ready_received_daily_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.ready_received_daily_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.ready_received_daily_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_ready_stock_daily_metrics_v2'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_ready_stock_received_activity_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 then '20261117-ready-stock-received-daily-1'end;$body$;$definition$;
 revoke all on function public.get_ready_stock_received_daily_version()from public;grant execute on function public.get_ready_stock_received_daily_version()to anon,authenticated;
 insert into greenloop_private.ready_received_daily_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rsr_receipts(date,date)','public.get_ready_stock_daily_metrics_v2(date)','public.get_ready_stock_received_activity_v1(date,integer,integer)','public.get_ready_stock_received_daily_version()'])s on conflict(identity)do update set hash=excluded.hash;
 if public.get_ready_stock_received_daily_version()is distinct from '20261117-ready-stock-received-daily-1'then raise exception 'Daily received-stock verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$received_install$;
select public.get_ready_stock_received_daily_version()as installed_ready_stock_received_daily_version;
