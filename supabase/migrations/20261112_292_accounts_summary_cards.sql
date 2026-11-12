-- Read-only Accounts summary cards; filtering happens before the 50-row page.
begin;
do $$begin perform set_config('greenloop.acards_office_before',coalesce(public.get_office_access_version(),''),true);end;$$;
do $$begin if to_regprocedure('greenloop_private.asf_report(text,jsonb,integer,integer,text,text)')is null or to_regprocedure('greenloop_private.aid_report(jsonb,integer,integer,text,text,boolean,text)')is null then raise exception 'Install the existing Accounts stock filters (270) and IMEI Data support first.';end if;end;$$;
create or replace function greenloop_private.acard_report(p_kind text,p_filters jsonb,p_metric text,p_offset integer,p_limit integer,p_sort_key text,p_sort_direction text,p_download boolean,p_summary_only boolean,p_expected_snapshot text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare base jsonb;part jsonb;source jsonb:='[]';selected jsonb;receipts jsonb;summary jsonb;token text;ids uuid[];pos integer:=0;names boolean;receipt_mode boolean:=p_metric like 'receipt_%';metric_key text;result jsonb;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('accounts','view');
 if p_kind is null or p_kind not in('supplier','customer','imei')or p_metric is null or p_metric not in('all','received','in_company','ready','in_process','exported','returned','receipt_received','receipt_returned','receipt_replacement','receipt_balance')or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 or p_download is null or p_summary_only is null then raise exception 'Choose a valid Accounts card and page.'using errcode='22023';end if;
 if p_kind='imei' then
  perform greenloop_private.aid_access(p_filters,p_sort_key,p_sort_direction,p_download);
  base:=greenloop_private.aid_report(p_filters,0,50,p_sort_key,p_sort_direction,true,null);
  source:=base->'rows';
 else
  perform greenloop_private.pf_cap('accounts',p_kind||'_stock');
  if p_download then perform greenloop_private.pf_cap('accounts','print');end if;
  loop
   part:=greenloop_private.asf_report(p_kind,p_filters,pos,50,p_sort_key,p_sort_direction);
   if base is null then base:=part;end if;
   source:=source||(part->'rows');pos:=pos+jsonb_array_length(part->'rows');
   exit when pos>=(part->>'total')::integer;
   if jsonb_array_length(part->'rows')=0 then raise exception 'Incomplete stock report.';end if;
  end loop;
 end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 select coalesce(array_agg(distinct (r->>'batch_id')::uuid)filter(where r->>'batch_id'is not null),array[]::uuid[])into ids from jsonb_array_elements(source)r;
 -- Receipt cards describe original receipt quantities, including stock awaiting IMEI.
 select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object('receipt_quantity',s.received_quantity,'supplier_name',case when names then s.supplier_name end)order by s.received_at desc,s.batch_id),'[]')into receipts
 from greenloop_private.sc_receipts()s where s.parent_batch_id is null and case when p_kind<>'imei' then s.batch_id=any(ids) else
  (nullif(p_filters->>'supplier_id','')is null or s.supplier_id=(p_filters->>'supplier_id')::uuid)
  and(nullif(p_filters->>'batch_id','')is null or s.batch_id=(p_filters->>'batch_id')::uuid)
  and(nullif(p_filters->>'invoice_number','')is null or s.invoice_number=p_filters->>'invoice_number')
  and(nullif(p_filters->>'from_date','')is null or s.received_at>=(p_filters->>'from_date')::date::timestamp at time zone 'Asia/Dubai')
  and(nullif(p_filters->>'to_date','')is null or s.received_at<((p_filters->>'to_date')::date+1)::timestamp at time zone 'Asia/Dubai')
  and(not exists(select 1 from jsonb_each_text(p_filters)f where f.key in('query','model','storage_gb','color','grade','stage')and nullif(f.value,'')is not null)or s.batch_id=any(ids)) end;
 select coalesce(array_agg((r->>'batch_id')::uuid),array[]::uuid[])into ids from jsonb_array_elements(receipts)r;
 if receipt_mode then
  metric_key:=case p_metric when 'receipt_received'then 'received_quantity'when 'receipt_returned'then 'returned_quantity'when 'receipt_replacement'then 'replacement_quantity'else 'balance_quantity'end;
  select coalesce(jsonb_agg(r order by n),'[]')into selected from jsonb_array_elements(receipts)with ordinality x(r,n)where coalesce((r->>metric_key)::numeric,0)>0;
 elsif p_kind='imei' then
  select coalesce(jsonb_agg(r order by n),'[]')into selected from jsonb_array_elements(source)with ordinality x(r,n)where
   p_metric in('all','received')or(p_metric='in_company'and r->>'category'not in('returned','exported'))or(p_metric='in_process'and r->>'category'not in('returned','exported','ready'))or r->>'category'=p_metric;
 else
  select coalesce(jsonb_agg(r order by n),'[]')into selected from jsonb_array_elements(source)with ordinality x(r,n)where p_metric='all'or coalesce((r->>(case when p_kind='customer'and p_metric='exported'then 'quantity'else p_metric end))::numeric,0)>0;
 end if;
 token:=md5(jsonb_build_array(p_kind,p_filters,p_metric,selected)::text);
 if p_download and p_expected_snapshot is not null and p_expected_snapshot<>token then raise exception 'Stock changed. Refresh this card before downloading.'using errcode='40001';end if;
 result:=base||jsonb_build_object('base_summary',base->'summary','base_totals',base->'totals','receipt_summary',greenloop_private.sc_summary(ids),'receipt_mode',receipt_mode,'metric',p_metric,'snapshot',token,'total',jsonb_array_length(selected),'names_allowed',names,'generated_at',statement_timestamp(),
  'rows',case when p_summary_only then '[]'::jsonb when p_download then selected else coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(selected)with ordinality x(r,n)where n>p_offset and n<=p_offset+p_limit),'[]')end);
 if p_kind='imei'and not receipt_mode then
  select jsonb_build_object('total_records',count(*),'imeis',count(*)filter(where r->>'imei'is not null),'in_company',count(*)filter(where r->>'category'not in('returned','exported')),'ready',count(*)filter(where r->>'category'='ready'),'in_process',count(*)filter(where r->>'category'not in('returned','exported','ready')),'exported',count(*)filter(where r->>'category'='exported'),'returned',count(*)filter(where r->>'category'='returned'),'missing_imei',count(*)filter(where r->>'imei'is null))into summary from jsonb_array_elements(selected)r;
  result:=result||jsonb_build_object('summary',summary);
 elsif not receipt_mode then
  select coalesce(jsonb_object_agg(k,v),'{}')into summary from(select k,coalesce((select sum(coalesce((r->>(case when p_kind='customer'and k='exported'then 'quantity'else k end))::numeric,0))from jsonb_array_elements(selected)r),0)v from unnest(array['received','in_company','ready','in_process','exported','returned','quantity'])k)t;
  result:=result||jsonb_build_object('totals',summary);
 end if;
 return result;
end;$$;
revoke all on function greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)from public,anon,authenticated;
create or replace function public.get_accounts_card_report_v1(p_kind text,p_filters jsonb default '{}',p_metric text default 'all',p_offset integer default 0,p_limit integer default 50,p_sort_key text default null,p_sort_direction text default 'asc',p_download boolean default false,p_summary_only boolean default false,p_expected_snapshot text default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.acard_report(p_kind,p_filters,p_metric,p_offset,p_limit,p_sort_key,p_sort_direction,p_download,p_summary_only,p_expected_snapshot);end;$$;
revoke all on function public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)from public,anon;
grant execute on function public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)to authenticated;
insert into greenloop_private.office_routines values('public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)',md5(pg_get_functiondef('greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)'::regprocedure)),md5(pg_get_functiondef('public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_accounts_card_report_v1','{"page":"accounts","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.acard_installation(identity text primary key,hash text not null);
alter table greenloop_private.acard_installation enable row level security;revoke all on greenloop_private.acard_installation from public,anon,authenticated;
create or replace function public.get_accounts_summary_cards_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.acard_installation)
 and has_function_privilege('authenticated','public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','EXECUTE')
 and not has_function_privilege('anon','public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','EXECUTE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_accounts_card_report_v1'and rule='{"page":"accounts","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.office_routines where identity='public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 then '20261112-accounts-summary-cards-1'end;$$;
revoke all on function public.get_accounts_summary_cards_version()from public;grant execute on function public.get_accounts_summary_cards_version()to anon,authenticated;
insert into greenloop_private.acard_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','public.get_accounts_card_report_v1(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','public.get_accounts_summary_cards_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_accounts_summary_cards_version()is distinct from '20261112-accounts-summary-cards-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or coalesce(public.get_office_access_version(),'')is distinct from current_setting('greenloop.acards_office_before')then raise exception 'Accounts summary cards verification failed: cards %, capabilities %, office %. Nothing installed.',public.get_accounts_summary_cards_version(),public.get_page_capabilities_version(),public.get_office_access_version();end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_accounts_summary_cards_version();
