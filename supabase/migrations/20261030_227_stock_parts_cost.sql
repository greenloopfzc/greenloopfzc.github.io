-- Read-only stock -> phone -> issued parts cost report. No operational writes.
begin;
do $$begin if public.get_pending_parts_prices_version()is distinct from '20261030-pending-parts-prices-1'then raise exception 'Install verified Pending Parts Prices first.';end if;end;$$;
-- Freeze existing defaults before adding a confidential read permission.
do $$declare u record;begin if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @> '[{"key":"stock_parts_cost"}]')then
 for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
 update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"stock_parts_cost","label":"View Stock Parts Cost (confidential)","write":false}]'where page_key='reports';
 update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',(capabilities->'reports')||'["stock_parts_cost"]')where capabilities->'reports'?'view'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
end if;end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create or replace function greenloop_private.scp_access(f jsonb)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_access('reports'),false)or not coalesce(public.has_page_capability_v1('reports','view'),false)or not coalesce(public.has_page_capability_v1('reports','stock_parts_cost'),false)then raise exception 'Stock Parts Cost report permission is required.'using errcode='42501';end if;
 if coalesce(f,'{}')<>'{}'::jsonb and not coalesce(public.has_page_capability_v1('reports','search'),false)then raise exception 'Reports Search permission is required for these filters.'using errcode='42501';end if;
 if jsonb_typeof(coalesce(f,'{}'))is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['supplier_id','batch_id','invoice_number','query','from_date','to_date'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Select valid stock cost filters.'using errcode='22023';end if;
 if coalesce(f->>'from_date','')<>''then perform(f->>'from_date')::date;end if;if coalesce(f->>'to_date','')<>''then perform(f->>'to_date')::date;end if;
 if coalesce(f->>'from_date','')<>''and coalesce(f->>'to_date','')<>''and(f->>'from_date')::date>(f->>'to_date')::date then raise exception 'From date must be on or before To date.'using errcode='22023';end if;
end;$$;
create or replace function greenloop_private.scp_totals(lines jsonb)returns jsonb language sql immutable set search_path=pg_catalog as $$
 select coalesce(jsonb_agg(to_jsonb(t)order by currency),'[]')from(
 select u->>'currency'currency,sum((u->>'quantity')::numeric)quantity,sum((u->>'returned_quantity')::numeric)returned_quantity,
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
create or replace function greenloop_private.scp_data(f jsonb,p_stock text,p_device uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare scopes jsonb;jobs jsonb;units jsonb;phones jsonb;stocks jsonb;chosen jsonb;all_scopes jsonb;facets jsonb;result jsonb;
begin
 if p_stock is not null and p_stock!~'^[a-f0-9]{32}$'then raise exception 'Select a valid stock.'using errcode='22023';end if;
 if p_device is not null and p_stock is null then raise exception 'Select a stock before selecting its phone.'using errcode='22023';end if;
 -- Receipt rows exist even before any IMEI has been entered. Unlinked legacy
 -- jobs receive separate keys rather than merging unrelated stock.
 with s as(
 select md5('batch:'||b.id::text)stock_key,b.id::text batch_id,b.batch_number,b.invoice_number,b.supplier_id::text supplier_id,coalesce(s.supplier_code,'Not recorded')supplier_code,b.planned_quantity,b.created_at received_at from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id
 union all
 select md5('legacy:'||j.id::text),'legacy:'||j.id::text,'Legacy phone '||d.imei_1,null,j.supplier_id::text,coalesce(s.supplier_code,'Not recorded'),1,j.received_at from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null left join public.suppliers s on s.id=j.supplier_id where j.deleted_at is null and j.receiving_batch_id is null
 )select coalesce(jsonb_agg(to_jsonb(s)order by received_at desc,stock_key),'[]')into all_scopes from s;
 select jsonb_build_object(
 'supplier_id',coalesce((select jsonb_agg(jsonb_build_object('value',id,'label',code)order by code)from(select distinct u->>'supplier_id'id,u->>'supplier_code'code from jsonb_array_elements(all_scopes)u where u->>'supplier_id'is not null)x),'[]'),
 'batch_id',coalesce((select jsonb_agg(jsonb_build_object('value',u->>'batch_id','label',concat_ws(' · ',u->>'batch_number',u->>'invoice_number',u->>'supplier_code'))order by u->>'batch_number')from jsonb_array_elements(all_scopes)u where coalesce(f->>'supplier_id','')=''or u->>'supplier_id'=f->>'supplier_id'),'[]'),
 'invoice_number',coalesce((select jsonb_agg(jsonb_build_object('value',v,'label',v)order by v)from(select distinct u->>'invoice_number'v from jsonb_array_elements(all_scopes)u where nullif(u->>'invoice_number','')is not null and(coalesce(f->>'supplier_id','')=''or u->>'supplier_id'=f->>'supplier_id'))x),'[]'))into facets;
 select coalesce(jsonb_agg(u),'[]')into scopes from jsonb_array_elements(all_scopes)u where(coalesce(f->>'supplier_id','')=''or u->>'supplier_id'=f->>'supplier_id')and(coalesce(f->>'batch_id','')=''or u->>'batch_id'=f->>'batch_id')and(coalesce(f->>'invoice_number','')=''or u->>'invoice_number'=f->>'invoice_number')
 and(coalesce(f->>'query','')=''or strpos(lower(concat_ws(' ',u->>'batch_number',u->>'invoice_number',u->>'supplier_code')),lower(f->>'query'))>0)
 and(coalesce(f->>'from_date','')=''or timezone('Asia/Dubai',(u->>'received_at')::timestamptz)::date>=(f->>'from_date')::date)
 and(coalesce(f->>'to_date','')=''or timezone('Asia/Dubai',(u->>'received_at')::timestamptz)::date<=(f->>'to_date')::date);
 select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'job_number',j.job_number,'device_id',d.id,'imei',d.imei_1,'device_number',d.device_number,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,'status',j.current_status,'stock_key',s->>'stock_key')),'[]')into jobs from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null join jsonb_array_elements(scopes)s on s->>'batch_id'=coalesce(j.receiving_batch_id::text,'legacy:'||j.id::text)where j.deleted_at is null;
 with issue_rows as(
 select i.id::text line_id,'Issued part'::text kind,j->>'stock_key'stock_key,j->>'device_id'device_id,j->>'job_id'job_id,j->>'job_number'job_number,r.part_name,i.quantity_issued::numeric quantity,i.quantity_returned::numeric returned_quantity,
 least(i.quantity_issued,i.quantity_returned,coalesce(a.restocked,0))::numeric restocked_quantity,least(i.quantity_issued,coalesce(a.damaged,0))::numeric damaged_quantity,least(i.quantity_issued,coalesce(a.faulty,0))::numeric faulty_quantity,
 greatest(0,i.quantity_returned-coalesce(a.classified,0))::numeric unclassified_return_quantity,
 case when p.issue_id is not null then p.unit_price when i.issue_notes like 'Issued by Parts Flow;%'then null else i.unit_cost end unit_price,coalesce(p.currency,'AED')currency,coalesce(src.source,'unrecorded')source,i.issued_at occurred_at
 from jsonb_array_elements(jobs)j join public.job_part_requests r on r.job_id=(j->>'job_id')::uuid join public.part_issue_transactions i on i.part_request_id=r.id
 left join greenloop_private.parts_flow_prices p on p.issue_id=i.id
 left join lateral(select source from greenloop_private.parts_issue_sources where issue_id=i.id order by id desc limit 1)src on true
 left join lateral(select sum(quantity)filter(where return_condition='restocked')restocked,sum(quantity)filter(where return_condition='damaged')damaged,sum(quantity)filter(where return_condition='faulty')faulty,sum(quantity)filter(where return_condition in('restocked','damaged','faulty'))classified from public.part_return_audit where part_issue_id=i.id)a on true where i.quantity_issued>0
 ),standalone as(
 select 'manual:'||i.id,'Unpriced manual part',j->>'stock_key',j->>'device_id',j->>'job_id',j->>'job_number',i.part_name,i.quantity::numeric,0,0,0,0,0,null::numeric,'AED','unrecorded',i.installed_at from jsonb_array_elements(jobs)j join public.lab_manual_part_installations i on i.job_id=(j->>'job_id')::uuid
 ),u as(select *from issue_rows union all select *from standalone)
 select coalesce(jsonb_agg(to_jsonb(u)||jsonb_build_object('net_quantity',quantity-restocked_quantity,'recorded_cost',unit_price*(quantity-restocked_quantity))order by occurred_at,line_id),'[]')into units from u;
 with partsets as(select u->>'stock_key'sk,u->>'device_id'did,jsonb_agg(u)lines,coalesce(sum((u->>'net_quantity')::numeric)filter(where u->>'unit_price'is null),0)pending from jsonb_array_elements(units)u group by u->>'stock_key',u->>'device_id'),
 base as(select j->>'stock_key'stock_key,j->>'device_id'device_id,min(j->>'imei')imei,min(j->>'device_number')device_number,min(j->>'model')model,min((j->>'storage_gb')::integer)storage_gb,min(j->>'color')color,string_agg(distinct j->>'status',', ')status from jsonb_array_elements(jobs)j group by j->>'stock_key',j->>'device_id')
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('totals',greenloop_private.scp_totals(coalesce(p.lines,'[]')),'pending_quantity',coalesce(p.pending,0))order by x.imei),'[]')into phones from base x left join partsets p on p.sk=x.stock_key and p.did=x.device_id;
 with partsets as(select u->>'stock_key'sk,jsonb_agg(u)lines,coalesce(sum((u->>'net_quantity')::numeric)filter(where u->>'unit_price'is null),0)pending from jsonb_array_elements(units)u group by u->>'stock_key'),
 counts as(select p->>'stock_key'sk,count(*)n from jsonb_array_elements(phones)p group by p->>'stock_key')
 select coalesce(jsonb_agg(s||jsonb_build_object('phones',coalesce(c.n,0),'totals',greenloop_private.scp_totals(coalesce(p.lines,'[]')),'pending_quantity',coalesce(p.pending,0))order by s->>'received_at'desc),'[]')into stocks from jsonb_array_elements(scopes)s left join partsets p on p.sk=s->>'stock_key'left join counts c on c.sk=s->>'stock_key';
 select s into chosen from jsonb_array_elements(stocks)s where s->>'stock_key'=p_stock;
 if p_stock is not null and chosen is null then raise exception 'This stock is no longer available under the selected filters. Refresh the report.'using errcode='40001';end if;
 if p_device is not null and not exists(select 1 from jsonb_array_elements(phones)p where p->>'stock_key'=p_stock and p->>'device_id'=p_device::text)then raise exception 'This phone does not belong to the selected stock.'using errcode='22023';end if;
 result:=jsonb_build_object('generated_at',now(),'stocks',stocks,'facets',facets,'selected_stock',chosen,'summary',jsonb_build_object('stocks',jsonb_array_length(stocks),'phones',(select count(distinct p->>'device_id')from jsonb_array_elements(phones)p),'pending_quantity',coalesce((select sum((p->>'pending_quantity')::numeric)from jsonb_array_elements(phones)p),0),'totals',greenloop_private.scp_totals(units)),
 'phones',case when p_stock is null then '[]'::jsonb else coalesce((select jsonb_agg(p order by p->>'imei')from jsonb_array_elements(phones)p where p->>'stock_key'=p_stock),'[]')end,
 'selected_phone',case when p_device is null then null else(select p from jsonb_array_elements(phones)p where p->>'stock_key'=p_stock and p->>'device_id'=p_device::text)end,
 'parts',case when p_device is null then '[]'::jsonb else coalesce((select jsonb_agg(u order by u->>'occurred_at',u->>'line_id')from jsonb_array_elements(units)u where u->>'stock_key'=p_stock and u->>'device_id'=p_device::text),'[]')end);
 return result;
end;$$;
create or replace function public.get_stock_parts_cost_v1(p_filters jsonb default '{}',p_stock text default null,p_device uuid default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.scp_access(coalesce(p_filters,'{}'));return greenloop_private.scp_data(coalesce(p_filters,'{}'),p_stock,p_device);end;$$;

do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_stock_parts_cost_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select string_agg('$'||i,','order by i)into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;

revoke all on function greenloop_private.scp_access(jsonb),greenloop_private.scp_data(jsonb,text,uuid),greenloop_private.scp_totals(jsonb)from public,anon,authenticated;
create table if not exists greenloop_private.stock_parts_cost_installation(identity text primary key,hash text not null);alter table greenloop_private.stock_parts_cost_installation enable row level security;revoke all on greenloop_private.stock_parts_cost_installation from public,anon,authenticated;
create or replace function public.get_stock_parts_cost_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_pending_parts_prices_version()='20261030-pending-parts-prices-1'
 and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.stock_parts_cost_installation where identity<>'catalog')
 and exists(select 1 from greenloop_private.stock_parts_cost_installation where identity='catalog'and hash=(select md5(c::text)from greenloop_private.page_capability_catalog p,jsonb_array_elements(p.capabilities)c where page_key='reports'and c->>'key'='stock_parts_cost'))
 and not exists(select 1 from greenloop_private.stock_parts_cost_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_function_privilege('anon','public.get_stock_parts_cost_v1(jsonb,text,uuid)','EXECUTE')and has_function_privilege('authenticated','public.get_stock_parts_cost_v1(jsonb,text,uuid)','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.stock_parts_cost_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.stock_parts_cost_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.stock_parts_cost_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261030-stock-parts-cost-1'end;$$;
revoke all on function public.get_stock_parts_cost_version()from public;grant execute on function public.get_stock_parts_cost_version()to anon,authenticated;
insert into greenloop_private.stock_parts_cost_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname in('scp_access','scp_totals','scp_data')or p.pronamespace='public'::regnamespace and p.proname in('get_stock_parts_cost_v1','get_stock_parts_cost_version')or p.oid=(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_stock_parts_cost_v1(jsonb,text,uuid)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.stock_parts_cost_installation values('catalog',(select md5(c::text)from greenloop_private.page_capability_catalog p,jsonb_array_elements(p.capabilities)c where page_key='reports'and c->>'key'='stock_parts_cost'))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_stock_parts_cost_version()is distinct from '20261030-stock-parts-cost-1'then raise exception 'Stock Parts Cost verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_stock_parts_cost_version()as installed_stock_parts_cost_version;
