-- Canonical receipt balances and simplified pending-price groups. No business rows are changed.
begin;
do $$begin
 if public.get_qc_issuance_version()is distinct from '20261104-qc-inspection-issuance-1'then raise exception 'Verify QC Inspection and Issuance first.';end if;
 if public.get_pending_parts_prices_version()is distinct from '20261030-pending-parts-prices-1'or public.get_stock_grade_analysis_version()is distinct from '20261104-stock-grade-analysis-1'or public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'then raise exception 'Verify existing Parts Prices, Stock Analysis and Replacement first.';end if;
 if to_regprocedure('public.get_stock_consistency_version()')is not null then if public.get_stock_consistency_version()is distinct from '20261105-stock-consistency-1'then raise exception 'Existing stock consistency requires review.';end if;end if;
end;$$;
CREATE OR REPLACE FUNCTION greenloop_private.ppp_units()
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 with base as(
 select i.id issue_id,i.part_request_id request_id,o.id order_id,o.job_id,d.id device_id,d.imei_1 imei,
  coalesce(b.supplier_id,j.supplier_id)::text supplier_id,coalesce(s.supplier_code,'Not recorded')supplier_code,
  coalesce(b.id::text,'legacy:'||j.id::text)batch_id,coalesce(b.batch_number,'Legacy phone '||d.imei_1)batch_number,coalesce(nullif(btrim(b.invoice_number),''),'Not recorded')invoice_number,
  coalesce(nullif(btrim(d.model),''),'Unspecified')model,d.storage_gb,
  case when d.storage_gb in(1024,2048)then(d.storage_gb/1024)::text||' TB'when d.storage_gb is not null then d.storage_gb::text||' GB'else 'Not recorded'end storage_label,
  coalesce(nullif(btrim(d.color),''),'Not recorded')color,r.part_name,
  i.quantity_issued::integer quantity,i.quantity_returned::integer returned_quantity,i.issued_at,timezone('Asia/Dubai',i.issued_at)::date::text issued_day,
  coalesce(src.source,'unrecorded')source,coalesce(src.id,0)source_revision,coalesce(p.currency,'AED')currency,
  p.issue_id price_record_id
 from public.part_issue_transactions i join public.job_part_requests r on r.id=i.part_request_id
 join greenloop_private.parts_flow_requests m on m.request_id=r.id join greenloop_private.parts_flow_orders o on o.id=m.order_id
 join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null
 left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=coalesce(b.supplier_id,j.supplier_id)
 left join greenloop_private.parts_flow_prices p on p.issue_id=i.id
 left join lateral(select source,id from greenloop_private.parts_issue_sources where issue_id=i.id order by id desc limit 1)src on true
 where i.quantity_issued>0 and p.unit_price is null and(p.issue_id is not null or i.unit_cost is null or i.issue_notes like 'Issued by Parts Flow;%')
 ), keyed as(select to_jsonb(b)||jsonb_build_object('model_key',regexp_replace(greenloop_private.ppp_norm(model),'^(apple\s+)?iphone\s*','',''),'color_key',greenloop_private.ppp_norm(color),'part_key',greenloop_private.ppp_norm(part_name))u from base b)
 select u||jsonb_build_object('group_id',md5(jsonb_build_array(u->'supplier_id',u->'batch_id',u->'invoice_number',u->'model_key',u->'part_key',u->'source',u->'currency')::text))from keyed;
$function$
;
CREATE OR REPLACE FUNCTION greenloop_private.ppp_report(p_filters jsonb, p_group text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare f jsonb:=coalesce(p_filters,'{}');units jsonb;matched jsonb;groups jsonb;selected jsonb;facets jsonb:='{}';k text;value_key text;label_key text;options jsonb;result jsonb;
begin
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['query','supplier_id','batch_id','invoice_number','model','part_name','source','currency','issued_day','quantity','phones','returned_quantity'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Use valid pending-price filters.'using errcode='22023';end if;
 if p_group is not null and p_group!~'^[a-f0-9]{32}$'then raise exception 'Select a current pending-price group.'using errcode='22023';end if;
 select coalesce(jsonb_agg(u order by u->>'issue_id'),'[]')into units from greenloop_private.ppp_units()u;
 select coalesce(jsonb_agg(u order by u->>'issue_id'),'[]')into matched from jsonb_array_elements(units)u where greenloop_private.ppp_matches(u,f);
 select coalesce(jsonb_agg(to_jsonb(g)order by g.supplier_code,g.batch_number,g.model,g.storage_gb,g.color,g.part_name,g.source),'[]')into groups from(
 select u->>'group_id'group_id,min(u->>'supplier_id')supplier_id,min(u->>'supplier_code')supplier_code,min(u->>'batch_id')batch_id,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,
  min(u->>'model')model,min(u->>'model_key')model_key,min((u->>'storage_gb')::integer)storage_gb,min(u->>'storage_label')storage_label,min(u->>'color')color,min(u->>'color_key')color_key,min(u->>'part_name')part_name,min(u->>'part_key')part_key,min(u->>'source')source,min(u->>'currency')currency,
  sum((u->>'quantity')::integer)::integer quantity,sum((u->>'returned_quantity')::integer)::integer returned_quantity,count(distinct u->>'device_id')::integer phones,count(*)::integer issue_count,
  min(u->>'issued_day')first_issued_day,max(u->>'issued_day')last_issued_day,
  md5(jsonb_agg(u order by u->>'issue_id')::text)selection_token
 from jsonb_array_elements(matched)u group by u->>'group_id')g;
 select coalesce(jsonb_agg(g),'[]')into selected from jsonb_array_elements(groups)g where(coalesce(f->>'quantity','')=''or g->>'quantity'=f->>'quantity')and(coalesce(f->>'phones','')=''or g->>'phones'=f->>'phones')and(coalesce(f->>'returned_quantity','')=''or g->>'returned_quantity'=f->>'returned_quantity');
 foreach k in array array['supplier_id','batch_id','invoice_number','model','part_name','source','currency','issued_day','quantity','phones','returned_quantity']loop
  value_key:=case k when 'model'then 'model_key'when 'color'then 'color_key'when 'part_name'then 'part_key'else k end;
  label_key:=case k when 'supplier_id'then 'supplier_code'when 'batch_id'then 'batch_number'when 'storage_gb'then 'storage_label'else k end;
  select coalesce(jsonb_agg(jsonb_build_object('value',v,'label',label)order by label),'[]')into options from(
   select coalesce(u->>value_key,'Not recorded')v,min(coalesce(u->>label_key,'Not recorded'))label from jsonb_array_elements(case when k in('quantity','phones','returned_quantity')then groups else units end)u group by coalesce(u->>value_key,'Not recorded'))x;
  if k='source'then options:='[{"value":"local","label":"Local"},{"value":"china","label":"China"},{"value":"unrecorded","label":"Not recorded"}]';end if;
  facets:=facets||jsonb_build_object(k,options);
 end loop;
 result:=jsonb_build_object('rows',selected,'facets',facets,'generated_at',now(),'overall_summary',jsonb_build_object('phones',(select count(distinct u->>'device_id')from jsonb_array_elements(units)u),'quantity',(select coalesce(sum((u->>'quantity')::integer),0)from jsonb_array_elements(units)u)), 'summary',jsonb_build_object('groups',jsonb_array_length(selected),
  'phones',(select count(distinct u->>'device_id')from jsonb_array_elements(matched)u where exists(select 1 from jsonb_array_elements(selected)g where g->>'group_id'=u->>'group_id')),
  'quantity',(select coalesce(sum((g->>'quantity')::integer),0)from jsonb_array_elements(selected)g),
  'returned_quantity',(select coalesce(sum((g->>'returned_quantity')::integer),0)from jsonb_array_elements(selected)g)),
  'details',case when p_group is null then '[]'::jsonb else coalesce((select jsonb_agg(u order by u->>'imei',u->>'issued_at',u->>'issue_id')from jsonb_array_elements(matched)u where u->>'group_id'=p_group and exists(select 1 from jsonb_array_elements(selected)g where g->>'group_id'=p_group)),'[]')end);
 return result;
end;$function$
;

create or replace function greenloop_private.sc_receipts()returns table(batch_id uuid,parent_batch_id uuid,supplier_id uuid,supplier_code text,supplier_name text,batch_number text,invoice_number text,received_at timestamptz,received_quantity bigint,returned_quantity bigint,replacement_quantity bigint,balance_quantity bigint,return_pending bigint,descendant_ids uuid[])language sql stable security definer set search_path=pg_catalog,public as $$
 with recursive edges as materialized(select x.original_batch_id parent,x.replacement_batch_id child,x.quantity from greenloop_private.srp_receipts x join public.receiving_batches b on b.id=x.replacement_batch_id),tree as(
 select b.id root,b.id node,array[b.id]path,0::bigint replacement from public.receiving_batches b
 union all select t.root,e.child,t.path||e.child,e.quantity::bigint from tree t join edges e on e.parent=t.node where not e.child=any(t.path)
 ),ret as materialized(select batch_id,count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))filter(where status='returned')done,count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))filter(where status in('requested','approved'))pending from public.supplier_returns where archived_at is null group by batch_id),roll as(
 select t.root,sum(t.replacement)replacement,coalesce(sum(ret.done),0)done,coalesce(sum(ret.pending),0)pending,array_agg(distinct t.node)ids from tree t left join ret on ret.batch_id=t.node group by t.root)
 select b.id,(select e.parent from edges e where e.child=b.id limit 1),b.supplier_id,s.supplier_code,case when coalesce(public.get_my_partner_name_access(),false)then s.company_name end,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity::bigint,x.done::bigint,x.replacement::bigint,(b.planned_quantity-x.done+x.replacement)::bigint,x.pending::bigint,x.ids
 from public.receiving_batches b join roll x on x.root=b.id left join public.suppliers s on s.id=b.supplier_id;
$$;
create or replace function greenloop_private.sc_summary(ids uuid[])returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with chosen as materialized(select *from greenloop_private.sc_receipts()where batch_id=any(coalesce(ids,array[]::uuid[]))),roots as(select c.*from chosen c where not exists(select 1 from chosen p where p.batch_id<>c.batch_id and c.batch_id=any(p.descendant_ids)))
 select jsonb_build_object('received',case when count(received_quantity)<count(*)then null else coalesce(sum(received_quantity),0)end,'returned',coalesce(sum(returned_quantity),0),'replacement_received',coalesce(sum(replacement_quantity),0),'balance',case when count(balance_quantity)<count(*)then null else coalesce(sum(balance_quantity),0)end,'return_pending',coalesce(sum(return_pending),0),'receipts',count(*))from roots;
$$;
create or replace function public.get_stock_receipt_catalog_v1(p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if p_page is null or p_page<>all(array['overview','stock_received','imei_entry','initial_qc','lab_glass','parts','final_qc','frame_department','ready_stock','export_boxes','stock_exported','ready_stock_journey','imei_search','accounts','supplier_returns','supplier_return_approval','supplier_return_handover','reports'])then raise exception 'Stock page access is required.'using errcode='42501';end if;
 perform greenloop_private.pf_cap(p_page,'view');
 if p_page='reports'and not exists(select 1 from greenloop_private.report_access_sections s where s.report_key=any(array['overview','stock_received','complete_device_details','supplier_progress','work_in_progress','parts_requests','parts_inventory','technicians','final_qc','costs','stock_parts_cost','export_boxes','stock_return','data_correction','stock_grade_analysis'])and public.has_page_capability_v1('reports',s.config->>'view'))then return '[]';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)order by received_at,batch_id)from greenloop_private.sc_receipts()x),'[]');
end;$$;
CREATE OR REPLACE FUNCTION greenloop_private.sga_report(f jsonb, download boolean, expected text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);catalogue jsonb;stocks jsonb;rows jsonb;totals jsonb;other jsonb;selected boolean;result jsonb;snapshot text;
begin
 selected:=exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null);
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity stock_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id)
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by received_at desc,batch_id)from b),'[]'))into catalogue;
 select coalesce(jsonb_agg(b order by b->>'batch_number'),'[]')into stocks from jsonb_array_elements(catalogue->'batches')b where selected and(nullif(f->>'supplier_id','')is null or b->>'supplier_id'=f->>'supplier_id')and(nullif(f->>'batch_id','')is null or b->>'batch_id'=f->>'batch_id')and(nullif(f->>'invoice_number','')is null or b->>'invoice_number'=f->>'invoice_number');
 if selected and jsonb_array_length(stocks)=0 then raise exception 'No stock matches this supplier, batch and invoice. Refresh the selection.'using errcode='22023';end if;
 if selected then
  with p as materialized(select *from greenloop_private.sga_rows(f)),groups as(
   select p.model,count(*)qty,count(*)filter(where not qc_pending and grade='A')a,count(*)filter(where not qc_pending and grade='B')b,count(*)filter(where not qc_pending and grade='D')d,
    count(*)filter(where not qc_pending and grade not in('A','B','D'))other,count(*)filter(where qc_pending)pending,count(*)filter(where glass)glass,count(*)filter(where polish)polish,count(*)filter(where returned)returned
   from p group by p.model
  )select coalesce((select jsonb_agg(to_jsonb(g)order by model)from groups g),'[]'),jsonb_build_object('qty',count(*),'a',count(*)filter(where not qc_pending and grade='A'),'b',count(*)filter(where not qc_pending and grade='B'),'d',count(*)filter(where not qc_pending and grade='D'),'other',count(*)filter(where not qc_pending and grade not in('A','B','D')),'pending',count(*)filter(where qc_pending),'glass',count(*)filter(where glass),'polish',count(*)filter(where polish),'returned',count(*)filter(where returned)),
   coalesce((select jsonb_agg(to_jsonb(x)order by grade)from(select grade,count(*)qty from p where not qc_pending and grade not in('A','B','D')group by grade)x),'[]')into rows,totals,other from p;
 else rows:='[]';totals:='{"qty":0,"a":0,"b":0,"d":0,"other":0,"pending":0,"glass":0,"polish":0,"returned":0}';other:='[]';end if;
 totals:=totals||jsonb_build_object('stock_quantity',coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0),'unentered',greatest(0,coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0)-(totals->>'qty')::bigint));
 result:=jsonb_build_object('receipt_summary',greenloop_private.sc_summary(array(select(s->>'batch_id')::uuid from jsonb_array_elements(stocks)s)),'selected',selected,'filters',f,'stocks',stocks,'rows',rows,'totals',totals,'other_grades',other,'names_allowed',names);
 snapshot:=md5(result::text);
 if download and(expected is null or expected is distinct from snapshot)then raise exception 'The stock analysis changed. Refresh it before creating the PDF.'using errcode='40001';end if;
 return result||jsonb_build_object('catalogue',catalogue,'snapshot',snapshot,'generated_at',now());
end;$function$
;

-- Register this read with the same page-view grants; names remain separately guarded.
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_stock_receipt_catalog_v1','{"dynamic":"filter_source","parameter":"p_page","overview":{"page":"overview","capability":"view","read":true},"reports":{"page":"reports","capability":"view","read":true},"initial_qc":{"page":"initial_qc","capability":"view","read":true},"final_qc":{"page":"final_qc","capability":"view","read":true},"lab_glass":{"page":"lab_glass","capability":"view","read":true},"parts":{"page":"parts","capability":"view","read":true},"frame_department":{"page":"frame_department","capability":"view","read":true},"stock_received":{"page":"stock_received","capability":"view","read":true},"imei_entry":{"page":"imei_entry","capability":"view","read":true},"ready_stock":{"page":"ready_stock","capability":"view","read":true},"export_boxes":{"page":"export_boxes","capability":"view","read":true},"accounts":{"page":"accounts","capability":"view","read":true},"imei_search":{"page":"imei_search","capability":"view","read":true},"stock_exported":{"page":"stock_exported","capability":"view","read":true},"ready_stock_journey":{"page":"ready_stock_journey","capability":"view","read":true},"supplier_returns":{"page":"supplier_returns","capability":"view","read":true},"supplier_return_approval":{"page":"supplier_return_approval","capability":"view","read":true},"supplier_return_handover":{"page":"supplier_return_handover","capability":"view","read":true}}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;body text;begin
 select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature into f from pg_proc p where p.oid='public.get_stock_receipt_catalog_v1(text)'::regprocedure;
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'(text)';execute replace(f.ddl,'FUNCTION public.get_stock_receipt_catalog_v1(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||E'($1);\nend;';execute format('create or replace function public.get_stock_receipt_catalog_v1(p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as %L',body);
 insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
end;$wrap$;
revoke all on function public.get_stock_receipt_catalog_v1(text)from public,anon;grant execute on function public.get_stock_receipt_catalog_v1(text)to authenticated;
revoke all on function greenloop_private.sc_receipts(),greenloop_private.sc_summary(uuid[])from public,anon,authenticated;
do $seal$declare ids regprocedure[]:=array['greenloop_private.ppp_units()'::regprocedure,'greenloop_private.ppp_report(jsonb,text)'::regprocedure,'greenloop_private.sga_report(jsonb,boolean,text)'::regprocedure];t record;begin
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using ids;end loop;
end;$seal$;

create table if not exists greenloop_private.stock_consistency_installation(identity text primary key,hash text not null);alter table greenloop_private.stock_consistency_installation enable row level security;revoke all on greenloop_private.stock_consistency_installation from public,anon,authenticated;
create or replace function public.get_stock_consistency_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_qc_issuance_version()='20261104-qc-inspection-issuance-1'and public.get_pending_parts_prices_version()='20261030-pending-parts-prices-1'and public.get_stock_grade_analysis_version()='20261104-stock-grade-analysis-1'and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.stock_consistency_installation)and not has_function_privilege('anon','public.get_stock_receipt_catalog_v1(text)','execute')then '20261105-stock-consistency-1'end;$$;
revoke all on function public.get_stock_consistency_version()from public;grant execute on function public.get_stock_consistency_version()to anon,authenticated;
insert into greenloop_private.stock_consistency_installation select x,md5(pg_get_functiondef(x::regprocedure))from unnest(array['greenloop_private.ppp_units()','greenloop_private.ppp_report(jsonb,text)','greenloop_private.sc_receipts()','greenloop_private.sc_summary(uuid[])','public.get_stock_receipt_catalog_v1(text)','greenloop_private.sga_report(jsonb,boolean,text)','public.get_stock_consistency_version()'])x on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.stock_consistency_installation select implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines where to_regprocedure(identity)='public.get_stock_receipt_catalog_v1(text)'::regprocedure on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_stock_consistency_version()is distinct from '20261105-stock-consistency-1'then raise exception 'Stock consistency integrity failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_stock_consistency_version()installed_stock_consistency_version;
