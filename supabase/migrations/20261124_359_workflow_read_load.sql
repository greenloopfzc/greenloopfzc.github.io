-- Reduce repeated work on the five hottest application reads.
begin;
set local statement_timeout='120s';
set local lock_timeout='5s';

create index if not exists gl_final_qc_waiting_order_idx
 on public.job_work_order_steps(created_at,id) include(work_order_id)
 where department='final_qc' and step_status='in_progress';

create index if not exists gl_lab_damage_arrival_idx
 on public.device_location_history(job_id,device_id,moved_at desc,id desc)
 include(from_location_id,to_location_id,movement_reason);

create index if not exists gl_lab_damage_final_attempt_idx
 on public.final_qc_inspections(job_id,attempt_number desc,inspected_at desc,id desc)
 include(result,failure_department);

do $install$
declare
 item record;
 seal record;
 installed text;
 current_source text;
 new_hash text;
 reviewed jsonb:='[]';
begin
 if to_regprocedure('public.get_workflow_read_load_version()') is not null then
  execute 'select public.get_workflow_read_load_version()' into installed;
  if installed is distinct from '20261124-workflow-read-load-1' then
   raise exception 'Existing workflow read optimization differs from this release.';
  end if;
  return;
 end if;

 if public.get_parts_queue_membership_version() is distinct from '20261119-parts-queue-membership-1' then
  raise exception 'The verified Parts queue release is required.';
 end if;

 for item in select * from (values
  ('greenloop_private.sbn_counts()','93861453ac24dfdc438c81c4cd3e172b',$ddl$
CREATE OR REPLACE FUNCTION greenloop_private.sbn_counts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
-- greenloop-shared-ready-count-276
declare result jsonb:='{}';qc jsonb;n bigint;
begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())then raise exception 'Active staff access required.'using errcode='42501';end if;
 if greenloop_private.sbn_can('stock_received')then
  select coalesce(sum(planned_quantity),0)into n from public.receiving_batches b where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id);
  result:=result||jsonb_build_object('stock_received',n);
 end if;
 if greenloop_private.sbn_can('imei_entry')then
  -- Use the same eligible receipts and return-adjusted balance as the IMEI Entry selector.
  if not public.is_active_staff()or not(public.has_page_access('imei_entry')or public.has_page_access('stock_received'))then raise exception 'Stock Received or IMEI Entry view permission is required.'using errcode='42501';end if;
  with receipts as materialized (
   select b.id, b.planned_quantity
   from public.receiving_batches b
   join public.stock_channels c on c.id=b.stock_channel_id and c.is_active
   join public.suppliers sp on sp.id=b.supplier_id and sp.is_active and sp.deleted_at is null
   where b.planned_quantity is not null
  ), entered_jobs as (
   select r.id batch_id
   from receipts r join public.jobs j on j.receiving_batch_id=r.id and j.deleted_at is null
   where not exists (select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id)
   union all
   select r.id
   from receipts r join greenloop_private.srp_phone_links l on l.replacement_batch_id=r.id
   join public.jobs j on j.id=l.replacement_job_id and j.deleted_at is null
  ), entered as (
   select batch_id, count(*) quantity from entered_jobs group by batch_id
  ), unentered_returns as (
   select t.batch_id, count(*) quantity
   from public.supplier_returns t join receipts r on r.id=t.batch_id
   where t.device_id is null and t.status in ('requested','approved','returned')
   group by t.batch_id
  )
  select coalesce(sum(greatest(r.planned_quantity-coalesce(e.quantity,0)-coalesce(t.quantity,0),0)),0)
  into n from receipts r
  left join entered e on e.batch_id=r.id left join unentered_returns t on t.batch_id=r.id;
  result:=result||jsonb_build_object('imei_entry',n);
 end if;
 if greenloop_private.sbn_can('initial_qc')then
  qc:=greenloop_private.qcn_counts();result:=result||qc;
 end if;
 if greenloop_private.sbn_can('qc_issuance')then
 select count(*)into n from greenloop_private.qc_saved_issuance s
 join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id
 join public.jobs j on j.id=s.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id)and j.current_status='initial_qc_pending'
 join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance';result:=result||jsonb_build_object('qc_issuance',n);
 elsif not greenloop_private.sbn_can('initial_qc')then result:=result-'qc_issuance';end if;
 if greenloop_private.sbn_can('lab_glass')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id) join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department in('laboratory','glass')and s.step_status='in_progress'and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','parts_pending');
  result:=result||jsonb_build_object('lab_glass',n);
 end if;
 if greenloop_private.sbn_can('parts')then
  select count(distinct imei)into n from(
 select d.imei_1 imei from greenloop_private.pqm_orders()q join public.devices d on d.id=q.device_id where q.needs_issue
 union select imei from greenloop_private.pp_returns()where status='pending')pending;
  result:=result||jsonb_build_object('parts',n);
 end if;
 if greenloop_private.sbn_can('final_qc')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id) join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='final_qc'and s.step_status='in_progress'and j.current_status in('final_qc_pending','qc_failed');
  result:=result||jsonb_build_object('final_qc',n);
 end if;
 if greenloop_private.sbn_can('frame_department')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id) join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='frame'and s.step_status='in_progress'and j.current_status in('frame_pending','frame_in_progress');
  result:=result||jsonb_build_object('frame',n);
 end if;
 if greenloop_private.sbn_can('ready_stock')then
  n:=greenloop_private.drc_ready_count();
  result:=result||jsonb_build_object('ready_stock',n);
 end if;
 if greenloop_private.sbn_can('accounts')then
  select count(*)into n from greenloop_private.box_workflow w join public.export_boxes b on b.id=w.box_id where w.state='accounts';
  result:=result||jsonb_build_object('accounts',n);
 end if;
 if greenloop_private.sbn_can('export_boxes')then
  select count(*)into n from public.export_boxes b left join greenloop_private.box_workflow w on w.box_id=b.id
  where coalesce(w.state,case when b.box_status='open'then 'draft'else 'legacy'end)in('draft','recheck')and exists(select 1 from public.export_box_items i where i.box_id=b.id);
  result:=result||jsonb_build_object('box_entry',n);
 end if;
 if greenloop_private.sbn_can('stock_exported')then
  select count(distinct i.device_id)into n from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id and w.state='exported'join public.jobs j on j.id=i.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id) join public.devices d on d.id=i.device_id and d.deleted_at is null where j.current_status='shipped';
  result:=result||jsonb_build_object('stock_exported',n);
 end if;
 if greenloop_private.sbn_can('ready_stock_journey')then
  select count(distinct d.id)into n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.deleted_at is null and greenloop_private.company_job_available(j.id);
  result:=result||jsonb_build_object('stock_journey',n);
 end if;
 if greenloop_private.sbn_can('supplier_returns')then
  select count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))into n from public.supplier_returns where archived_at is null and status in('requested','approved');
  result:=result||jsonb_build_object('supplier_returns',n);
 end if;
 return result;
end;$function$;
$ddl$),
  ('greenloop_private.pd_enrich(jsonb)','643e4ec06554e08db6b9b37f88614b68',$ddl$
CREATE OR REPLACE FUNCTION greenloop_private.pd_enrich(plan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 declare k text;rows jsonb;
 begin
  if plan is null then return null;end if;
  foreach k in array array['parts','part_history','issues']loop
   if jsonb_typeof(plan->k)='array'then
    select coalesce(jsonb_agg(a.item||jsonb_build_object(
      'damaged',coalesce(d.damaged,false),'damage_reason',d.reason,'damage_by',u.full_name,
      'damage_at',d.changed_at,'damage_source',d.source) order by a.line),'[]')
    into rows
    from jsonb_array_elements(plan->k) with ordinality a(item,line)
    left join public.part_issue_transactions i on i.id=case when a.item->>'request_id' is null
      then coalesce(nullif(a.item->>'issue_id',''),nullif(a.item->>'id',''))::uuid end
    left join greenloop_private.parts_request_damage d
      on d.request_id=coalesce((a.item->>'request_id')::uuid,i.part_request_id)
    left join public.user_profiles u on u.id=d.changed_by;
    plan:=jsonb_set(plan,array[k],rows);
   end if;
  end loop;
  return plan||jsonb_build_object('damage_version','20261117-parts-request-damage-1');
 end;$function$;
$ddl$),
  ('greenloop_private.technician_parts_pending()','f99486ad198e1961d9a58ed37affccff',$ddl$
CREATE OR REPLACE FUNCTION greenloop_private.technician_parts_pending()
 RETURNS TABLE(order_id uuid, request_id uuid, device_id uuid, imei text, model text, storage_gb integer, color text, supplier_code text, batch_number text, technician_key text, technician_name text, part_name text, quantity bigint, ordered_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 with pending_requests as materialized (
   select m.order_id,r.id,r.part_name,r.quantity_requested,r.quantity_issued
   from greenloop_private.parts_flow_requests m join public.job_part_requests r on r.id=m.request_id
   where r.status<>'cancelled' and r.quantity_requested>r.quantity_issued
 ), pending_orders as materialized (
   select o.*
   from greenloop_private.parts_flow_orders o join public.jobs j on j.id=o.job_id and j.deleted_at is null
   where o.completed_at is null
     and j.current_status in ('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
     and exists (select 1 from pending_requests r where r.order_id=o.id)
 ), cycles as materialized (
   select j.job_id,greenloop_private.pf_cycle(j.job_id) cycle
   from (select distinct job_id from pending_orders) j
 ), assigned_orders as materialized (
   select o.*,st.assigned_technician_name,t.id technician_id,t.full_name
   from pending_orders o join cycles cy on cy.job_id=o.job_id and cy.cycle=o.cycle
   join public.job_work_order_steps st on st.id=o.step_id
   left join lateral (
     select tr.id,tr.full_name from public.technician_roster tr
     where greenloop_private.ed_matches(st.assigned_technician_roster_id,st.assigned_technician_name,tr.id,tr.full_name)
     order by tr.is_active desc,tr.created_at,tr.id limit 1
   ) t on true
 )
 select o.id,r.id,d.id,d.imei_1,d.model,d.storage_gb,coalesce(nullif(btrim(d.color),''),'Not recorded'),s.supplier_code,b.batch_number,
 coalesce(o.technician_id::text,case when nullif(btrim(o.assigned_technician_name),'') is null
   then 'unassigned' else 'legacy:'||greenloop_private.ed_key(o.assigned_technician_name) end),
 coalesce(o.full_name,nullif(btrim(o.assigned_technician_name),''),'Unassigned'),
 r.part_name,(r.quantity_requested-r.quantity_issued)::bigint,o.submitted_at
 from assigned_orders o join pending_requests r on r.order_id=o.id
 join public.jobs j on j.id=o.job_id join public.devices d on d.id=o.device_id and d.deleted_at is null
 left join public.suppliers s on s.id=j.supplier_id left join public.receiving_batches b on b.id=j.receiving_batch_id;
$function$;
$ddl$),
  ('greenloop_private.ppp_report(jsonb,text)','c4d11f8b1431eb5c78c0806592517569',$ddl$
CREATE OR REPLACE FUNCTION greenloop_private.ppp_report(p_filters jsonb, p_group text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare f jsonb:=coalesce(p_filters,'{}'); result jsonb;
begin
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['query','supplier_id','batch_id','invoice_number','model','part_name','source','currency','issued_day','quantity','phones','returned_quantity'])or jsonb_typeof(e.value)not in('string','null')or (length(e.value#>>'{}')>200 and not(e.key in('query','_search')and greenloop_private.sc_is_bulk(e.value#>>'{}'))))then raise exception 'Use valid pending-price filters.'using errcode='22023';end if;
 if p_group is not null and p_group!~'^[a-f0-9]{32}$'then raise exception 'Select a current pending-price group.'using errcode='22023';end if;
 with units as materialized (
  select u from greenloop_private.ppp_units() u
 ), matched as materialized (
  select u,u->>'group_id' group_id from units where greenloop_private.ppp_matches(u,f)
 ), groups as materialized (
 select group_id,min(u->>'supplier_id')supplier_id,min(u->>'supplier_code')supplier_code,min(u->>'batch_id')batch_id,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,
  min(u->>'model')model,min(u->>'model_key')model_key,min((u->>'storage_gb')::integer)storage_gb,min(u->>'storage_label')storage_label,min(u->>'color')color,min(u->>'color_key')color_key,min(u->>'part_name')part_name,min(u->>'part_key')part_key,min(u->>'source')source,min(u->>'currency')currency,
  sum((u->>'quantity')::integer)::integer quantity,sum((u->>'returned_quantity')::integer)::integer returned_quantity,count(distinct u->>'device_id')::integer phones,count(*)::integer issue_count,
  min(u->>'issued_day')first_issued_day,max(u->>'issued_day')last_issued_day,
  md5(jsonb_agg(u order by u->>'issue_id')::text)selection_token

  from matched group by group_id
 ), selected as materialized (
  select g.* from groups g
  where (coalesce(f->>'quantity','')='' or g.quantity::text=f->>'quantity')
    and (coalesce(f->>'phones','')='' or g.phones::text=f->>'phones')
    and (coalesce(f->>'returned_quantity','')='' or g.returned_quantity::text=f->>'returned_quantity')
 ), facet_keys(key) as (
  values ('supplier_id'),('batch_id'),('invoice_number'),('model'),('part_name'),
    ('currency'),('issued_day'),('quantity'),('phones'),('returned_quantity')
 ), facet_values as (
  select k.key,coalesce(k.value,'Not recorded') value,min(coalesce(k.label,'Not recorded')) label
  from units
  cross join lateral (values
    ('supplier_id',u->>'supplier_id',u->>'supplier_code'),('batch_id',u->>'batch_id',u->>'batch_number'),
    ('invoice_number',u->>'invoice_number',u->>'invoice_number'),('model',u->>'model_key',u->>'model'),
    ('part_name',u->>'part_key',u->>'part_name'),('currency',u->>'currency',u->>'currency'),
    ('issued_day',u->>'issued_day',u->>'issued_day')
  ) k(key,value,label) group by k.key,coalesce(k.value,'Not recorded')
  union all
  select k.key,k.value,k.value from groups g
  cross join lateral (values ('quantity',g.quantity::text),('phones',g.phones::text),
    ('returned_quantity',g.returned_quantity::text)) k(key,value)
  group by k.key,k.value
 ), facet_options as (
  select k.key,coalesce(jsonb_agg(jsonb_build_object('value',v.value,'label',v.label)
    order by v.label,v.value) filter (where v.value is not null),'[]') options
  from facet_keys k left join facet_values v on v.key=k.key group by k.key
 ), eligible as materialized (
  select m.u,m.group_id from matched m join selected g using(group_id)
 )
 select jsonb_build_object(
  'rows',coalesce((select jsonb_agg(to_jsonb(g) order by
    g.supplier_code,g.batch_number,g.model,g.storage_gb,g.color,g.part_name,g.source,g.group_id) from selected g),'[]'),
  'facets',(select jsonb_object_agg(key,options) from facet_options)||
    '{"source":[{"value":"local","label":"Local"},{"value":"china","label":"China"},{"value":"unrecorded","label":"Not recorded"}]}'::jsonb,
  'generated_at',now(),
  'overall_summary',(select jsonb_build_object('phones',count(distinct u->>'device_id'),
    'quantity',coalesce(sum((u->>'quantity')::integer),0)) from units),
  'summary',(select jsonb_build_object('groups',count(*),
    'phones',(select count(distinct u->>'device_id') from eligible),
    'quantity',coalesce(sum(quantity),0),'returned_quantity',coalesce(sum(returned_quantity),0)) from selected),
  'details',case when p_group is null then '[]'::jsonb else coalesce((
    select jsonb_agg(u order by u->>'imei',u->>'issued_at',u->>'issue_id')
    from eligible where group_id=p_group),'[]') end
 ) into result;
 return result;
end;$function$;
$ddl$)
 ) r(identity,source_hash,replacement) loop
  current_source:=pg_get_functiondef(to_regprocedure(item.identity));
  if md5(replace(current_source,chr(13),'')) is distinct from item.source_hash then
   raise exception 'Unexpected database definition for %. No changes were applied.',item.identity;
  end if;
  reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',item.identity,'hash',md5(current_source)));
  execute item.replacement;
 end loop;

 -- Keep existing installation checks valid only for the exact bodies replaced.
 for item in select * from jsonb_to_recordset(reviewed) as r(identity text,hash text) loop
  new_hash:=md5(pg_get_functiondef(to_regprocedure(item.identity)));
  for seal in
   select c.oid::regclass relation,k.identity_column,k.hash_column
   from pg_class c
   cross join (values ('identity','hash'),('identity','before_hash'),('identity','definition_hash'),
     ('object_identity','definition_hash'),('function_identity','definition_hash')) k(identity_column,hash_column)
   where c.relnamespace='greenloop_private'::regnamespace and c.relkind='r'
   and right(c.relname,13)='_installation'
   and exists (select 1 from pg_attribute where attrelid=c.oid and attname=k.identity_column and atttypid='text'::regtype and not attisdropped)
   and exists (select 1 from pg_attribute where attrelid=c.oid and attname=k.hash_column and atttypid='text'::regtype and not attisdropped)
  loop
   execute format('update %s set %I=$1 where replace(%I,'' '','''')=replace($2,'' '','''') and %I=$3',
     seal.relation,seal.hash_column,seal.identity_column,seal.hash_column)
   using new_hash,item.identity,item.hash;
  end loop;
 end loop;

 create table greenloop_private.workflow_read_load_installation(identity text primary key,hash text not null);
 alter table greenloop_private.workflow_read_load_installation enable row level security;
 revoke all on greenloop_private.workflow_read_load_installation from public,anon,authenticated;
 insert into greenloop_private.workflow_read_load_installation
 select r.identity,md5(pg_get_functiondef(to_regprocedure(r.identity)))
 from jsonb_to_recordset(reviewed) as r(identity text);

 create function public.get_workflow_read_load_version() returns text
 language sql stable security definer set search_path=pg_catalog,public as $marker$
 select case when (
  select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
  from greenloop_private.workflow_read_load_installation
 ) and (
  select count(*)=3 and bool_and(indisvalid and indisready) from pg_index
  where indexrelid in (to_regclass('public.gl_final_qc_waiting_order_idx'),
    to_regclass('public.gl_lab_damage_arrival_idx'),to_regclass('public.gl_lab_damage_final_attempt_idx'))
 ) then '20261124-workflow-read-load-1' end;
 $marker$;
 revoke all on function public.get_workflow_read_load_version() from public;
 grant execute on function public.get_workflow_read_load_version() to anon,authenticated;
 insert into greenloop_private.capability_rpc_rules values ('get_workflow_read_load_version','{"read":true}')
 on conflict(rpc_name) do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation
 set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
 where identity='rules';

 if public.get_workflow_read_load_version() is distinct from '20261124-workflow-read-load-1'
  or public.get_parts_queue_membership_version() is distinct from '20261119-parts-queue-membership-1'
 then raise exception 'Workflow read optimization could not be verified.'; end if;
 notify pgrst,'reload schema';
end;
$install$;

select public.get_workflow_read_load_version() as installed_workflow_read_load_version;
commit;
