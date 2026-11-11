-- Read-only grouped summaries before individual IMEI details.
begin;
do $$begin
 if public.get_ready_stock_daily_averages_version()is distinct from '20261111-ready-stock-averages-1'then raise exception 'Verified Ready Stock averages are required.';end if;
 if to_regprocedure('public.get_ready_stock_groups_version()')is not null then if public.get_ready_stock_groups_version()is distinct from '20261111-ready-stock-groups-1'then raise exception 'Existing grouped stock installation requires review.';end if;end if;
end;$$;
create or replace function greenloop_private.rsg_facts(p_mode text,p_date date,p_groups jsonb,p_from date,p_to date)
returns table(job_id uuid,device_id uuid,occurred_at timestamptz,box_number text,final_grade text)
language sql stable security definer set search_path=pg_catalog,public as $$
 with current_phones as(
 select distinct on(d.id)j.id job_id,d.id device_id,q.inspected_at occurred_at,null::text box_number,coalesce(nullif(btrim(q.final_grade),''),'Unspecified')final_grade
 from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null
 cross join lateral(select f.inspected_at,f.final_grade from greenloop_private.qdr_ready_outcomes f where f.job_id=j.id and f.result='pass'and(p_from is null or timezone('Asia/Dubai',f.inspected_at)::date between p_from and p_to)order by f.inspected_at desc limit 1)q
 where p_mode='current'and j.deleted_at is null and j.current_status in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
 and(p_groups is null or exists(select 1 from jsonb_array_elements(p_groups)g where btrim(concat_ws(' ',coalesce(nullif(btrim(d.model),''),'Unknown model'),case when d.storage_gb is not null then d.storage_gb::text||' GB'end))=g->>'m'and lower(regexp_replace(btrim(coalesce(nullif(btrim(q.final_grade),''),'Unspecified')),'[[:space:]]+',' ','g'))=g->>'g'))
 order by d.id,q.inspected_at desc,j.id
 ),daily as(
 select f.job_id,f.device_id,f.occurred_at,f.box_number,coalesce(f.export_grade,q.final_grade,'Unspecified')final_grade from greenloop_private.rsd_facts(p_date)f
 left join lateral(select o.final_grade from greenloop_private.qdr_ready_outcomes o where o.job_id=f.job_id and o.inspected_at<=f.occurred_at order by o.inspected_at desc limit 1)q on true where p_mode in('ready','export')and f.kind=p_mode
 )select *from current_phones union all select *from daily;
$$;
revoke all on function greenloop_private.rsg_facts(text,date,jsonb,date,date)from public,anon,authenticated;
create or replace function greenloop_private.rsg_read(p_mode text,p_date date,p_groups jsonb,p_from date,p_to date,p_group jsonb,p_offset integer,p_limit integer)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare day_value date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);names boolean;result jsonb;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('ready_stock','view');
 if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
 if p_mode is null or p_mode not in('current','ready','export')then raise exception 'Choose a stock report.'using errcode='22023';end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Choose a valid 50-row page.'using errcode='22023';end if;
 if(p_from is null)<>(p_to is null)or(p_from is not null and p_from>p_to)then raise exception 'Choose a valid date range.'using errcode='22023';end if;
 if p_mode<>'current'and(p_groups is not null or p_from is not null)then raise exception 'Daily reports use their selected day.'using errcode='22023';end if;
 if p_from is not null or(p_mode<>'current'and day_value<>(now()at time zone 'Asia/Dubai')::date)then perform greenloop_private.pf_cap('ready_stock','search');end if;
 if p_mode<>'current'and day_value>(now()at time zone 'Asia/Dubai')::date then raise exception 'Choose today or an earlier date.'using errcode='22023';end if;
 if p_groups is not null then
  if jsonb_typeof(p_groups)<>'array'or jsonb_array_length(p_groups)not between 1 and 10000 then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_groups)g where jsonb_typeof(g)<>'object'or jsonb_typeof(g->'m')is distinct from 'string'or jsonb_typeof(g->'g')is distinct from 'string'or length(g->>'m')not between 1 and 1000 or length(g->>'g')not between 1 and 200)then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
 end if;
 if p_group is not null then if jsonb_typeof(p_group)<>'array'or jsonb_array_length(p_group)<>6 then raise exception 'Choose a summary line.'using errcode='22023';end if;end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with facts as materialized(select *from greenloop_private.rsg_facts(p_mode,day_value,p_groups,p_from,p_to)),
 base as materialized(select f.*,d.imei_1 imei,d.device_number,coalesce(nullif(btrim(d.model),''),'Unknown model')model,d.storage_gb,d.color,b.id batch_id,b.batch_number,b.invoice_number,b.planned_quantity,sp.id supplier_id,sp.supplier_code,case when names then sp.company_name end supplier_name,
  jsonb_build_array(coalesce(nullif(btrim(d.model),''),'Unknown model'),d.storage_gb,d.color,f.final_grade,b.id,sp.id)group_key
  from facts f join public.devices d on d.id=f.device_id join public.jobs j on j.id=f.job_id left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers sp on sp.id=coalesce(j.supplier_id,b.supplier_id)),
 grouped as materialized(select group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,planned_quantity,supplier_code,supplier_name,count(*)quantity from base group by group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,planned_quantity,supplier_code,supplier_name),
 summary_page as(select *from grouped order by model,storage_gb,color,final_grade,batch_number,group_key offset p_offset limit p_limit),
 phone_page as(select *from base where group_key=p_group order by imei,device_id offset p_offset limit p_limit)
 select jsonb_build_object('mode',p_mode,'date',case when p_mode<>'current'then day_value end,'view',case when p_group is null then 'groups'else 'phones'end,'offset',p_offset,'limit',p_limit,
  'total',case when p_group is null then(select count(*)from grouped)else(select count(*)from base where group_key=p_group)end,'phone_total',(select count(*)from base),
  'rows',case when p_group is null then coalesce((select jsonb_agg(to_jsonb(s)order by model,storage_gb,color,final_grade,batch_number,group_key)from summary_page s),'[]'::jsonb)else coalesce((select jsonb_agg(jsonb_build_object('imei',imei,'device_number',device_number,'model',model,'storage_gb',storage_gb,'color',color,'final_grade',final_grade,'batch_number',batch_number,'invoice_number',invoice_number,'planned_quantity',planned_quantity,'supplier_code',supplier_code,'supplier_name',supplier_name,'occurred_at',occurred_at,'box_number',box_number)order by imei,device_id)from phone_page),'[]'::jsonb)end)into result;
 return result;
end;$$;
revoke all on function greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)from public,anon,authenticated;
create or replace function public.get_ready_stock_grouped_v1(p_mode text,p_date date default null,p_groups jsonb default null,p_date_from date default null,p_date_to date default null,p_group jsonb default null,p_offset integer default 0,p_limit integer default 50)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.rsg_read(p_mode,p_date,p_groups,p_date_from,p_date_to,p_group,p_offset,p_limit);end;$$;
revoke all on function public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)from public,anon,authenticated;grant execute on function public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)to authenticated;
insert into greenloop_private.office_routines select 'public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)','greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)',md5(pg_get_functiondef('greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)'::regprocedure)),md5(pg_get_functiondef('public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)'::regprocedure))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_ready_stock_grouped_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_ready_stock_groups_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.ready_groups_installation(identity text primary key,hash text not null);
alter table greenloop_private.ready_groups_installation enable row level security;revoke all on greenloop_private.ready_groups_installation from public,anon,authenticated;
create or replace function public.get_ready_stock_groups_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.ready_groups_installation)
 and has_function_privilege('authenticated','public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)','EXECUTE')and not has_function_privilege('anon','public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsg_facts(text,date,jsonb,date,date)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsg_facts(text,date,jsonb,date,date)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.ready_groups_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.ready_groups_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.ready_groups_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_ready_stock_grouped_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 then '20261111-ready-stock-groups-1'end;$$;
revoke all on function public.get_ready_stock_groups_version()from public;grant execute on function public.get_ready_stock_groups_version()to anon,authenticated;
insert into greenloop_private.ready_groups_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rsg_facts(text,date,jsonb,date,date)','greenloop_private.rsg_read(text,date,jsonb,date,date,jsonb,integer,integer)','public.get_ready_stock_grouped_v1(text,date,jsonb,date,date,jsonb,integer,integer)','public.get_ready_stock_groups_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_ready_stock_groups_version()is distinct from '20261111-ready-stock-groups-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Grouped Ready Stock verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_ready_stock_groups_version()as installed_ready_stock_groups_version;
