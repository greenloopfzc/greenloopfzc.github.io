-- Add ordering to filtered reports without altering existing readers or business records.
begin;
do $$ begin
 if public.get_table_filters_version() is distinct from '20261012-table-filters-1' then raise exception 'Install and verify Table Filters before Table Sorting.';end if;
end; $$;
create or replace function public.get_sorted_filter_records_v1(p_source text,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_by text default null,p_sort_direction text default 'asc')
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source_rows jsonb;matched jsonb;keys text[];facet_keys text[];date_key text;v_page_key text;facets jsonb;result jsonb;metadata jsonb;sort_keys text[];number_keys text[];date_keys text[];sort_type text;
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

 -- Only typed, visible fields may control ordering. Filtering and privacy run first.
 number_keys:=array['quantity','quantity_received','total_cost','unit_cost','storage_gb','received','in_company','ready','in_process','exported','returned','awaiting_imei','price_amount','total_value','parts_cost'];
 date_keys:=array['received_at','returned_at','reviewed_at','date_entered','date_received','date_completed','export_date','exported_at','saved_at','verified_at','filter_date','occurred_at','created_at'];
 sort_keys:=keys||array[date_key]||case p_source
 when 'inventory_receipts' then array['quantity_received','total_cost','unit_cost']
 when 'part_returns' then array['quantity']
 when 'journey' then array['date_received','date_completed','export_date','parts_cost','quantity_received','stock_channel','battery_health','supplier_grade','company_initial_grade','parts_issued','service_done']
 when 'accounts_supplier' then array['received','in_company','ready','in_process','exported','returned','awaiting_imei']
 when 'accounts_customer' then array['received_at','quantity']
 when 'accounts' then array['saved_at','verified_at','quantity']
 when 'stock_exported' then array['saved_at','verified_at','quantity']
 when 'damage_entry' then array['quantity','price_amount','total_value','created_at']
 when 'damage_management' then array['quantity','price_amount','total_value','created_at']
 else array[]::text[] end;
 if p_sort_direction is null or p_sort_direction not in ('asc','desc') or (p_sort_by is not null and not p_sort_by=any(sort_keys)) then raise exception 'Invalid sort field or direction.' using errcode='22023';end if;
 sort_type:=case when p_sort_by=any(number_keys) then 'number' when p_sort_by=any(date_keys) then 'date' else 'text' end;
 if p_source in ('damage_entry','damage_management') then
  select coalesce(jsonb_agg(value||jsonb_build_object('total_value',nullif(value->>'price_amount','')::numeric*coalesce(nullif(value->>'quantity','')::numeric,1)) order by ord),'[]') into source_rows from jsonb_array_elements(source_rows) with ordinality r(value,ord);
 end if;
 if exists(select 1 from jsonb_object_keys(p_filters) k where not k=any(keys||array['_from','_to','_search'])) then raise exception 'Unknown filter field.' using errcode='22023';end if;
 select coalesce(jsonb_object_agg(k,values),'{}') into facets from (select k,(select coalesce(jsonb_agg(v order by v),'[]') from (select distinct value->>k v from jsonb_array_elements(source_rows) where nullif(value->>k,'') is not null) vals) values from unnest(facet_keys) k) f;
 select coalesce(jsonb_agg(value order by ord),'[]') into matched from jsonb_array_elements(source_rows) with ordinality r(value,ord) where greenloop_private.filter_record_matches(value,p_filters,keys,date_key);

 -- Sort the whole matching array before taking a page; missing values stay last.
 -- Original ordinal is the final tiebreaker so equal values remain stable.
 if p_sort_by is not null then
  select coalesce(jsonb_agg(value order by
   case when sort_type='number' and p_sort_direction='asc' then nullif(value->>p_sort_by,'')::numeric end asc nulls last,
   case when sort_type='number' and p_sort_direction='desc' then nullif(value->>p_sort_by,'')::numeric end desc nulls last,
   case when sort_type='date' and p_sort_direction='asc' then nullif(value->>p_sort_by,'')::timestamptz end asc nulls last,
   case when sort_type='date' and p_sort_direction='desc' then nullif(value->>p_sort_by,'')::timestamptz end desc nulls last,
   case when sort_type='text' and p_sort_direction='asc' then lower(nullif(btrim(value->>p_sort_by),'')) end asc nulls last,
   case when sort_type='text' and p_sort_direction='desc' then lower(nullif(btrim(value->>p_sort_by),'')) end desc nulls last,
   ord),'[]') into matched from jsonb_array_elements(matched) with ordinality r(value,ord);
 end if;
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
revoke all on function public.get_sorted_filter_records_v1(text,jsonb,integer,integer,text,text) from public,anon,authenticated;
grant execute on function public.get_sorted_filter_records_v1(text,jsonb,integer,integer,text,text) to authenticated;


-- Retain the installed Super Admin/session guard and alert cursor logic.
do $$ declare d text;begin
 d:=pg_get_functiondef('public.get_login_activity_v1(text,date,date,integer,integer,bigint)'::regprocedure);
 if position('offset p_offset limit p_limit' in d)=0 then raise exception 'Login Activity reader differs from the sorting prerequisite.';end if;
 d:=replace(d,'FUNCTION public.get_login_activity_v1(', 'FUNCTION greenloop_private.sort_login_activity_source(');
 execute replace(d,'offset p_offset limit p_limit','');
end; $$;
revoke all on function greenloop_private.sort_login_activity_source(text,date,date,integer,integer,bigint) from public,anon,authenticated;
create or replace function public.get_sorted_login_activity_v1(p_search text default '',p_from date default null,p_to date default null,p_offset integer default 0,p_limit integer default 25,p_after_id bigint default null,p_sort_by text default null,p_sort_direction text default 'asc')
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;ordered jsonb;is_date boolean;begin
 if p_sort_direction is null or p_sort_direction not in ('asc','desc') or (p_sort_by is not null and p_sort_by not in ('name','username','login_at','device','browser','login_surface','last_seen','last_page','status')) then raise exception 'Invalid login sort.' using errcode='22023';end if;
 result:=greenloop_private.sort_login_activity_source(p_search,p_from,p_to,p_offset,p_limit,p_after_id);
 is_date:=p_sort_by in ('login_at','last_seen');
 select coalesce(jsonb_agg(value order by
  case when is_date and p_sort_direction='asc' then (value->>p_sort_by)::timestamptz end asc nulls last,
  case when is_date and p_sort_direction='desc' then (value->>p_sort_by)::timestamptz end desc nulls last,
  case when not is_date and p_sort_direction='asc' then lower(nullif(value->>p_sort_by,'')) end asc nulls last,
  case when not is_date and p_sort_direction='desc' then lower(nullif(value->>p_sort_by,'')) end desc nulls last,
  ord),'[]') into ordered from jsonb_array_elements(result->'rows') with ordinality r(value,ord);
 return result||jsonb_build_object('rows',coalesce((select jsonb_agg(value order by ord) from (select value,ord from jsonb_array_elements(ordered) with ordinality r(value,ord) order by ord offset p_offset limit p_limit) p),'[]'));
end; $$;
revoke all on function public.get_sorted_login_activity_v1(text,date,date,integer,integer,bigint,text,text) from public,anon,authenticated;
grant execute on function public.get_sorted_login_activity_v1(text,date,date,integer,integer,bigint,text,text) to authenticated;

create table if not exists greenloop_private.table_sort_installation(identity text primary key,definition_hash text not null);
revoke all on greenloop_private.table_sort_installation from public,anon,authenticated;
insert into greenloop_private.table_sort_installation values('public.get_sorted_filter_records_v1(text,jsonb,integer,integer,text,text)',md5(pg_get_functiondef('public.get_sorted_filter_records_v1(text,jsonb,integer,integer,text,text)'::regprocedure)))
on conflict(identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.table_sort_installation select signature,md5(pg_get_functiondef(signature::regprocedure)) from unnest(array['greenloop_private.sort_login_activity_source(text,date,date,integer,integer,bigint)','public.get_sorted_login_activity_v1(text,date,date,integer,integer,bigint,text,text)']) signature
on conflict(identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_table_sorting_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_table_filters_version()='20261012-table-filters-1' and (select count(*) from greenloop_private.table_sort_installation)=3 and not exists(select 1 from greenloop_private.table_sort_installation i where to_regprocedure(i.identity) is null or md5(pg_get_functiondef(to_regprocedure(i.identity)))<>i.definition_hash) then '20261013-table-sorting-1' end;
$$;
revoke all on function public.get_table_sorting_version() from public;
grant execute on function public.get_table_sorting_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_table_sorting_version() as installed_table_sorting_version;
