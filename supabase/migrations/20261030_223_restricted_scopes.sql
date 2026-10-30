-- Targeted operational deletion. Installation never deletes business records.
begin;
do $$begin
 if public.get_qc_direct_parts_version()is distinct from '20261029-qc-direct-parts-1' then raise exception 'Install and verify Initial QC direct Parts before Restricted Data scopes.'using errcode='55000';end if;
end;$$;

create table if not exists greenloop_private.restricted_scope_archive(
 audit_id uuid primary key references public.deletion_history(id),private_records jsonb not null,created_at timestamptz not null default now());
alter table greenloop_private.restricted_scope_archive enable row level security;
revoke all on greenloop_private.restricted_scope_archive from public,anon,authenticated;

create or replace function greenloop_private.rds_access(p_scope text)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare cap text;
begin
 perform greenloop_private.require_office_network();
 cap:=case p_scope when 'supplier'then 'delete_supplier'when 'invoice'then 'delete_invoice'when 'batch'then 'delete_batch'when 'imei_list'then 'delete_imei_list'end;
 if cap is null then raise exception 'Choose Supplier, Invoice, Stock/Batch or multiple IMEIs.'using errcode='22023';end if;
 if auth.uid()is null or not public.is_active_staff()or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_edit_access('reports'),false)or not coalesce(public.has_page_capability_v1('reports',cap),false)then raise exception 'Permission is required for this deletion scope.'using errcode='42501';end if;
 if not public.has_role(case when p_scope='imei_list'then array['owner','super_admin','manager']::public.app_role_key[]else array['owner','super_admin']::public.app_role_key[]end)then raise exception 'Only an Owner or Super Admin can delete a supplier, invoice or batch; Managers may delete an authorised IMEI list.'using errcode='42501';end if;
end;$$;

create or replace function greenloop_private.rds_resolve(p_scope text,p_selection jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_supplier uuid;v_id uuid;v_invoice text;v_batches uuid[]:='{}';v_devices uuid[]:='{}';v_imeis text[];v_supplier_row jsonb;v_archive boolean:=false;v_label text;v_confirmation text;v_normalized jsonb;v_allowed text[];
begin
 perform greenloop_private.rds_access(p_scope);
 if jsonb_typeof(p_selection)is distinct from 'object'then raise exception 'Choose an exact deletion selection.'using errcode='22023';end if;
 v_allowed:=case p_scope when 'supplier'then array['supplier_id','archive_supplier']when 'invoice'then array['supplier_id','invoice_number']when 'batch'then array['batch_id']else array['imeis']end;
 if exists(select 1 from jsonb_object_keys(p_selection)k where not k=any(v_allowed))then raise exception 'Unknown deletion selection field.'using errcode='22023';end if;
 if p_scope in('supplier','invoice')then
  if not p_selection?'supplier_id'or(p_scope='supplier'and coalesce(p_selection->>'supplier_id','')='')then raise exception 'Choose a supplier.'using errcode='22023';end if;
  if p_selection->>'supplier_id'is not null then
   if p_selection->>'supplier_id'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then raise exception 'Choose a valid supplier.'using errcode='22023';end if;
   v_supplier:=(p_selection->>'supplier_id')::uuid;select to_jsonb(s)into v_supplier_row from public.suppliers s where id=v_supplier;
   if v_supplier_row is null then raise exception 'The selected supplier no longer exists.'using errcode='22023';end if;
  end if;
 end if;
 if p_scope='supplier'then
  if p_selection?'archive_supplier'and jsonb_typeof(p_selection->'archive_supplier')<>'boolean'then raise exception 'Choose whether to remove the supplier from new receipts.'using errcode='22023';end if;
  v_archive:=coalesce((p_selection->>'archive_supplier')::boolean,true);
  select coalesce(array_agg(id order by id),'{}')into v_batches from public.receiving_batches where supplier_id=v_supplier;
  select coalesce(array_agg(distinct device_id order by device_id),'{}')into v_devices from public.jobs where supplier_id=v_supplier or receiving_batch_id=any(v_batches);
  if exists(select 1 from public.jobs j where j.device_id=any(v_devices)and not(coalesce(j.supplier_id=v_supplier,false)or coalesce(j.receiving_batch_id=any(v_batches),false)))then raise exception 'A selected phone also belongs to another supplier. Review its complete IMEI workflow before deleting this supplier.'using errcode='55000';end if;
  if exists(select 1 from public.jobs j where j.device_id=any(v_devices)and j.supplier_id is not null and j.supplier_id<>v_supplier)then raise exception 'A selected phone has a conflicting supplier assignment. Review its complete IMEI workflow before deleting this supplier.'using errcode='55000';end if;
  if exists(select 1 from public.jobs j join public.receiving_batches b on b.id=j.receiving_batch_id where j.device_id=any(v_devices)and b.supplier_id is distinct from v_supplier)then raise exception 'A selected phone is linked to another supplier receipt. No records deleted.'using errcode='55000';end if;
  v_label:='Supplier '||(v_supplier_row->>'supplier_code');v_confirmation:='DELETE SUPPLIER '||(v_supplier_row->>'supplier_code');v_normalized:=jsonb_build_object('supplier_id',v_supplier,'archive_supplier',v_archive);
 elsif p_scope='invoice'then
  v_invoice:=nullif(btrim(p_selection->>'invoice_number'),'');if v_invoice is null or length(v_invoice)>120 or v_invoice~'[[:cntrl:]]'then raise exception 'Choose a complete invoice number.'using errcode='22023';end if;
  select coalesce(array_agg(id order by id),'{}')into v_batches from public.receiving_batches where supplier_id is not distinct from v_supplier and btrim(invoice_number)=v_invoice;
  if cardinality(v_batches)=0 then raise exception 'No receipts match this invoice and supplier.'using errcode='22023';end if;
  select coalesce(array_agg(distinct device_id order by device_id),'{}')into v_devices from public.jobs where receiving_batch_id=any(v_batches);
  v_label:='Invoice '||v_invoice||' | '||coalesce(v_supplier_row->>'supplier_code','No supplier');v_confirmation:='DELETE INVOICE '||v_invoice||' '||coalesce(v_supplier_row->>'supplier_code','NO SUPPLIER');v_normalized:=jsonb_build_object('supplier_id',v_supplier,'invoice_number',v_invoice);
 elsif p_scope='batch'then
  if coalesce(p_selection->>'batch_id','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then raise exception 'Choose a valid Stock/Batch.'using errcode='22023';end if;
  v_id:=(p_selection->>'batch_id')::uuid;select batch_number into v_label from public.receiving_batches where id=v_id;if v_label is null then raise exception 'The selected Stock/Batch no longer exists.'using errcode='22023';end if;
  v_batches:=array[v_id];select coalesce(array_agg(distinct device_id order by device_id),'{}')into v_devices from public.jobs where receiving_batch_id=v_id;
  v_confirmation:='DELETE BATCH '||v_label;v_label:='Stock/Batch '||v_label;v_normalized:=jsonb_build_object('batch_id',v_id);
 else
  if jsonb_typeof(p_selection->'imeis')is distinct from 'array'or jsonb_array_length(p_selection->'imeis')not between 1 and 5000 then raise exception 'Paste between 1 and 5,000 complete IMEIs.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_selection->'imeis')v where jsonb_typeof(v)<>'string'or(v#>>'{}')!~'^[0-9]{15}$')then raise exception 'Every IMEI must contain exactly 15 digits.'using errcode='22023';end if;
  select array_agg(distinct value order by value)into v_imeis from jsonb_array_elements_text(p_selection->'imeis');
  if exists(select 1 from unnest(v_imeis)i left join public.devices d on d.imei_1=i or d.imei_2=i group by i having count(d.id)<>1)then raise exception 'An IMEI is missing or matches more than one phone. Check the list; no records deleted.'using errcode='22023';end if;
  select array_agg(id order by id)into v_devices from public.devices where imei_1=any(v_imeis)or imei_2=any(v_imeis);
  v_label:='IMEI list | '||cardinality(v_devices)||' phones';v_confirmation:='DELETE '||cardinality(v_devices)||' IMEIS';v_normalized:=jsonb_build_object('imeis',to_jsonb(v_imeis));
 end if;
 if p_scope in('invoice','batch')and exists(select 1 from public.jobs j join public.receiving_batches b on b.id=j.receiving_batch_id where j.device_id=any(v_devices)and j.supplier_id is not null and b.supplier_id is not null and j.supplier_id<>b.supplier_id)then raise exception 'A selected receipt contains a conflicting supplier assignment. Review its complete IMEI workflow before deletion.'using errcode='55000';end if;
 if p_scope in('invoice','batch')and exists(select 1 from public.jobs j where j.device_id=any(v_devices)and(j.receiving_batch_id is null or not j.receiving_batch_id=any(v_batches)))then raise exception 'A selected phone also belongs to another receipt. Review its complete IMEI workflow before deleting this invoice or batch.'using errcode='55000';end if;
 return jsonb_build_object('selection',v_normalized,'devices',v_devices,'batches',v_batches,'label',v_label,'confirmation',v_confirmation,'supplier_archive_before',case when v_archive and coalesce((v_supplier_row->>'is_active')::boolean,false)then jsonb_build_array(v_supplier_row)else '[]'::jsonb end);
end;$$;

create or replace function greenloop_private.rds_private_tables()returns text[]language sql immutable set search_path=pg_catalog as $$select array['qc_direct_parts_orders','parts_reorder_sources','parts_flow_returns','parts_flow_prices','parts_flow_requests','lab_only_services','parts_flow_orders']::text[];$$;

create or replace function public.get_restricted_scope_options_v1(p_scope text,p_query text default '',p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;names boolean;query text;
begin
 perform greenloop_private.rds_access(p_scope);if p_scope='imei_list'then return jsonb_build_object('rows','[]'::jsonb,'has_more',false);end if;
 if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 or length(coalesce(p_query,''))>200 then raise exception 'Choose a valid search and result page.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);query:='%'||btrim(coalesce(p_query,''))||'%';
 if p_scope='supplier'then
  select coalesce(jsonb_agg(row order by code,id),'[]')into result from(select s.supplier_code code,s.id,jsonb_build_object('selection',jsonb_build_object('supplier_id',s.id),'label',s.supplier_code||case when names then ' | '||s.company_name else ''end||case when s.deleted_at is not null or not s.is_active then ' (archived)'else ''end)row from public.suppliers s where(s.is_active or exists(select 1 from public.receiving_batches b where b.supplier_id=s.id)or exists(select 1 from public.jobs j where j.supplier_id=s.id))and(s.supplier_code ilike query or names and s.company_name ilike query)order by s.supplier_code,s.id offset p_offset limit p_limit+1)q;
 elsif p_scope='invoice'then
  select coalesce(jsonb_agg(row order by invoice,code,supplier_id),'[]')into result from(select btrim(b.invoice_number)invoice,coalesce(s.supplier_code,'No supplier')code,b.supplier_id,jsonb_build_object('selection',jsonb_build_object('supplier_id',b.supplier_id,'invoice_number',btrim(b.invoice_number)),'label',btrim(b.invoice_number)||' | '||coalesce(s.supplier_code,'No supplier')||case when names and s.company_name is not null then ' | '||s.company_name else ''end||' | '||count(*)||' batch(es)')row from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where nullif(btrim(b.invoice_number),'')is not null and(b.invoice_number ilike query or s.supplier_code ilike query or names and s.company_name ilike query)group by btrim(b.invoice_number),b.supplier_id,s.supplier_code,s.company_name order by btrim(b.invoice_number),coalesce(s.supplier_code,'No supplier'),b.supplier_id offset p_offset limit p_limit+1)q;
 else
  select coalesce(jsonb_agg(row order by code,id),'[]')into result from(select b.batch_number code,b.id,jsonb_build_object('selection',jsonb_build_object('batch_id',b.id),'label',b.batch_number||' | '||coalesce(b.invoice_number,'No invoice')||' | '||coalesce(s.supplier_code,'No supplier')||case when names and s.company_name is not null then ' | '||s.company_name else ''end||' | '||coalesce(to_char(timezone('Asia/Dubai',b.received_at),'DD Mon YYYY'),'Date unavailable'))row from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where b.batch_number ilike query or b.invoice_number ilike query or s.supplier_code ilike query or names and s.company_name ilike query order by b.batch_number,b.id offset p_offset limit p_limit+1)q;
 end if;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by ord),'[]')from jsonb_array_elements(result)with ordinality q(value,ord)where ord<=p_limit),'has_more',jsonb_array_length(result)>p_limit,'next_offset',p_offset+p_limit);
end;$$;

create or replace function greenloop_private.rds_private_records(p_devices uuid[],p_jobs uuid[],p_requests uuid[])returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb:='{}';orders uuid[];returns_ids uuid[];t text;items jsonb;fk record;crossed boolean;
begin
 for t in select unnest(greenloop_private.rds_private_tables()||array['parts_flow_audit','lab_only_services_audit'])order by 1 loop execute format('lock table greenloop_private.%I in share row exclusive mode',t);end loop;
 if exists(select 1 from greenloop_private.parts_flow_orders where(device_id=any(p_devices)or job_id=any(p_jobs))and not(device_id=any(p_devices)and job_id=any(p_jobs)))then raise exception 'A Parts order crosses the selected phone records. No records deleted.'using errcode='55000';end if;
 select coalesce(array_agg(id order by id),'{}')into orders from greenloop_private.parts_flow_orders where job_id=any(p_jobs);
 select coalesce(array_agg(id order by id),'{}')into returns_ids from greenloop_private.parts_flow_returns where order_id=any(orders);
 if exists(select 1 from greenloop_private.parts_reorder_sources where return_id=any(returns_ids)and not request_id=any(p_requests))then raise exception 'A replacement order crosses the selected phones. No records deleted.'using errcode='55000';end if;
 foreach t in array greenloop_private.rds_private_tables()||array['parts_flow_audit','lab_only_services_audit']loop
  if t='parts_flow_orders'then execute format('select coalesce(jsonb_agg(to_jsonb(t)order by to_jsonb(t)::text),''[]'')from greenloop_private.%I t where id=any($1)',t)into items using orders;
  elsif t in('lab_only_services','lab_only_services_audit')then execute format('select coalesce(jsonb_agg(to_jsonb(t)order by to_jsonb(t)::text),''[]'')from greenloop_private.%I t where job_id=any($1)',t)into items using p_jobs;
  elsif t='parts_reorder_sources'then select coalesce(jsonb_agg(to_jsonb(s)order by to_jsonb(s)::text),'[]')into items from greenloop_private.parts_reorder_sources s where request_id=any(p_requests)or return_id=any(returns_ids);
  else execute format('select coalesce(jsonb_agg(to_jsonb(t)order by to_jsonb(t)::text),''[]'')from greenloop_private.%I t where order_id=any($1)',t)into items using orders;end if;
  result:=result||jsonb_build_object(t,items);
 end loop;
 for fk in select c.oid,child.relname child_table,ns.nspname child_schema,parent.relname parent_table from pg_constraint c join pg_class parent on parent.oid=c.confrelid join pg_class child on child.oid=c.conrelid join pg_namespace ns on ns.oid=child.relnamespace where c.contype='f'and parent.relnamespace='greenloop_private'::regnamespace and parent.relname=any(greenloop_private.rds_private_tables())loop
  if fk.child_schema<>'greenloop_private'or not fk.child_table=any(greenloop_private.rds_private_tables())then raise exception 'Unreviewed dependency % -> %. No records deleted.',fk.child_table,fk.parent_table using errcode='55000';end if;
 end loop;
 for fk in select child.relname child_table,parent.relname parent_table,string_agg(format('to_jsonb(t)->%L=r->%L',ca.attname,pa.attname),' and 'order by k.ord)predicate from pg_constraint c join pg_class child on child.oid=c.conrelid join pg_class parent on parent.oid=c.confrelid cross join lateral unnest(c.conkey,c.confkey)with ordinality k(child_att,parent_att,ord)join pg_attribute ca on ca.attrelid=c.conrelid and ca.attnum=k.child_att join pg_attribute pa on pa.attrelid=c.confrelid and pa.attnum=k.parent_att where c.contype='f'and child.relnamespace='greenloop_private'::regnamespace and parent.relnamespace='greenloop_private'::regnamespace and child.relname=any(greenloop_private.rds_private_tables())and parent.relname=any(greenloop_private.rds_private_tables())group by c.oid,child.relname,parent.relname loop
  execute format('select exists(select 1 from greenloop_private.%I t where exists(select 1 from jsonb_array_elements($1)r where %s)and not exists(select 1 from jsonb_array_elements($2)r where r=to_jsonb(t)))',fk.child_table,fk.predicate)into crossed using coalesce(result->fk.parent_table,'[]'),coalesce(result->fk.child_table,'[]');
  if crossed then raise exception 'Unreviewed private cross-link % -> %. No records deleted.',fk.child_table,fk.parent_table using errcode='55000';end if;
 end loop;
 return result;
end;$$;

create or replace function greenloop_private.rds_cleanup(p_plan jsonb)returns bigint language plpgsql security definer set search_path=pg_catalog,public as $$
declare t text;items jsonb;changed bigint;total bigint:=0;
begin
 perform greenloop_private.rds_access(p_plan->>'scope');
 foreach t in array greenloop_private.rds_private_tables()loop
  items:=coalesce(p_plan->'private_records'->t,'[]');
  execute format('delete from greenloop_private.%I t where exists(select 1 from jsonb_array_elements($1)r where r=to_jsonb(t))',t)using items;
  get diagnostics changed=row_count;if changed<>jsonb_array_length(items)then raise exception 'Selected private % records changed. No changes saved.',t using errcode='40001';end if;total:=total+changed;
 end loop;
 return total;
end;$$;

create or replace function public.preview_restricted_scope_v1(p_scope text,p_selection jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare plan jsonb;counts jsonb;total bigint;private_count bigint;
begin
 plan:=greenloop_private.rds_plan(p_scope,p_selection);
 select jsonb_object_agg(key,jsonb_array_length(value)),sum(jsonb_array_length(value))into counts,total from jsonb_each(plan->'records')where key<>'data_change_history';
 select coalesce(sum(jsonb_array_length(value)),0)into private_count from jsonb_each(plan->'private_records')where key=any(greenloop_private.rds_private_tables())or key='suppliers';
 if coalesce(total,0)+private_count=0 then raise exception 'There are no operational records in this selection.'using errcode='22023';end if;
 return jsonb_build_object('scope',p_scope,'selection',plan->'selection','label',plan->>'label','confirmation',plan->>'confirmation','selection_token',md5(plan::text||auth.uid()::text),'device_count',jsonb_array_length(plan->'records'->'devices'),'job_count',jsonb_array_length(plan->'records'->'jobs'),'receipt_count',jsonb_array_length(plan->'records'->'receiving_batches'),'record_count',coalesce(total,0)+private_count,'counts',counts,'archive_supplier',jsonb_array_length(plan->'private_records'->'suppliers')>0,
  'stages',(select coalesce(jsonb_agg(jsonb_build_object('stage',stage,'count',qty)order by stage),'[]')from(select coalesce(value->>'current_status','Unknown')stage,count(*)qty from jsonb_array_elements(plan->'records'->'devices')group by 1)q),
  'devices',(select coalesce(jsonb_agg(jsonb_build_object('imei',value->>'imei_1','model',value->>'model','storage_gb',value->'storage_gb','color',value->>'color','status',value->>'current_status')order by value->>'imei_1'),'[]')from jsonb_array_elements(plan->'records'->'devices')),
  'receipts',(select coalesce(jsonb_agg(jsonb_build_object('batch_number',value->>'batch_number','invoice_number',value->>'invoice_number','supplier_code',(select supplier_code from public.suppliers where id=(value->>'supplier_id')::uuid),'planned_quantity',value->'planned_quantity')order by value->>'batch_number'),'[]')from jsonb_array_elements(plan->'records'->'receiving_batches')));
end;$$;

CREATE OR REPLACE FUNCTION greenloop_private.rds_plan(p_scope text,p_selection jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_imei text := null;resolution jsonb;explicit_batches uuid[];private_rows jsonb;
  v_devices uuid[]; v_jobs uuid[]; v_orders uuid[]; v_steps uuid[];
  v_inspections uuid[]; v_requests uuid[]; v_issues uuid[];
  v_batches uuid[]; v_boxes uuid[] := '{}'::uuid[];
  v_table text; v_rows jsonb; v_plan jsonb := '{}'::jsonb;
  v_filter text; v_fk record; v_cross_link boolean; v_workflows_before jsonb;
begin
  perform greenloop_private.rds_access(p_scope);
  perform pg_advisory_xact_lock(19920261026);
  -- The damage module has its own removal workflow and must never enter this list.
  if exists(select 1 from unnest(greenloop_private.restricted_tables()) t
    where t like 'manual_damage%' or t like 'damage_%') then
    raise exception 'Live Damage Report is excluded from the operational reset.' using errcode='55000';
  end if;
  -- Use the same serialization lock as Box Entry/Accounts before taking table locks.
  perform pg_advisory_xact_lock(16320261010);
  -- A consistent snapshot is also used at execution. Table locks prevent new
  -- children or edits between the rechecked preview and the final deletion.
  -- This intentionally briefly pauses writers, while normal reads continue.
  for v_table in select unnest(greenloop_private.restricted_tables() || array['part_inventory','part_stock_lots','part_lot_status_balances','data_change_history','deletion_history','supplier_returns','supplier_return_events','suppliers']) order by 1 loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  lock table greenloop_private.box_workflow in share row exclusive mode;

  resolution:=greenloop_private.rds_resolve(p_scope,p_selection);
  select coalesce(array_agg(value::uuid),'{}')into v_devices from jsonb_array_elements_text(resolution->'devices');
  select coalesce(array_agg(value::uuid),'{}')into explicit_batches from jsonb_array_elements_text(resolution->'batches');
  select coalesce(array_agg(id),'{}'::uuid[]) into v_jobs from public.jobs where device_id=any(v_devices);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_orders from public.job_work_orders where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_steps from public.job_work_order_steps where work_order_id=any(v_orders);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_inspections from (
    select id from public.initial_qc_inspections where job_id=any(v_jobs)
    union select id from public.final_qc_inspections where job_id=any(v_jobs)
  ) q;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_requests from public.job_part_requests where job_id=any(v_jobs);
  select coalesce(array_agg(id),'{}'::uuid[]) into v_issues from public.part_issue_transactions where part_request_id=any(v_requests);
  select coalesce(array_agg(b.id),'{}'::uuid[]) into v_batches from public.receiving_batches b
    where (b.id=any(explicit_batches) or exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and j.id=any(v_jobs)))
      and not exists(select 1 from public.jobs j where j.receiving_batch_id=b.id and not(j.id=any(v_jobs)));
  if to_regclass('public.export_boxes') is not null and to_regclass('public.export_box_items') is not null then
    select coalesce(array_agg(b.id),'{}'::uuid[]) into v_boxes from public.export_boxes b
      where (p_scope='all' or exists(select 1 from public.export_box_items i where i.box_id=b.id and (i.device_id=any(v_devices) or i.job_id=any(v_jobs))))
        and not exists(select 1 from public.export_box_items i where i.box_id=b.id and not(i.device_id=any(v_devices) or i.job_id=any(v_jobs)));
  end if;

  -- Explicit allowlist: a newly added dependency must be reviewed, rather than
  -- silently being removed by an ON DELETE CASCADE without an audit snapshot.
  for v_fk in
    select child.relname as child_table, parent.relname as parent_table
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    where c.contype='f' and pn.nspname='public'
      and parent.relname=any(greenloop_private.restricted_tables())
      and not((ns.nspname='greenloop_private' and child.relname='box_workflow'
        and parent.relname='export_boxes' and c.confdeltype='c' and c.convalidated
        and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname='box_id')]::smallint[]
        and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])
        or (ns.nspname='public' and (child.relname=any(greenloop_private.restricted_tables())
        or (child.relname='supplier_returns' and c.confdeltype='r'
          and parent.relname in ('devices','jobs','receiving_batches','stock_batch_plan_lines')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' when 'jobs' then 'job_id' when 'receiving_batches' then 'batch_id' else 'plan_line_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[])
        or (child.relname='data_change_history' and c.confdeltype='n' and parent.relname in ('devices','jobs')
          and c.conkey=array[(select attnum from pg_attribute where attrelid=c.conrelid and attname=case parent.relname when 'devices' then 'device_id' else 'job_id' end)]::smallint[]
          and c.confkey=array[(select attnum from pg_attribute where attrelid=c.confrelid and attname='id')]::smallint[]))))
  loop
    raise exception 'Unreviewed dependency % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
  end loop;

  -- No other table may be silently cascaded or detached when deleting a flow.
  for v_fk in select c.conrelid::regclass::text as child_table from pg_constraint c
    where c.contype='f' and c.confrelid='greenloop_private.box_workflow'::regclass
  loop
    raise exception 'Unreviewed dependency % -> box_workflow. No records deleted.',v_fk.child_table using errcode='55000';
  end loop;
  select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
    into v_workflows_before from greenloop_private.box_workflow w
    where p_scope='all' or exists(select 1 from public.export_box_items i
      where i.box_id=w.box_id and (i.device_id=any(v_devices) or i.job_id=any(v_jobs)));
  -- Include exact workflow rows in the reviewed token and deletion audit. A shared
  -- box survives a single-IMEI deletion; only fully removed boxes lose their flow.
  select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
    into v_rows from greenloop_private.box_workflow w where w.box_id=any(v_boxes);
  v_plan := jsonb_build_object('box_workflow',v_rows);

  foreach v_table in array greenloop_private.restricted_tables() || array['data_change_history'] loop
    if to_regclass('public.'||v_table) is null then continue; end if;
    if p_scope='all' and v_table not in ('part_stock_movements','data_change_history') then v_filter := 'true';
    elsif v_table='devices' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($1)';
    elsif v_table='receiving_batches' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($8)';
    elsif v_table='stock_batch_plan_lines' then v_filter := '(to_jsonb(t)->>''receiving_batch_id'')::uuid=any($8)';
    elsif v_table='export_boxes' then v_filter := '(to_jsonb(t)->>''id'')::uuid=any($9)';
    else
      v_filter := '(to_jsonb(t)->>''device_id'')::uuid=any($1) or (to_jsonb(t)->>''job_id'')::uuid=any($2) or (to_jsonb(t)->>''work_order_id'')::uuid=any($3) or (to_jsonb(t)->>''work_order_step_id'')::uuid=any($4) or (to_jsonb(t)->>''inspection_id'')::uuid=any($5) or (to_jsonb(t)->>''part_request_id'')::uuid=any($6) or (to_jsonb(t)->>''part_issue_id'')::uuid=any($7)';
    end if;
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from public.%I t where %s',v_table,v_filter)
      into v_rows using v_devices,v_jobs,v_orders,v_steps,v_inspections,v_requests,v_issues,v_batches,v_boxes;
    v_plan := v_plan || jsonb_build_object(v_table,v_rows);
  end loop;
  -- Detect unplanned cross-links even if a future FK uses an existing table.
  -- This includes CASCADE/SET NULL FKs which otherwise could modify extra rows.
  for v_fk in
    select child.relname as child_table,parent.relname as parent_table,
      string_agg(format('to_jsonb(t)->%L = r->%L',ca.attname,pa.attname),' and ' order by k.ord) as predicate
    from pg_constraint c join pg_class child on child.oid=c.conrelid
    join pg_namespace ns on ns.oid=child.relnamespace
    join pg_class parent on parent.oid=c.confrelid
    join pg_namespace pn on pn.oid=parent.relnamespace
    cross join lateral unnest(c.conkey,c.confkey) with ordinality k(child_att,parent_att,ord)
    join pg_attribute ca on ca.attrelid=c.conrelid and ca.attnum=k.child_att
    join pg_attribute pa on pa.attrelid=c.confrelid and pa.attnum=k.parent_att
    where c.contype='f' and ns.nspname='public' and pn.nspname='public'
      and child.relname=any(greenloop_private.restricted_tables())
      and parent.relname=any(greenloop_private.restricted_tables())
    group by c.oid,child.relname,parent.relname
  loop
    execute format('select exists(select 1 from public.%I t where exists(select 1 from jsonb_array_elements($1) r where %s) and not exists(select 1 from jsonb_array_elements($2) r where r=to_jsonb(t)))',v_fk.child_table,v_fk.predicate)
      into v_cross_link using coalesce(v_plan->v_fk.parent_table,'[]'::jsonb),coalesce(v_plan->v_fk.child_table,'[]'::jsonb);
    if v_cross_link then
      raise exception 'Unreviewed cross-link % -> %. No records deleted.',v_fk.child_table,v_fk.parent_table using errcode='55000';
    end if;
  end loop;
  private_rows:=greenloop_private.rds_private_records(v_devices,v_jobs,v_requests)||jsonb_build_object('suppliers',resolution->'supplier_archive_before');
  return jsonb_build_object('scope',p_scope,'selection',resolution->'selection','label',resolution->>'label','confirmation',resolution->>'confirmation','imei',v_imei,'records',v_plan,'private_records',private_rows,
    'box_workflow_before',v_workflows_before,
    'supplier_returns_to_archive',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from public.supplier_returns r where r.archived_at is null and (p_scope='all' or r.device_id=any(v_devices) or r.job_id=any(v_jobs) or r.batch_id=any(v_batches))),'[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.rds_archive_returns(p_audit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare h public.deletion_history%rowtype; r public.supplier_returns%rowtype; v_before jsonb; v_snapshot jsonb; v_actor text;
begin
 select * into h from public.deletion_history where id=p_audit_id and record_type='restricted_data_deletion' and deleted_by=auth.uid();
 if h.id is null then raise exception 'An authorized Restricted Data audit is required.' using errcode='42501'; end if;
 perform greenloop_private.rds_access(h.record_data->>'scope');
 select coalesce(nullif(full_name,''),login_username,'Staff') into v_actor from public.user_profiles where id=auth.uid();
 for v_before in select value from jsonb_array_elements(coalesce(h.record_data->'supplier_returns_to_archive','[]'::jsonb)) loop
  select * into r from public.supplier_returns where id=(v_before->>'id')::uuid for update;
  if r.id is null or to_jsonb(r)<>v_before or r.archived_at is not null then raise exception 'Supplier Return data changed. Preview the deletion again.' using errcode='40001'; end if;
  select jsonb_build_object('device_id',r.device_id,'job_id',r.job_id,'batch_id',r.batch_id,'plan_line_id',r.plan_line_id,
   'supplier_code',s.supplier_code,'supplier_name',s.company_name,'batch_number',b.batch_number,'job_number',j.job_number,
   'purchase_cost',j.purchase_cost) into v_snapshot from public.suppliers s
   left join public.receiving_batches b on b.id=r.batch_id left join public.jobs j on j.id=r.job_id where s.id=r.supplier_id;
  insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),r.id);
  insert into public.supplier_return_events(return_id,action,from_status,to_status,actor_id,actor_name,notes,event_data)
   values(r.id,'archived_by_restricted_data',r.status,r.status,auth.uid(),coalesce(v_actor,'Staff'),h.deletion_reason,jsonb_build_object('deletion_audit_id',h.id,'scope',h.record_data->>'scope'));
  update public.supplier_returns set source_snapshot=v_snapshot,archived_at=now(),archived_by=auth.uid(),deletion_audit_id=h.id,
   device_id=null,job_id=null,batch_id=null,plan_line_id=null,updated_at=now() where id=r.id;
  delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid() and return_id=r.id;
 end loop;
end; $function$;

CREATE OR REPLACE FUNCTION greenloop_private.rds_execute(p_scope text,p_selection jsonb, p_deletion_code text, p_confirmation text, p_reason text, p_selection_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
 SET lock_timeout TO '5s'
 SET statement_timeout TO '90s'
AS $function$
declare
  v_plan jsonb; v_table text; v_rows jsonb; v_row jsonb;v_private_count bigint;v_supplier_count bigint;
  v_audit_id uuid := gen_random_uuid(); v_actor jsonb; v_counts jsonb;
  v_record_count bigint := 0; v_deleted bigint; v_restored numeric := 0;
  v_stock_before jsonb; v_stock_after jsonb;
  v_lots_before jsonb := '[]'::jsonb; v_balances_before jsonb := '[]'::jsonb;
  v_lots_after jsonb := '[]'::jsonb; v_balances_after jsonb := '[]'::jsonb;
begin
  perform greenloop_private.rds_access(p_scope);
  if coalesce(p_deletion_code,'')<>'1213' then raise exception 'Incorrect deletion code.' using errcode='42501'; end if;
  if p_reason is null or char_length(btrim(p_reason))<5 or char_length(btrim(p_reason))>1000 then
    raise exception 'Enter a deletion reason (5 to 1000 characters).' using errcode='22023';
  end if;
  v_plan:=greenloop_private.rds_plan(p_scope,p_selection);
  if p_confirmation is distinct from(v_plan->>'confirmation')then raise exception 'Type the exact confirmation shown in the preview.'using errcode='22023';end if;
  if p_selection_token is null or p_selection_token<>md5(v_plan::text||auth.uid()::text) then
    raise exception 'The selected data changed. Preview it again before deleting.' using errcode='40001';
  end if;
  select jsonb_object_agg(key,jsonb_array_length(value)),sum(jsonb_array_length(value))
    into v_counts,v_record_count from jsonb_each(v_plan->'records') where key<>'data_change_history';
  select coalesce(sum(jsonb_array_length(value)),0)into v_private_count from jsonb_each(v_plan->'private_records')where key=any(greenloop_private.rds_private_tables())or key='suppliers';
  v_record_count:=coalesce(v_record_count,0)+v_private_count;
  if v_record_count=0 then raise exception 'There are no IMEI records or phone processes to delete.' using errcode='22023'; end if;
  select jsonb_build_object('id',id,'name',to_jsonb(p)->>'full_name','email',to_jsonb(p)->>'email')
    into v_actor from public.user_profiles p where id=auth.uid();
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_before from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_before from public.part_stock_lots l
      where l.id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_before from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'lot_id' from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r);
  end if;

  -- Archive complete ORIGINAL rows (including technician IDs, issue/return
  -- details and existing correction audit links) before any mutation.
  insert into public.deletion_history(id,deleted_by,record_type,record_id,record_label,deletion_method,deletion_reason,record_data)
    values(v_audit_id,auth.uid(),'restricted_data_deletion',v_audit_id::text,
      v_plan->>'label',
      'hard_delete',btrim(p_reason),(v_plan-'private_records')||jsonb_build_object('audit_id',v_audit_id,'actor',v_actor,'counts',v_counts,'inventory_before',v_stock_before,
        'professional_lots_before',v_lots_before,'professional_balances_before',v_balances_before,
        'professional_inventory_policy','Physical lot quantities and statuses retained. Removing phone history is not a physical stock return.'));

  -- Detach only the exact Supplier Return rows included in the preview token;
  -- the return and its events remain as permanent, readable audit records.
  insert into greenloop_private.restricted_scope_archive(audit_id,private_records)values(v_audit_id,v_plan->'private_records');
  perform greenloop_private.rds_archive_returns(v_audit_id);
  perform greenloop_private.pf_context(true);
  perform greenloop_private.rds_cleanup(v_plan);

  -- Retain the established stock rule: only uninstalled, unreturned units are
  -- restored. Installed/damaged/manual parts are never added to available stock.
  with remaining as (
    select i.inventory_part_id,sum(greatest(i.quantity_issued-coalesce((select sum(x.quantity_installed) from public.part_installations x where x.part_issue_id=i.id),0)-i.quantity_returned,0)) as quantity
    from public.part_issue_transactions i
    where i.id::text in(select r->>'id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r)
    group by i.inventory_part_id
  ), changed as (
    update public.part_inventory i set stock_quantity=i.stock_quantity+r.quantity::integer
      from remaining r where i.id=r.inventory_part_id and r.quantity>0 returning r.quantity
  ) select coalesce(sum(quantity),0) into v_restored from changed;

  insert into greenloop_private.ledger_delete_capabilities(transaction_id,backend_pid,movement_id,audit_id)
    select txid_current(),pg_backend_pid(),(r->>'id')::uuid,v_audit_id
    from jsonb_array_elements(coalesce(v_plan->'records'->'part_stock_movements','[]'::jsonb)) r;

  -- Remove reviewed private flows BEFORE box items. Item-delete triggers otherwise
  -- increment the revision and clear print metadata, changing the archived row.
  -- Shared boxes are not in this array and retain their normal revision behavior.
  v_rows := coalesce(v_plan->'records'->'box_workflow','[]'::jsonb);
  delete from greenloop_private.box_workflow w
    where exists(select 1 from jsonb_array_elements(v_rows) r where r=to_jsonb(w));
  get diagnostics v_deleted=row_count;
  if v_deleted<>jsonb_array_length(v_rows) then
    raise exception 'Selected box workflow records changed during deletion. No changes saved.' using errcode='40001';
  end if;

  foreach v_table in array greenloop_private.restricted_tables() loop
    v_rows := coalesce(v_plan->'records'->v_table,'[]'::jsonb);
    if jsonb_array_length(v_rows)=0 then continue; end if;
    -- Compare the complete archived row, not caller-provided identifiers.
    execute format('delete from public.%I t where exists(select 1 from jsonb_array_elements($1) r where r=to_jsonb(t))',v_table) using v_rows;
    get diagnostics v_deleted=row_count;
    if v_deleted<>jsonb_array_length(v_rows) then
      raise exception 'Selected % records changed during deletion. No changes saved.',v_table using errcode='40001';
    end if;
  end loop;
  if exists(select 1 from greenloop_private.ledger_delete_capabilities where transaction_id=txid_current() and backend_pid=pg_backend_pid()) then
    raise exception 'Ledger deletion did not consume its exact audit authorization.' using errcode='55000';
  end if;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_stock_after from public.part_inventory i
    where i.id::text in(select r->>'inventory_part_id' from jsonb_array_elements(v_plan->'records'->'part_issue_transactions') r);
  if to_regclass('public.part_stock_lots') is not null then
    select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into v_lots_after from public.part_stock_lots l
      where l.id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if to_regclass('public.part_lot_status_balances') is not null then
    select coalesce(jsonb_agg(to_jsonb(b) order by to_jsonb(b)::text),'[]'::jsonb) into v_balances_after from public.part_lot_status_balances b
      where b.lot_id::text in(select r->>'id' from jsonb_array_elements(v_lots_before) r);
  end if;
  if v_lots_after<>v_lots_before or v_balances_after<>v_balances_before then
    raise exception 'Professional inventory changed during phone deletion. No changes saved.' using errcode='40001';
  end if;
  v_rows:=coalesce(v_plan->'private_records'->'suppliers','[]');
  update public.suppliers s set is_active=false,deleted_at=now(),deleted_by=auth.uid(),deleted_reason='Archived by Restricted Data supplier deletion'
   where exists(select 1 from jsonb_array_elements(v_rows)r where r=to_jsonb(s));
  get diagnostics v_supplier_count=row_count;
  if v_supplier_count<>jsonb_array_length(v_rows)then raise exception 'The supplier profile changed. No changes saved.'using errcode='40001';end if;
  perform greenloop_private.pf_context(false);
  update public.deletion_history set record_data=record_data||jsonb_build_object('private_record_counts',(select jsonb_object_agg(key,jsonb_array_length(value))from jsonb_each(v_plan->'private_records')),'archived_supplier',v_supplier_count>0,'restored_part_units',v_restored,'inventory_after',v_stock_after,
    'professional_lots_after',v_lots_after,'professional_balances_after',v_balances_after,
    'box_workflow_after',(select coalesce(jsonb_agg(to_jsonb(w) order by w.box_id),'[]'::jsonb)
      from greenloop_private.box_workflow w where w.box_id::text in
      (select r->>'box_id' from jsonb_array_elements(v_plan->'box_workflow_before') r)))
    where id=v_audit_id;
  return jsonb_build_object('audit_id',v_audit_id,'scope',p_scope,
    'deleted_devices',jsonb_array_length(v_plan->'records'->'devices'),
    'deleted_jobs',jsonb_array_length(v_plan->'records'->'jobs'),'deleted_receipts',jsonb_array_length(v_plan->'records'->'receiving_batches'),'archived_supplier',v_supplier_count>0,
    'deleted_records',v_record_count,'restored_part_units',v_restored,'counts',v_counts);
end;
$function$;


create or replace function public.execute_restricted_scope_v1(p_scope text,p_selection jsonb,p_deletion_code text,p_confirmation text,p_reason text,p_selection_token text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$begin
 perform greenloop_private.rds_access(p_scope);
 return greenloop_private.rds_execute(p_scope,p_selection,p_deletion_code,p_confirmation,p_reason,p_selection_token);
end;$$;


-- Add actions without granting targeted deletion to ordinary staff.
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"delete_supplier","label":"Delete by Supplier","write":true},{"key":"delete_invoice","label":"Delete by Invoice","write":true},{"key":"delete_batch","label":"Delete by Stock/Batch","write":true},{"key":"delete_imei_list","label":"Delete multiple IMEIs","write":true}]'::jsonb
 where page_key='reports'and not exists(select 1 from jsonb_array_elements(capabilities)c where c->>'key'='delete_supplier');
do $$begin
 if(select count(*)from greenloop_private.page_capability_catalog p,jsonb_array_elements(p.capabilities)c where p.page_key='reports'and c->>'key'=any(array['delete_supplier','delete_invoice','delete_batch','delete_imei_list']))<>4 then raise exception 'Restricted Data capability catalog requires review.';end if;
end;$$;
update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',(select jsonb_agg(v order by v)from(select distinct value v from jsonb_array_elements_text(coalesce(c.capabilities->'reports','[]')||'["delete_supplier","delete_invoice","delete_batch","delete_imei_list"]'::jsonb))q))
 where coalesce(c.capabilities->'reports','[]')?'reset'and exists(select 1 from public.user_page_permissions where user_id=c.user_id and page_key='reports'and access_level='edit')and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key in('owner','super_admin'));
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';

-- New entry points use the same office gate and reviewed wrapper receipts.
do $wrap$declare f record;impl text;args text;body text;impl_identity text;begin
 for f in select p.*,p.oid::regprocedure::text signature,pg_get_functiondef(p.oid)ddl from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_restricted_scope_options_v1','preview_restricted_scope_v1','execute_restricted_scope_v1')loop
  if strpos(f.ddl,'greenloop-office-wrapper-196')>0 then continue;end if;
  impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
  body:=E'begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.'||impl||'('||args||E');
end;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
do $$declare r record;begin for r in select oid::regprocedure sig from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'rds_%'loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end;$$;
create table if not exists greenloop_private.restricted_scopes_installation(identity text primary key,hash text not null);
alter table greenloop_private.restricted_scopes_installation enable row level security;revoke all on greenloop_private.restricted_scopes_installation from public,anon,authenticated;
create or replace function public.get_restricted_scopes_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_qc_direct_parts_version()='20261029-qc-direct-parts-1'
 and(select count(*)=15 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.restricted_scopes_installation where identity<>'reports_catalog')
 and exists(select 1 from greenloop_private.restricted_scopes_installation where identity='reports_catalog'and hash=(select md5(jsonb_agg(c order by c->>'key')::text)from greenloop_private.page_capability_catalog p,jsonb_array_elements(p.capabilities)c where p.page_key='reports'and c->>'key'=any(array['delete_supplier','delete_invoice','delete_batch','delete_imei_list'])))
 and exists(select 1 from pg_class where oid='greenloop_private.restricted_scope_archive'::regclass and relrowsecurity)
 and exists(select 1 from pg_class where oid='greenloop_private.restricted_scopes_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.restricted_scopes_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.restricted_scopes_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from unnest(array['public.get_restricted_scope_options_v1(text,text,integer,integer)','public.preview_restricted_scope_v1(text,jsonb)','public.execute_restricted_scope_v1(text,jsonb,text,text,text,text)'])s where has_function_privilege('anon',to_regprocedure(s),'EXECUTE')or not has_function_privilege('authenticated',to_regprocedure(s),'EXECUTE'))
 and not has_table_privilege('anon','greenloop_private.restricted_scope_archive','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.restricted_scope_archive','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.restricted_scopes_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261030-restricted-scopes-1'end;$$;
revoke all on function public.get_restricted_scopes_version()from public;grant execute on function public.get_restricted_scopes_version()to anon,authenticated;
insert into greenloop_private.restricted_scopes_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'rds_%'or p.pronamespace='public'::regnamespace and p.proname in('get_restricted_scopes_version','get_restricted_scope_options_v1','preview_restricted_scope_v1','execute_restricted_scope_v1')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_restricted_scope_options_v1(text,text,integer,integer)'::regprocedure,'public.preview_restricted_scope_v1(text,jsonb)'::regprocedure,'public.execute_restricted_scope_v1(text,jsonb,text,text,text,text)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.restricted_scopes_installation values('reports_catalog',(select md5(jsonb_agg(c order by c->>'key')::text)from greenloop_private.page_capability_catalog p,jsonb_array_elements(p.capabilities)c where p.page_key='reports'and c->>'key'=any(array['delete_supplier','delete_invoice','delete_batch','delete_imei_list'])))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_restricted_scopes_version()is distinct from '20261030-restricted-scopes-1'then raise exception 'Restricted Data scopes verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_restricted_scopes_version()as installed_restricted_scopes_version;
