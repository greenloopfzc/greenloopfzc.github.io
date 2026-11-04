-- Accounts IMEI DATA: read-only stock detail and complete filtered exports.
begin;
do $$begin
 if public.get_workflow_polish_version()is distinct from '20261103-workflow-polish-1'then raise exception 'Install and verify Workflow Polish first.';end if;
 if to_regprocedure('public.get_accounts_imei_data_version()')is not null then
  if public.get_accounts_imei_data_version()is distinct from '20261104-accounts-imei-data-1'then raise exception 'Existing Accounts IMEI DATA installation requires review.';end if;
 end if;
end;$$;
-- Preserve existing grants before introducing two independent, read-only ticks.
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='accounts'and capabilities @> '[{"key":"imei_data"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop
   insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;
  end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"imei_data","label":"View IMEI DATA","write":false},{"key":"imei_download","label":"IMEI DATA: PDF View / Download and Excel","write":false}]'where page_key='accounts';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{accounts}',(capabilities->'accounts')||'["imei_data","imei_download"]')
   where capabilities->'accounts'?'view'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';

create or replace function greenloop_private.aid_access(f jsonb,k text,d text,download boolean)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 perform greenloop_private.pf_cap('accounts','view');perform greenloop_private.pf_cap('accounts','imei_data');
 if download then perform greenloop_private.pf_cap('accounts','imei_download');end if;
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['supplier_id','batch_id','invoice_number','query','model','storage_gb','color','grade','stage','from_date','to_date'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Choose valid IMEI DATA filters.'using errcode='22023';end if;
 if f<>'{}'then perform greenloop_private.pf_cap('accounts','search');end if;
 if k is null or k not in('imei','model','storage_gb','color','supplier_code','batch_number','invoice_number','received_at','final_grade','stage','technician','returned_at')or d is null or d not in('asc','desc')then raise exception 'Choose a valid report sort.'using errcode='22023';end if;
 if k<>'imei'or d<>'asc'then perform greenloop_private.pf_cap('accounts','sort');end if;
 if nullif(f->>'supplier_id','')is not null then perform(f->>'supplier_id')::uuid;end if;
 if nullif(f->>'batch_id','')is not null then perform(f->>'batch_id')::uuid;end if;
 if nullif(f->>'storage_gb','')is not null and(f->>'storage_gb')!~'^[0-9]{1,6}$'then raise exception 'Choose valid GB.'using errcode='22023';end if;
 if nullif(f->>'from_date','')is not null then perform(f->>'from_date')::date;end if;
 if nullif(f->>'to_date','')is not null then perform(f->>'to_date')::date;end if;
 if nullif(f->>'from_date','')is not null and nullif(f->>'to_date','')is not null and(f->>'from_date')::date>(f->>'to_date')::date then raise exception 'From date must be on or before To date.'using errcode='22023';end if;
end;$$;

create or replace function greenloop_private.aid_rows(f jsonb)returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
with phones as materialized(
 select distinct on(j.receiving_batch_id,j.device_id)j.id job_id,j.device_id,j.receiving_batch_id batch_id,coalesce(b.supplier_id,j.supplier_id)supplier_id,j.current_status::text status,
  b.batch_number,b.invoice_number,coalesce(b.received_at,j.received_at)received_at,b.planned_quantity receipt_quantity,j.supplier_grade,d.imei_1::text imei,d.brand,d.model,d.storage_gb,d.color,d.original_grade,d.gc_grade,d.battery_health,d.battery_health_unavailable,j.current_location_id
 from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null left join public.receiving_batches b on b.id=j.receiving_batch_id
 where j.deleted_at is null
  and(nullif(f->>'supplier_id','')is null or coalesce(b.supplier_id,j.supplier_id)=(f->>'supplier_id')::uuid)
  and(nullif(f->>'batch_id','')is null or j.receiving_batch_id=(f->>'batch_id')::uuid)
  and(nullif(f->>'invoice_number','')is null or b.invoice_number=f->>'invoice_number')
 order by j.receiving_batch_id,j.device_id,j.received_at desc,j.created_at desc,j.id desc
), entered as(
 select 'phone:'||coalesce(p.batch_id::text,'legacy')||':'||p.device_id::text record_key,p.job_id,p.device_id,p.batch_id,p.batch_number,p.invoice_number,p.received_at,p.receipt_quantity,p.supplier_id,s.supplier_code,
  case when public.get_my_partner_name_access()then s.company_name end supplier_name,p.imei,p.brand,p.model,p.storage_gb,p.color,coalesce(p.supplier_grade,p.original_grade)supplier_grade,p.gc_grade initial_grade,q.final_grade,
  p.battery_health initial_bh,p.battery_health_unavailable initial_bh_unavailable,q.final_battery_health final_bh,q.final_battery_health_unavailable final_bh_unavailable,
  p.status current_status,case when lower(coalesce(l.location_name,''))like '%frame%'then 'B-DEPT'else l.location_name end current_location,t.technician,
  p.status='returned_to_supplier'or coalesce(r.status='returned',false)returned,
  p.status in('supplier_return_requested','return_pending')or coalesce(r.status in('requested','approved'),false)return_pending,
  p.status='shipped'or coalesce(x.state in('exported','legacy'),false)exported,
  r.return_number,r.handed_over_at returned_at,r.reason return_reason,r.notes return_notes,r.slip_reference return_reference
 from phones p left join public.suppliers s on s.id=p.supplier_id left join public.locations l on l.id=p.current_location_id
 left join lateral(select z.final_grade,z.final_battery_health,z.final_battery_health_unavailable from public.final_qc_inspections z where z.job_id=p.job_id order by z.inspected_at desc,z.id desc limit 1)q on true
 left join lateral(select upper(coalesce(nullif(btrim(tr.full_name),''),nullif(btrim(st.assigned_technician_name),'')))technician from public.job_work_orders w join public.job_work_order_steps st on st.work_order_id=w.id left join public.technician_roster tr on tr.id=st.assigned_technician_roster_id where w.job_id=p.job_id and st.department in('laboratory','glass')order by case when st.step_status='in_progress'then 0 else 1 end,st.assigned_at desc nulls last,w.created_at desc,st.id desc limit 1)t on true
 left join lateral(select z.*from public.supplier_returns z where z.archived_at is null and z.status in('returned','requested','approved')and z.batch_id is not distinct from p.batch_id and(z.device_id=p.device_id or z.job_id=p.job_id or z.device_id is null and z.imei_1=p.imei)order by case when z.status='returned'then 0 else 1 end,coalesce(z.handed_over_at,z.requested_at)desc,z.id desc limit 1)r on true
 left join lateral(select w.state from public.export_box_items i left join greenloop_private.box_workflow w on w.box_id=i.box_id where i.job_id=p.job_id order by i.scanned_at desc,i.id desc limit 1)x on true
), unentered as(
 select distinct on(r.batch_id,coalesce(nullif(r.imei_1,''),r.id::text))'return:'||r.id::text record_key,null::uuid job_id,null::uuid device_id,b.id batch_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity receipt_quantity,coalesce(b.supplier_id,r.supplier_id)supplier_id,s.supplier_code,
  case when public.get_my_partner_name_access()then s.company_name end supplier_name,nullif(r.imei_1,'')imei,null::text brand,coalesce(nullif(r.model,''),b.planned_model,'Not recorded')model,
  case when r.source_snapshot->>'storage_gb'~'^[0-9]{1,6}$'then(r.source_snapshot->>'storage_gb')::integer end storage_gb,r.source_snapshot->>'color'color,null::text supplier_grade,null::text initial_grade,null::text final_grade,
  null::smallint initial_bh,false initial_bh_unavailable,null::smallint final_bh,false final_bh_unavailable,
  case when r.status='returned'then 'returned_to_supplier'else 'supplier_return_requested'end current_status,null::text current_location,null::text technician,r.status='returned'returned,r.status in('requested','approved')return_pending,false exported,
  r.return_number,r.handed_over_at returned_at,r.reason return_reason,r.notes return_notes,r.slip_reference return_reference
 from public.supplier_returns r join public.receiving_batches b on b.id=r.batch_id left join public.suppliers s on s.id=coalesce(b.supplier_id,r.supplier_id)
 where r.archived_at is null and r.device_id is null and r.job_id is null and r.status in('returned','requested','approved')
  and not exists(select 1 from phones p where p.batch_id=r.batch_id and p.imei=r.imei_1)
  and(nullif(f->>'supplier_id','')is null or coalesce(b.supplier_id,r.supplier_id)=(f->>'supplier_id')::uuid)
  and(nullif(f->>'batch_id','')is null or b.id=(f->>'batch_id')::uuid)
  and(nullif(f->>'invoice_number','')is null or b.invoice_number=f->>'invoice_number')
 order by r.batch_id,coalesce(nullif(r.imei_1,''),r.id::text),case when r.status='returned'then 0 else 1 end,coalesce(r.handed_over_at,r.requested_at)desc,r.id desc
), all_rows as(select *from entered union all select *from unentered), classified as(
 select a.*,case when returned then 'returned'when return_pending then 'return_pending'when exported then 'exported'when current_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then 'ready'else 'in_process'end category,
 case when returned then 'Returned to supplier'when return_pending then 'Supplier return pending'when exported then 'Exported'
 when current_status in('received','initial_qc_pending','initial_qc_completed','no_work_required')then 'Initial QC'
 when current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','work_required','rework')then 'Lab & Glass'
 when current_status in('frame_pending','frame_in_progress')then 'B-DEPT'when current_status='parts_pending'then 'Parts'
 when current_status in('final_qc_pending','qc_failed')then 'Final QC'when current_status='accounts_pending'then 'Accounts verification'
 when current_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then 'Ready Stock'
 when current_status='box_entry_pending'then 'Box Entry'else initcap(replace(current_status,'_',' '))end stage
 from all_rows a
)select to_jsonb(c)from classified c;
$$;

create or replace function greenloop_private.aid_report(f jsonb,p_offset integer,p_limit integer,k text,d text,download boolean,expected text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source jsonb;filtered jsonb;ordered jsonb;facets jsonb;summary jsonb;token text;selection jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 200 then raise exception 'Choose a valid report page.'using errcode='22023';end if;
 select coalesce(jsonb_agg(r),'[]')into source from greenloop_private.aid_rows(f)r;
 select jsonb_build_object('model',coalesce(jsonb_agg(distinct r->>'model')filter(where r->>'model'is not null),'[]'),'storage_gb',coalesce(jsonb_agg(distinct(r->>'storage_gb')::integer)filter(where r->>'storage_gb'is not null),'[]'),'color',coalesce(jsonb_agg(distinct r->>'color')filter(where r->>'color'is not null),'[]'),'grade',coalesce(jsonb_agg(distinct r->>'final_grade')filter(where r->>'final_grade'is not null),'[]'),'stage',coalesce(jsonb_agg(distinct r->>'stage'),'[]'))into facets from jsonb_array_elements(source)r;
 select coalesce(jsonb_agg(r),'[]')into filtered from jsonb_array_elements(source)r where
  (nullif(f->>'model','')is null or r->>'model'=f->>'model')and(nullif(f->>'storage_gb','')is null or r->>'storage_gb'=f->>'storage_gb')and(nullif(f->>'color','')is null or r->>'color'=f->>'color')
  and(nullif(f->>'grade','')is null or r->>'final_grade'=f->>'grade')and(nullif(f->>'stage','')is null or r->>'stage'=f->>'stage')
  and(nullif(f->>'from_date','')is null or(r->>'received_at')::timestamptz >=(f->>'from_date')::date::timestamp at time zone 'Asia/Dubai')
  and(nullif(f->>'to_date','')is null or(r->>'received_at')::timestamptz <((f->>'to_date')::date+1)::timestamp at time zone 'Asia/Dubai')
  and(nullif(btrim(f->>'query'),'')is null or strpos(lower(concat_ws(' ',r->>'imei',r->>'model',r->>'color',r->>'supplier_code',r->>'supplier_name',r->>'batch_number',r->>'invoice_number',r->>'technician',r->>'stage',r->>'return_number',r->>'return_reason')),lower(btrim(f->>'query')))>0);
 select coalesce(jsonb_agg(r order by
  case when d='asc'and k='storage_gb'then(r->>k)::numeric end asc nulls last,case when d='desc'and k='storage_gb'then(r->>k)::numeric end desc nulls last,
  case when d='asc'and k<>'storage_gb'then lower(r->>k)end asc nulls last,case when d='desc'and k<>'storage_gb'then lower(r->>k)end desc nulls last,r->>'record_key'),'[]')into ordered from jsonb_array_elements(filtered)r;
 token:=md5(ordered::text);
 if download and expected is not null and expected is distinct from token then raise exception 'Stock data changed. Refresh IMEI DATA before downloading.'using errcode='40001';end if;
 select jsonb_build_object('total_records',count(*),'imeis',count(*)filter(where r->>'imei'is not null),'in_company',count(*)filter(where r->>'category'not in('returned','exported')),'ready',count(*)filter(where r->>'category'='ready'),'in_process',count(*)filter(where r->>'category'not in('returned','exported','ready')),'exported',count(*)filter(where r->>'category'='exported'),'returned',count(*)filter(where r->>'category'='returned'),'return_pending',count(*)filter(where r->>'category'='return_pending'),'missing_imei',count(*)filter(where r->>'imei'is null))into summary from jsonb_array_elements(ordered)r;
 select jsonb_build_object('supplier_code',case when count(distinct r->>'supplier_code')=1 then min(r->>'supplier_code')end,'supplier_name',case when count(distinct r->>'supplier_code')=1 then min(r->>'supplier_name')end,'batch_number',case when count(distinct r->>'batch_number')=1 then min(r->>'batch_number')end,'invoice_number',case when count(distinct r->>'invoice_number')=1 then min(r->>'invoice_number')end)into selection from jsonb_array_elements(source)r;
 return jsonb_build_object('generated_at',statement_timestamp(),'filters',f,'sort_key',k,'sort_direction',d,'snapshot',token,'selection',selection,'names_allowed',coalesce(public.get_my_partner_name_access(),false),'summary',summary,'facets',facets,'total',jsonb_array_length(ordered),'offset',case when download then 0 else p_offset end,
  'rows',case when download then ordered else coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(ordered)with ordinality x(r,n)where n>p_offset and n<=p_offset+p_limit),'[]')end);
end;$$;

create or replace function public.get_accounts_imei_catalogue_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;names boolean;begin
 perform greenloop_private.aid_access('{}','imei','asc',false);names:=coalesce(public.get_my_partner_name_access(),false);
 with batches as(select b.id batch_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity,b.supplier_id,s.supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id),suppliers as(select distinct supplier_id,supplier_code,supplier_name from batches where supplier_id is not null)
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from suppliers s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by received_at desc,batch_id)from batches b),'[]'),'names_allowed',names)into result;return result;
end;$$;
create or replace function public.get_accounts_imei_data_v1(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_key text default 'imei',p_sort_direction text default 'asc')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.aid_access(coalesce(p_filters,'{}'),p_sort_key,p_sort_direction,false);return greenloop_private.aid_report(coalesce(p_filters,'{}'),p_offset,p_limit,p_sort_key,p_sort_direction,false,null);
end;$$;
create or replace function public.export_accounts_imei_data_v1(p_filters jsonb default '{}',p_sort_key text default 'imei',p_sort_direction text default 'asc',p_expected_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.aid_access(coalesce(p_filters,'{}'),p_sort_key,p_sort_direction,true);return greenloop_private.aid_report(coalesce(p_filters,'{}'),0,50,p_sort_key,p_sort_direction,true,p_expected_snapshot);
end;$$;

insert into greenloop_private.capability_rpc_rules values
 ('get_accounts_imei_catalogue_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"imei_data"}],"read":true}'),
 ('get_accounts_imei_data_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"imei_data"}],"read":true}'),
 ('export_accounts_imei_data_v1','{"all":[{"page":"accounts","capability":"view"},{"page":"accounts","capability":"imei_data"},{"page":"accounts","capability":"imei_download"}],"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';

do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_accounts_imei_catalogue_v1','get_accounts_imei_data_v1','export_accounts_imei_data_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
revoke all on function greenloop_private.aid_access(jsonb,text,text,boolean),greenloop_private.aid_rows(jsonb),greenloop_private.aid_report(jsonb,integer,integer,text,text,boolean,text)from public,anon,authenticated;
create table if not exists greenloop_private.accounts_imei_installation(identity text primary key,hash text not null);
alter table greenloop_private.accounts_imei_installation enable row level security;revoke all on greenloop_private.accounts_imei_installation from public,anon,authenticated;
create or replace function public.get_accounts_imei_data_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_workflow_polish_version()='20261103-workflow-polish-1'
 and(select count(*)=10 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.accounts_imei_installation)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='accounts'and capabilities @> '[{"key":"imei_data","write":false},{"key":"imei_download","write":false}]')
 and exists(select 1 from pg_class where oid='greenloop_private.accounts_imei_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.accounts_imei_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.accounts_imei_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.accounts_imei_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from greenloop_private.accounts_imei_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='public'::regnamespace and p.proname<>'get_accounts_imei_data_version'and(has_function_privilege('anon',p.oid,'EXECUTE')or not has_function_privilege('authenticated',p.oid,'EXECUTE')))
 then '20261104-accounts-imei-data-1'end;$$;
revoke all on function public.get_accounts_imei_data_version()from public;grant execute on function public.get_accounts_imei_data_version()to anon,authenticated;
insert into greenloop_private.accounts_imei_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname in('aid_access','aid_rows','aid_report')or p.pronamespace='public'::regnamespace and p.proname in('get_accounts_imei_catalogue_v1','get_accounts_imei_data_v1','export_accounts_imei_data_v1','get_accounts_imei_data_version')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_accounts_imei_catalogue_v1()'::regprocedure,'public.get_accounts_imei_data_v1(jsonb,integer,integer,text,text)'::regprocedure,'public.export_accounts_imei_data_v1(jsonb,text,text,text)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_accounts_imei_data_version()is distinct from '20261104-accounts-imei-data-1'then raise exception 'Accounts IMEI DATA verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_accounts_imei_data_version()as installed_accounts_imei_data_version;
