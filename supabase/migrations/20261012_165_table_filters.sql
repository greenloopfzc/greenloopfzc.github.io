-- Read-only table filtering. Existing workflow functions, data and version markers are retained.
begin;
create schema if not exists greenloop_private;
-- Copy the installed read definitions, keeping their permission and privacy checks.
-- Only their outer page limit is removed; matching and pagination happen below.
do $copies$
declare n text; d text; old text; replacement text;
begin
 for n,old,replacement in select * from (values
 ('get_part_inventory_receipts(integer)', 'limit greatest(1, least(coalesce(p_limit, 150), 1000))',''),
 ('get_part_return_report(text,integer)', 'limit greatest(1, least(coalesce(p_limit, 500), 2000))',''),
 ('get_frame_department_report(integer)', 'limit greatest(1, least(coalesce(p_limit, 250), 2000))',''),
 ('get_stock_journey_v1(date,date,text,integer,integer)', 'offset p_offset limit p_limit',''),
 ('get_accounts_stock_v1(text,date,date,text,integer,integer)', 'offset p_offset limit p_limit',''),
 ('get_box_queue_v1(text,date,date,integer,integer)', 'offset p_offset limit p_limit',''),
 ('get_manual_damage_management_v1(text,integer,integer)', 'offset v_offset limit v_limit','')
 ) v(n,old,replacement) loop
  d:=pg_get_functiondef(('public.'||n)::regprocedure);
  if position(old in d)=0 then raise exception 'Filter prerequisite differs: %',n; end if;
  d:=replace(d,'FUNCTION public.'||split_part(n,'(',1)||'(', 'FUNCTION greenloop_private.filter_'||split_part(n,'(',1)||'(');
  d:=replace(d,old,replacement);
  if n='get_part_inventory_receipts(integer)' then d:=replace(d,'order by receipt.received_at desc','order by receipt.received_at desc,receipt.id desc');end if;
  execute d;
  execute 'revoke all on function greenloop_private.filter_'||n||' from public,anon,authenticated';
 end loop;
end; $copies$;

create or replace function greenloop_private.filter_record_matches(r jsonb,f jsonb,keys text[],date_key text)
returns boolean language plpgsql immutable set search_path=pg_catalog as $$
declare k text;v text;d date;q text:=lower(btrim(coalesce(f->>'_search','')));begin
 if q<>'' and not exists(select 1 from unnest(keys) x where strpos(lower(coalesce(r->>x,'')),q)>0) then return false;end if;
 if nullif(f->>'_from','') is not null or nullif(f->>'_to','') is not null then
  d:=(nullif(r->>date_key,'')::timestamptz at time zone 'Asia/Dubai')::date;
  if d is null or d<nullif(f->>'_from','')::date or d>nullif(f->>'_to','')::date then return false;end if;
 end if;
 for k,v in select key,value from jsonb_each_text(f) where key not like '\_%' escape '\' and value<>'' loop
  if not k=any(keys) or lower(coalesce(r->>k,''))<>lower(v) then return false;end if;
 end loop;
 return true;
end; $$;
revoke all on function greenloop_private.filter_record_matches(jsonb,jsonb,text[],text) from public,anon,authenticated;

create or replace function public.get_filter_records_v1(p_source text,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source_rows jsonb;matched jsonb;keys text[];facet_keys text[];date_key text;v_page_key text;facets jsonb;result jsonb;metadata jsonb;
begin
 if p_source is null or jsonb_typeof(p_filters) is distinct from 'object' or octet_length(p_filters::text)>5000 or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>200 then raise exception 'Invalid table filters or page.' using errcode='22023';end if;
 if nullif(p_filters->>'_from','')::date>nullif(p_filters->>'_to','')::date then raise exception 'From date must be on or before To date.' using errcode='22023';end if;
 v_page_key:=case p_source when 'inventory_receipts' then 'inventory' when 'part_returns' then 'parts' when 'frame_results' then 'frame_department' when 'journey' then 'ready_stock_journey' when 'accounts_supplier' then 'accounts' when 'accounts_customer' then 'accounts' when 'accounts' then 'accounts' when 'stock_exported' then 'stock_exported' when 'damage_entry' then 'tv_manual_entry' when 'damage_management' then 'reports' end;
 if v_page_key is null then raise exception 'Unknown filter source.' using errcode='22023';end if;
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not coalesce(
 (select access_level in ('view','edit') from public.user_page_permissions where user_id=auth.uid() and user_page_permissions.page_key=v_page_key),
 public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then raise exception 'Page view permission is required.' using errcode='42501';end if;
 case p_source
 when 'inventory_receipts' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_part_inventory_receipts(150) r;
  keys:=array['receipt_number','invoice_number','source_origin','sku','part_name','notes'];facet_keys:=array['part_name','source_origin'];date_key:='received_at';
 when 'part_returns' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_part_return_report(null,500) r;
  keys:=array['imei','device_number','job_number','supplier_code','part_name','reason','invoice_number','return_condition','returned_by_name'];facet_keys:=array['supplier_code','part_name','return_condition','returned_by_name'];date_key:='returned_at';
 when 'frame_results' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_frame_department_report(250) r;
  keys:=array['imei','supplier_code','model','result','notes','reviewed_by_name'];facet_keys:=array['supplier_code','model','result','reviewed_by_name'];date_key:='reviewed_at';
 when 'journey' then
  source_rows:=greenloop_private.filter_get_stock_journey_v1(null,null,'',0,100)->'rows';
  keys:=array['imei','device_number','device_details','current_stage','current_status','supplier_code','supplier_company','invoice_number','technician_name','box_number','customer_name','company_final_grade'];facet_keys:=array['current_stage','supplier_code','company_final_grade'];date_key:='date_entered';
 when 'accounts_supplier','accounts_customer' then
  source_rows:=greenloop_private.filter_get_accounts_stock_v1(case when p_source='accounts_supplier' then 'supplier' else 'customer' end,null,null,null,0,100)->'rows';
  keys:=array['supplier_code','supplier_name','customer_code','customer_name','invoice_number','batch_number','box_number','model','storage_gb','color','final_grade'];facet_keys:=array['supplier_code','customer_code','model','storage_gb','color','final_grade'];date_key:=case when p_source='accounts_supplier' then 'received_at' else 'exported_at' end;
 when 'accounts','stock_exported' then
  source_rows:=greenloop_private.filter_get_box_queue_v1(p_source,null,null,0,100)->'rows';
  select coalesce(jsonb_agg(value||jsonb_build_object('filter_date',coalesce(value->>'verified_at',value->>'saved_at'))),'[]') into source_rows from jsonb_array_elements(source_rows);
  keys:=array['box_number','customer_code','customer_name','state','saved_by_name','verified_by_name'];facet_keys:=array['state','customer_code','saved_by_name','verified_by_name'];date_key:='filter_date';
 when 'damage_entry','damage_management' then
  if p_source='damage_entry' then perform public.get_manual_damage_report_v2(0,1);
  else metadata:=greenloop_private.filter_get_manual_damage_management_v1('',0,100);end if;
  select coalesce(jsonb_agg(to_jsonb(r)-'request_id'-'reported_by_user_id' order by occurred_at desc,id desc),'[]') into source_rows from greenloop_private.manual_damage_effective r;
  if p_source='damage_management' then source_rows:=metadata->'rows';end if;
  keys:=array['id','damage','damaged_by','department','model','part_name','reason','identifier','part_source','currency','reported_by'];facet_keys:=array['damaged_by','department','model','part_name','part_source','currency'];date_key:='occurred_at';
 else raise exception 'Unknown source';
 end case;
 if exists(select 1 from jsonb_object_keys(p_filters) k where not k=any(keys||array['_from','_to','_search'])) then raise exception 'Unknown filter field.' using errcode='22023';end if;
 select coalesce(jsonb_object_agg(k,values),'{}') into facets from (select k,(select coalesce(jsonb_agg(v order by v),'[]') from (select distinct value->>k v from jsonb_array_elements(source_rows) where nullif(value->>k,'') is not null) vals) values from unnest(facet_keys) k) f;
 select coalesce(jsonb_agg(value order by ord),'[]') into matched from jsonb_array_elements(source_rows) with ordinality r(value,ord) where greenloop_private.filter_record_matches(value,p_filters,keys,date_key);
 select jsonb_build_object('total',jsonb_array_length(matched),'record_count',jsonb_array_length(matched),'total_count',jsonb_array_length(matched),'has_more',p_offset::bigint+p_limit<jsonb_array_length(matched),'facets',facets,
 'rows',coalesce((select jsonb_agg(value order by ord) from (select value,ord from jsonb_array_elements(matched) with ordinality r(value,ord) order by ord offset p_offset limit p_limit) paged),'[]'),
 'totals',jsonb_build_object(
 'received',coalesce((select sum((r->>'received')::numeric) from jsonb_array_elements(matched) r),0),
 'in_company',coalesce((select sum((r->>'in_company')::numeric) from jsonb_array_elements(matched) r),0),
 'ready',coalesce((select sum((r->>'ready')::numeric) from jsonb_array_elements(matched) r),0),
 'in_process',coalesce((select sum((r->>'in_process')::numeric) from jsonb_array_elements(matched) r),0),
 'exported',coalesce((select sum(coalesce(r->>'exported',r->>'quantity')::numeric) from jsonb_array_elements(matched) r),0),
 'returned',coalesce((select sum((r->>'returned')::numeric) from jsonb_array_elements(matched) r),0),
 'quantity',coalesce((select sum(coalesce(r->>'quantity',r->>'quantity_received','0')::numeric) from jsonb_array_elements(matched) r),0),
 'total_cost',coalesce((select sum((r->>'total_cost')::numeric) from jsonb_array_elements(matched) r),0),
 'total_value',coalesce((select sum((r->>'total_value')::numeric) from jsonb_array_elements(matched) r),0),
 'pass',(select count(*) from jsonb_array_elements(matched) r where r->>'result'='pass'),
 'fail',(select count(*) from jsonb_array_elements(matched) r where r->>'result'='fail')
 )) into result;
 return coalesce(metadata,'{}'::jsonb)||result;
end; $$;
revoke all on function public.get_filter_records_v1(text,jsonb,integer,integer) from public,anon,authenticated;
grant execute on function public.get_filter_records_v1(text,jsonb,integer,integer) to authenticated;
create or replace function public.get_part_return_filter_data_v1() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;begin
 perform public.get_filter_records_v1('part_returns','{}',0,1);
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into result from greenloop_private.filter_get_part_return_report(null,500) r;
 return result;
end; $$;
revoke all on function public.get_part_return_filter_data_v1() from public,anon,authenticated;
grant execute on function public.get_part_return_filter_data_v1() to authenticated;
create table if not exists greenloop_private.table_filter_installation(identity text primary key,definition_hash text not null);
revoke all on greenloop_private.table_filter_installation from public,anon,authenticated;
insert into greenloop_private.table_filter_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='greenloop_private' and p.proname in ('filter_record_matches','filter_get_part_inventory_receipts','filter_get_part_return_report','filter_get_frame_department_report','filter_get_stock_journey_v1','filter_get_accounts_stock_v1','filter_get_box_queue_v1','filter_get_manual_damage_management_v1')) or (n.nspname='public' and p.proname in ('get_filter_records_v1','get_part_return_filter_data_v1'))
on conflict(identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_table_filters_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when (select count(*) from greenloop_private.table_filter_installation)=10 and not exists(select 1 from greenloop_private.table_filter_installation i where to_regprocedure(i.identity) is null or md5(pg_get_functiondef(to_regprocedure(i.identity)))<>i.definition_hash) then '20261012-table-filters-1' end;
$$;
revoke all on function public.get_table_filters_version() from public;
grant execute on function public.get_table_filters_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_table_filters_version() as installed_table_filters_version;
