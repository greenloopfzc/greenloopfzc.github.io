-- Accounts stock filters read canonical receipt and customer relationships.
begin;
do $$begin
 if to_regprocedure('public.get_accounts_stock_filters_version()')is not null then if public.get_accounts_stock_filters_version()is distinct from '20261109-accounts-stock-filters-1'then raise exception 'Existing Accounts Stock Filters integrity differs.';end if;end if;
 if public.get_installation_component_engine_version()is distinct from '20261107-installation-components-1'then raise exception 'Verified installation component support is required.';end if;
end;$$;
create or replace function greenloop_private.asf_report(p_kind text,p_filters jsonb,p_offset integer,p_limit integer,p_sort_by text,p_sort_direction text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source_rows jsonb;matched jsonb;facets jsonb;outcome jsonb;names boolean;keys text[]:=array['supplier_code','supplier_name','batch_number','invoice_number','customer_code','customer_name','model','storage_gb','color','final_grade','box_number'];facet_keys text[];date_key text;sort_keys text[];number_keys text[]:=array['storage_gb','received','in_company','ready','in_process','exported','returned','quantity','awaiting_imei'];sort_type text;ids uuid[];
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('accounts','view');
 if p_kind is null or p_kind not in('supplier','customer')then raise exception 'Select Supplier Stock or Customer Stock.'using errcode='22023';end if;
 perform greenloop_private.pf_cap('accounts',p_kind||'_stock');
 if jsonb_typeof(p_filters)is distinct from 'object'or octet_length(p_filters::text)>5000 or exists(select 1 from jsonb_object_keys(p_filters)k where not k=any(keys||array['_search','_from','_to']))or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 or p_sort_direction is null or p_sort_direction not in('asc','desc')then raise exception 'Select valid stock filters, sorting and page.'using errcode='22023';end if;
 if exists(select 1 from jsonb_each_text(p_filters)where coalesce(value,'')<>'')then perform greenloop_private.pf_cap('accounts','search');end if;
 if p_sort_by is not null then perform greenloop_private.pf_cap('accounts','sort');end if;
 if nullif(p_filters->>'_from','')::date>nullif(p_filters->>'_to','')::date then raise exception 'From date must be before To date.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 if not names and (nullif(p_filters->>'supplier_name','')is not null or nullif(p_filters->>'customer_name','')is not null or p_sort_by in('supplier_name','customer_name'))then raise exception 'Supplier and customer name permission is required.'using errcode='42501';end if;
 date_key:=case when p_kind='supplier'then 'received_at'else 'exported_at'end;
 sort_keys:=keys||number_keys||array['received_at','exported_at'];
 if p_sort_by is not null and not p_sort_by=any(sort_keys)then raise exception 'Unknown sort field.'using errcode='22023';end if;
 sort_type:=case when p_sort_by=any(number_keys)then 'number'when p_sort_by in('received_at','exported_at')then 'date'else 'text'end;
 if p_kind='supplier'then
  select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('batch_number',b.batch_number,'invoice_number',b.invoice_number,'receipt_quantity',b.planned_quantity,'supplier_name',case when names then r.supplier_name end,'supplier_code',case when r.supplier_code is not null then regexp_replace(r.supplier_code,'-\([0-9]+\)$','')||case when b.planned_quantity is not null then '-('||b.planned_quantity::text||')'else ''end end)order by r.received_at desc,r.batch_id,r.model,r.storage_gb,r.color),'[]')into source_rows
  from greenloop_private.accounts_supplier_rows()r left join public.receiving_batches b on b.id=r.batch_id;
 else
  select coalesce(jsonb_agg(to_jsonb(r)order by r.exported_at desc,r.box_id,r.batch_id,r.model,r.storage_gb,r.color,r.final_grade),'[]')into source_rows from(
   select w.box_id,b.box_number,coalesce(w.verified_at,b.closed_at)exported_at,w.state,coalesce(w.customer_id,c.id)customer_id,
    coalesce(w.customer_code,c.customer_code,'Not recorded')customer_code,case when names then coalesce(w.customer_name,c.company_name,'Not recorded')end customer_name,
    rb.id batch_id,rb.batch_number,rb.invoice_number,rb.received_at,rb.planned_quantity receipt_quantity,
    case when s.supplier_code is not null then regexp_replace(s.supplier_code,'-\([0-9]+\)$','')||case when rb.planned_quantity is not null then '-('||rb.planned_quantity::text||')'else ''end end supplier_code,case when names then s.company_name end supplier_name,
    i.model,i.storage_gb,i.color,i.final_grade,count(*)::bigint quantity
   from greenloop_private.box_workflow w join public.export_boxes b on b.id=w.box_id join public.export_box_items i on i.box_id=b.id
   join public.jobs j on j.id=i.job_id left join public.receiving_batches rb on rb.id=j.receiving_batch_id
   left join public.suppliers s on s.id=coalesce(j.supplier_id,rb.supplier_id)left join public.customers c on c.id=coalesce(w.customer_id,j.customer_id)
   where w.state in('exported','legacy')
   group by w.box_id,b.box_number,w.verified_at,b.closed_at,w.state,w.customer_id,c.id,w.customer_code,c.customer_code,w.customer_name,c.company_name,
    rb.id,rb.batch_number,rb.invoice_number,rb.received_at,rb.planned_quantity,s.supplier_code,s.company_name,i.model,i.storage_gb,i.color,i.final_grade
  )r;
 end if;
 facet_keys:=array['supplier_code','supplier_name','batch_number','invoice_number','customer_code','customer_name','model','storage_gb','color','final_grade'];
 select coalesce(jsonb_object_agg(k,vals),'{}')into facets from(select k,(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct value->>k v from jsonb_array_elements(source_rows)where nullif(value->>k,'')is not null and greenloop_private.filter_record_matches(value,p_filters-k,keys,date_key))x)vals from unnest(facet_keys)k)f;
 select coalesce(jsonb_agg(value order by ord),'[]')into matched from jsonb_array_elements(source_rows)with ordinality r(value,ord)where greenloop_private.filter_record_matches(value,p_filters,keys,date_key);
 select coalesce(array_agg(distinct (value->>'batch_id')::uuid)filter(where value->>'batch_id'is not null),array[]::uuid[])into ids from jsonb_array_elements(matched);
 select coalesce(jsonb_agg(value order by
 case when sort_type='number'and p_sort_direction='asc'then nullif(value->>p_sort_by,'')::numeric end asc nulls last,case when sort_type='number'and p_sort_direction='desc'then nullif(value->>p_sort_by,'')::numeric end desc nulls last,
 case when sort_type='date'and p_sort_direction='asc'then nullif(value->>p_sort_by,'')::timestamptz end asc nulls last,case when sort_type='date'and p_sort_direction='desc'then nullif(value->>p_sort_by,'')::timestamptz end desc nulls last,
 case when sort_type='text'and p_sort_direction='asc'then lower(nullif(value->>p_sort_by,''))end asc nulls last,case when sort_type='text'and p_sort_direction='desc'then lower(nullif(value->>p_sort_by,''))end desc nulls last,ord),'[]')into matched from jsonb_array_elements(matched)with ordinality r(value,ord);
 select jsonb_build_object('total',jsonb_array_length(matched),'names_allowed',names,'facets',facets,'rows',coalesce((select jsonb_agg(value order by ord)from(select value,ord from jsonb_array_elements(matched)with ordinality r(value,ord)order by ord offset p_offset limit p_limit)x),'[]'),
 'receipt_summary',greenloop_private.sc_summary(ids),'totals',jsonb_build_object('received',coalesce((select sum((r->>'received')::bigint)from jsonb_array_elements(matched)r),0),'in_company',coalesce((select sum((r->>'in_company')::bigint)from jsonb_array_elements(matched)r),0),'ready',coalesce((select sum((r->>'ready')::bigint)from jsonb_array_elements(matched)r),0),'in_process',coalesce((select sum((r->>'in_process')::bigint)from jsonb_array_elements(matched)r),0),'exported',coalesce((select sum(coalesce(r->>'exported',r->>'quantity')::bigint)from jsonb_array_elements(matched)r),0),'returned',coalesce((select sum((r->>'returned')::bigint)from jsonb_array_elements(matched)r),0),'quantity',coalesce((select sum((r->>'quantity')::bigint)from jsonb_array_elements(matched)r),0)))into outcome;
 return outcome;
end;$$;
revoke all on function greenloop_private.asf_report(text,jsonb,integer,integer,text,text)from public,anon,authenticated;
create or replace function public.get_accounts_stock_report_v2(p_kind text,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_by text default null,p_sort_direction text default 'asc')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.asf_report(p_kind,p_filters,p_offset,p_limit,p_sort_by,p_sort_direction);end;$$;
revoke all on function public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)from public,anon,authenticated;grant execute on function public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)to authenticated;
insert into greenloop_private.office_routines values('public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)','greenloop_private.asf_report(text,jsonb,integer,integer,text,text)',md5(pg_get_functiondef('greenloop_private.asf_report(text,jsonb,integer,integer,text,text)'::regprocedure)),md5(pg_get_functiondef('public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_accounts_stock_report_v2','{"dynamic":"accounts_stock","parameter":"p_kind","read":true,"supplier":{"page":"accounts","capability":"supplier_stock"},"customer":{"page":"accounts","capability":"customer_stock"}}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.accounts_stock_filters_installation(identity text primary key,hash text not null);alter table greenloop_private.accounts_stock_filters_installation enable row level security;revoke all on greenloop_private.accounts_stock_filters_installation from public,anon,authenticated;
create or replace function public.get_accounts_stock_filters_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.accounts_stock_filters_installation)
 and has_function_privilege('authenticated','public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)','EXECUTE')and not has_function_privilege('anon','public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.asf_report(text,jsonb,integer,integer,text,text)','EXECUTE')and not has_function_privilege('anon','greenloop_private.asf_report(text,jsonb,integer,integer,text,text)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.accounts_stock_filters_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.accounts_stock_filters_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and exists(select 1 from pg_class where oid='greenloop_private.accounts_stock_filters_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_accounts_stock_report_v2'and rule='{"dynamic":"accounts_stock","parameter":"p_kind","read":true,"supplier":{"page":"accounts","capability":"supplier_stock"},"customer":{"page":"accounts","capability":"customer_stock"}}'::jsonb)then '20261109-accounts-stock-filters-1'end;$$;
revoke all on function public.get_accounts_stock_filters_version()from public;grant execute on function public.get_accounts_stock_filters_version()to anon,authenticated;
insert into greenloop_private.accounts_stock_filters_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.asf_report(text,jsonb,integer,integer,text,text)','public.get_accounts_stock_report_v2(text,jsonb,integer,integer,text,text)','public.get_accounts_stock_filters_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_accounts_stock_filters_version()is distinct from '20261109-accounts-stock-filters-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Accounts Stock Filters installation failed. No changes installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_accounts_stock_filters_version()as installed_accounts_stock_filters_version;
