-- Read-only supplier/batch/model/part usage. Financial fields are never returned.
DO $parts_usage_install$ BEGIN EXECUTE $ddl$
do $$begin
 if public.get_generic_housing_retirement_version()is distinct from '20261116-generic-housing-retired-1'then raise exception 'Verify Generic Housing Retirement first.';end if;
 if to_regprocedure('public.get_parts_usage_report_version()')is not null then if public.get_parts_usage_report_version()is distinct from '20261116-parts-usage-report-1'then raise exception 'Existing Parts Usage Report integrity needs review.';end if;end if;
end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @> '[{"key":"parts_usage"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"parts_usage","label":"View Parts Usage Report","write":false},{"key":"parts_usage_search","label":"Parts Usage: search and filters","write":false},{"key":"parts_usage_download","label":"Parts Usage: PDF and Excel","write":false}]'where page_key='reports';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',(capabilities->'reports')||'["parts_usage","parts_usage_search","parts_usage_download"]')where capabilities->'reports'?'view'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
 end if;
end;$$;
create or replace function greenloop_private.pug_access(f jsonb,download boolean)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_access('reports'),false)or not coalesce(public.has_page_capability_v1('reports','view'),false)or not coalesce(public.has_page_capability_v1('reports','parts_usage'),false)then raise exception 'Parts Usage Report access is required.'using errcode='42501';end if;
 if f<>'{}'::jsonb and not coalesce(public.has_page_capability_v1('reports','parts_usage_search'),false)then raise exception 'Parts Usage search permission is required.'using errcode='42501';end if;
 if download and not coalesce(public.has_page_capability_v1('reports','parts_usage_download'),false)then raise exception 'Parts Usage download permission is required.'using errcode='42501';end if;
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['supplier_id','batch_id','model','part_name','query','from_date','to_date'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Choose valid Parts Usage filters.'using errcode='22023';end if;
 if nullif(f->>'supplier_id','')is not null then perform(f->>'supplier_id')::uuid;end if;
 if nullif(f->>'batch_id','')is not null then perform(f->>'batch_id')::uuid;end if;
 if nullif(f->>'from_date','')is not null then perform(f->>'from_date')::date;end if;
 if nullif(f->>'to_date','')is not null then perform(f->>'to_date')::date;end if;
 if nullif(f->>'from_date','')is not null and nullif(f->>'to_date','')is not null and(f->>'from_date')::date>(f->>'to_date')::date then raise exception 'From date must be on or before To date.'using errcode='22023';end if;
end;$$;
create or replace function greenloop_private.pug_units(f jsonb,names boolean)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with recursive roots as materialized(
  select b.id,b.supplier_id,b.batch_number,b.invoice_number,b.planned_quantity receipt_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name
  from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id
  where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id)
  and(nullif(f->>'supplier_id','')is null or b.supplier_id=(f->>'supplier_id')::uuid)and(nullif(f->>'batch_id','')is null or b.id=(f->>'batch_id')::uuid)
 ),mapping(root_id,batch_id)as(
  select id,id from roots union select m.root_id,r.replacement_batch_id from mapping m join greenloop_private.srp_receipts r on r.original_batch_id=m.batch_id where r.replacement_batch_id is not null
 ),phones as materialized(
  select j.id job_id,d.id device_id,d.imei_1 imei,coalesce(nullif(btrim(d.model),''),'Not recorded')model,d.storage_gb,d.color,d.gc_grade grade,j.current_status::text current_stage,r.*
  from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null join mapping m on m.batch_id=j.receiving_batch_id join roots r on r.id=m.root_id where j.deleted_at is null
 ),installations as materialized(select part_issue_id,part_request_id,job_id,device_id,sum(quantity_installed)installed from public.part_installations group by part_issue_id,part_request_id,job_id,device_id),lines as(
  select 'issue:'||i.id source_id,p.id batch_id,p.supplier_id,p.supplier_code,p.supplier_name,p.batch_number,p.invoice_number,p.receipt_quantity,p.job_id,p.device_id,p.imei,p.model,p.storage_gb,p.color,p.grade,p.current_stage,btrim(r.part_name)part_name,
   coalesce(nullif(btrim(r.requested_for_technician),''),nullif(btrim(st.assigned_technician_name),''),tr.full_name)technician,i.quantity_issued::bigint issued,coalesce(x.installed,0)::bigint installed,coalesce(i.quantity_returned,0)::bigint returned,0::bigint manual_installed,i.issued_at occurred_at,'Issued part'::text source
  from phones p join public.job_part_requests r on r.job_id=p.job_id join public.part_issue_transactions i on i.part_request_id=r.id
  left join greenloop_private.parts_flow_requests link on link.request_id=r.id left join greenloop_private.parts_flow_orders ord on ord.id=link.order_id left join public.job_work_order_steps st on st.id=ord.step_id left join public.technician_roster tr on tr.id=st.assigned_technician_roster_id
  left join installations x on x.part_issue_id=i.id and x.part_request_id=r.id and x.job_id=r.job_id and x.device_id=r.device_id where i.quantity_issued>0
  union all
  select 'manual:'||i.id,p.id,p.supplier_id,p.supplier_code,p.supplier_name,p.batch_number,p.invoice_number,p.receipt_quantity,p.job_id,p.device_id,p.imei,p.model,p.storage_gb,p.color,p.grade,p.current_stage,btrim(i.part_name),coalesce(nullif(btrim(st.assigned_technician_name),''),tr.full_name),0,i.quantity::bigint,0,i.quantity::bigint,i.installed_at,'Manual installation'
  from phones p join public.lab_manual_part_installations i on i.job_id=p.job_id and i.device_id=p.device_id left join public.job_work_order_steps st on st.id=i.work_order_step_id left join public.technician_roster tr on tr.id=st.assigned_technician_roster_id where i.quantity>0
 ),chosen as(
  select l.*,issued-returned net_issued from lines l where(nullif(f->>'model','')is null or l.model=f->>'model')and(nullif(f->>'part_name','')is null or l.part_name=f->>'part_name')
  and(nullif(f->>'query','')is null or strpos(lower(concat_ws(' ',supplier_code,supplier_name,batch_number,invoice_number,imei,model,part_name,technician)),lower(f->>'query'))>0)
  and(nullif(f->>'from_date','')is null or(occurred_at at time zone 'Asia/Dubai')::date>=(f->>'from_date')::date)
  and(nullif(f->>'to_date','')is null or(occurred_at at time zone 'Asia/Dubai')::date<=(f->>'to_date')::date)
 )select coalesce(jsonb_agg(to_jsonb(c)order by source_id),'[]')from chosen c;
$$;
create or replace function greenloop_private.pug_read(f jsonb,p_group text,start_row integer,expected text,download boolean)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);units jsonb;groups jsonb;chosen jsonb;catalogue jsonb;totals jsonb;token text;selected_group jsonb;begin
 perform greenloop_private.pug_access(f,download);
 if start_row is null or start_row<0 or start_row%50<>0 or p_group is not null and p_group!~'^[0-9a-f]{32}$'then raise exception 'Choose a valid Parts Usage page or group.'using errcode='22023';end if;
 if (p_group is not null or start_row>0 or download)and(expected is null or expected!~'^[0-9a-f]{32}$')then raise exception 'Refresh Parts Usage before opening details or downloading.'using errcode='22023';end if;
 units:=greenloop_private.pug_units(f,names);
 if jsonb_array_length(units)<>(select count(distinct u->>'source_id')from jsonb_array_elements(units)u)then raise exception 'Part history has an ambiguous original batch link. Review the stock records.'using errcode='40001';end if;
 token:=md5(jsonb_build_object('filters',f,'units',units,'names',names)::text);
 if expected is not null and expected is distinct from token then raise exception 'Parts Usage changed. Refresh before opening details or downloading.'using errcode='40001';end if;
 with p as(select u from jsonb_array_elements(units)u),g as(
  select (u->>'batch_id')::uuid batch_id,(u->>'supplier_id')::uuid supplier_id,min(u->>'supplier_code')supplier_code,min(u->>'supplier_name')supplier_name,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,min((u->>'receipt_quantity')::bigint)receipt_quantity,u->>'model'model,u->>'part_name'part_name,
   count(distinct u->>'device_id')phones,sum((u->>'issued')::bigint)issued,sum((u->>'installed')::bigint)installed,sum((u->>'returned')::bigint)returned,sum((u->>'net_issued')::bigint)net_issued,sum((u->>'manual_installed')::bigint)manual_installed
  from p group by u->>'batch_id',u->>'supplier_id',u->>'model',u->>'part_name'
 )select coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('group_id',md5(jsonb_build_array(batch_id,model,part_name)::text))order by supplier_code,batch_number,model,part_name,batch_id),'[]')into groups from g;
 if p_group is not null then
  select u into selected_group from jsonb_array_elements(groups)u where u->>'group_id'=p_group;
  if selected_group is null then raise exception 'This part group no longer matches the selected report.'using errcode='40001';end if;
  with p as(select u from jsonb_array_elements(units)u where u->>'batch_id'=selected_group->>'batch_id'and u->>'model'=selected_group->>'model'and u->>'part_name'=selected_group->>'part_name'),g as(
   select (u->>'device_id')::uuid device_id,min(u->>'imei')imei,min(u->>'model')model,min((u->>'storage_gb')::integer)storage_gb,min(u->>'color')color,min(u->>'grade')grade,string_agg(distinct u->>'current_stage',', ')current_stage,string_agg(distinct u->>'technician',', 'order by u->>'technician')technician,
    min(u->>'supplier_code')supplier_code,min(u->>'supplier_name')supplier_name,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,min((u->>'receipt_quantity')::bigint)receipt_quantity,min(u->>'part_name')part_name,
    sum((u->>'issued')::bigint)issued,sum((u->>'installed')::bigint)installed,sum((u->>'returned')::bigint)returned,sum((u->>'net_issued')::bigint)net_issued,sum((u->>'manual_installed')::bigint)manual_installed,min((u->>'occurred_at')::timestamptz)first_recorded,max((u->>'occurred_at')::timestamptz)last_recorded
   from p group by u->>'device_id'
  )select coalesce(jsonb_agg(to_jsonb(g)order by imei,device_id),'[]')into chosen from g;
 else chosen:=groups;end if;
 select jsonb_build_object('phones',count(distinct u->>'device_id'),'issued',coalesce(sum((u->>'issued')::bigint),0),'installed',coalesce(sum((u->>'installed')::bigint),0),'returned',coalesce(sum((u->>'returned')::bigint),0),'net_issued',coalesce(sum((u->>'net_issued')::bigint),0),'manual_installed',coalesce(sum((u->>'manual_installed')::bigint),0))into totals from jsonb_array_elements(units)u;
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.planned_quantity receipt_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id))
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by batch_number,batch_id)from b),'[]'),'models',coalesce((select jsonb_agg(v order by v)from(select distinct u->>'model'v from jsonb_array_elements(units)u)x),'[]'),'parts',coalesce((select jsonb_agg(v order by v)from(select distinct u->>'part_name'v from jsonb_array_elements(units)u)x),'[]'))into catalogue;
 return jsonb_build_object('version','20261116-parts-usage-report-1','filters',f,'group_id',p_group,'selected_group',selected_group,'names_allowed',names,'snapshot',token,'totals',totals,'total',jsonb_array_length(chosen),'offset',start_row,'download',download,'rows',case when download then chosen else coalesce((select jsonb_agg(u order by n)from jsonb_array_elements(chosen)with ordinality a(u,n)where n>start_row and n<=start_row+50),'[]')end,'catalogue',catalogue,'generated_at',now());
end;$$;
create or replace function public.get_parts_usage_report_v1(p_filters jsonb default '{}',p_group text default null,p_offset integer default 0,p_expected text default null)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$select greenloop_private.pug_read(coalesce(p_filters,'{}'),p_group,p_offset,p_expected,false);$$;
create or replace function public.export_parts_usage_report_v1(p_filters jsonb,p_group text,p_expected text)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$select greenloop_private.pug_read(coalesce(p_filters,'{}'),p_group,0,p_expected,true);$$;
revoke all on function greenloop_private.pug_access(jsonb,boolean),greenloop_private.pug_units(jsonb,boolean),greenloop_private.pug_read(jsonb,text,integer,text,boolean)from public,anon,authenticated;
revoke all on function public.get_parts_usage_report_v1(jsonb,text,integer,text),public.export_parts_usage_report_v1(jsonb,text,text)from public,anon;grant execute on function public.get_parts_usage_report_v1(jsonb,text,integer,text),public.export_parts_usage_report_v1(jsonb,text,text)to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_parts_usage_report_v1','{"page":"reports","capability":"parts_usage","read":true}'),('export_parts_usage_report_v1','{"all":[{"page":"reports","capability":"parts_usage"},{"page":"reports","capability":"parts_usage_download"}],"read":true}'),('get_parts_usage_report_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.parts_usage_report_installation(identity text primary key,hash text not null);alter table greenloop_private.parts_usage_report_installation enable row level security;revoke all on greenloop_private.parts_usage_report_installation from public,anon,authenticated;
create or replace function public.get_parts_usage_report_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_generic_housing_retirement_version()='20261116-generic-housing-retired-1'and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_usage_report_installation)and not exists(select 1 from greenloop_private.parts_usage_report_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))and exists(select 1 from pg_class where oid='greenloop_private.parts_usage_report_installation'::regclass and relrowsecurity)and not has_table_privilege('authenticated','greenloop_private.parts_usage_report_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_function_privilege('anon','public.get_parts_usage_report_v1(jsonb,text,integer,text)','EXECUTE')and not has_function_privilege('anon','public.export_parts_usage_report_v1(jsonb,text,text)','EXECUTE')and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @> '[{"key":"parts_usage"},{"key":"parts_usage_search"},{"key":"parts_usage_download"}]')then '20261116-parts-usage-report-1'end;$$;
revoke all on function public.get_parts_usage_report_version()from public;grant execute on function public.get_parts_usage_report_version()to anon,authenticated;
insert into greenloop_private.parts_usage_report_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.pug_access(jsonb,boolean)','greenloop_private.pug_units(jsonb,boolean)','greenloop_private.pug_read(jsonb,text,integer,text,boolean)','public.get_parts_usage_report_v1(jsonb,text,integer,text)','public.export_parts_usage_report_v1(jsonb,text,text)','public.get_parts_usage_report_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_parts_usage_report_version()is distinct from '20261116-parts-usage-report-1'then raise exception 'Parts Usage Report verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$parts_usage_install$;
select public.get_parts_usage_report_version()as installed_parts_usage_report_version;
