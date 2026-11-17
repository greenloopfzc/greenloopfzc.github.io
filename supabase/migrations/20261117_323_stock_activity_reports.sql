-- Read-only stock activity periods. No stock/workflow/history backfill.
do $activity_install$
begin
 if public.get_ready_stock_received_daily_version()is distinct from '20261117-ready-stock-received-daily-1'then raise exception 'Install the verified Stock Received daily update first.';end if;
 if to_regprocedure('public.get_stock_activity_reports_version()')is not null then if public.get_stock_activity_reports_version()is distinct from '20261117-stock-activity-reports-1'then raise exception 'Existing stock activity integrity differs. Nothing installed.';end if;end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Existing permission rules are not verified.';end if;
 create index if not exists stock_activity_receipt_time on public.receiving_batches(received_at,id)where planned_quantity>=0;
 create table if not exists greenloop_private.stock_activity_installation(identity text primary key,hash text not null);
 alter table greenloop_private.stock_activity_installation enable row level security;
 revoke all on greenloop_private.stock_activity_installation from public,anon,authenticated;

 create or replace function greenloop_private.rpta_access(day date,history boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 begin
  perform greenloop_private.pf_cap('ready_stock','view');
  if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
  if day is null or day>(now()at time zone 'Asia/Dubai')::date or day<date '1900-01-01'then raise exception 'Choose today or an earlier valid activity date.'using errcode='22023';end if;
  if history or day<>(now()at time zone 'Asia/Dubai')::date then perform greenloop_private.pf_cap('ready_stock','search');end if;
 end;$body$;

 create or replace function greenloop_private.rpta_facts(p_from date,p_to date)returns table(kind text,activity_day date,job_id uuid,device_id uuid,occurred_at timestamptz,box_number text,export_grade text,final_grade text,model text,storage_gb integer,color text,batch_id uuid)language sql stable security definer set search_path=pg_catalog,public as $body$
 with bounds as(select p_from::timestamp at time zone 'Asia/Dubai'lo,(p_to+1)::timestamp at time zone 'Asia/Dubai'hi),arrivals as(
  select 'ready'::text kind,h.job_id,h.device_id,h.moved_at occurred_at,null::text box_number,null::text export_grade,h.id tie
  from public.device_location_history h join public.locations l on l.id=h.to_location_id cross join bounds b where l.location_code in('PRODUCTION','READY','READY-STOCK')and h.from_location_id is distinct from h.to_location_id and h.moved_at>=b.lo and h.moved_at<b.hi and h.moved_at<=now()
 ),exports as(
  select 'export'::text kind,i.job_id,i.device_id,w.verified_at occurred_at,bx.box_number,i.final_grade export_grade,i.id tie
  from greenloop_private.box_workflow w join public.export_boxes bx on bx.id=w.box_id join public.export_box_items i on i.box_id=w.box_id cross join bounds b where w.state='exported'and w.verified_at is not null and i.scanned_at<=w.verified_at and w.verified_at>=b.lo and w.verified_at<b.hi and w.verified_at<=now()
  union all select 'export',r.job_id,j.device_id,r.dispatched_at,null,null,r.id from public.stock_out_records r join public.jobs j on j.id=r.job_id cross join bounds b where r.dispatched_at>=b.lo and r.dispatched_at<b.hi and r.dispatched_at<=now()
 ),selected as(
  select distinct on(f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.device_id)f.* from(select *from arrivals union all select *from exports)f
  join public.jobs j on j.id=f.job_id and j.device_id=f.device_id and j.deleted_at is null join public.devices d on d.id=f.device_id and d.deleted_at is null
  where(f.occurred_at at time zone 'Asia/Dubai')::time between time '10:00'and time '21:00'
  order by f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.device_id,f.occurred_at,f.tie
 )select f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.job_id,f.device_id,f.occurred_at,f.box_number,f.export_grade,coalesce(f.export_grade,q.final_grade,'Unspecified'),d.model,d.storage_gb,d.color,j.receiving_batch_id
 from selected f join public.jobs j on j.id=f.job_id join public.devices d on d.id=f.device_id left join lateral(select o.final_grade from greenloop_private.qdr_ready_outcomes o where o.job_id=f.job_id and o.inspected_at<=f.occurred_at order by o.inspected_at desc limit 1)q on true;$body$;

 create or replace function greenloop_private.rpta_first(p_kind text)returns date language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare result date;box_time timestamptz;stock_out_time timestamptz;
 begin
  if p_kind='received'then
   select(b.received_at at time zone 'Asia/Dubai')::date into result from public.receiving_batches b where b.planned_quantity>0 and b.received_at<=now()and not exists(select 1 from greenloop_private.srp_receipts x where x.replacement_batch_id=b.id)order by b.received_at,b.id limit 1;
  elsif p_kind='ready'then
   select(h.moved_at at time zone 'Asia/Dubai')::date into result from public.device_location_history h join public.locations l on l.id=h.to_location_id join public.jobs j on j.id=h.job_id and j.device_id=h.device_id and j.deleted_at is null join public.devices d on d.id=h.device_id and d.deleted_at is null where l.location_code in('PRODUCTION','READY','READY-STOCK')and h.from_location_id is distinct from h.to_location_id and h.moved_at<=now()and(h.moved_at at time zone 'Asia/Dubai')::time between time '10:00'and time '21:00'order by h.moved_at,h.id limit 1;
  elsif p_kind='export'then
   select w.verified_at into box_time from greenloop_private.box_workflow w join public.export_boxes bx on bx.id=w.box_id join public.export_box_items i on i.box_id=w.box_id and i.scanned_at<=w.verified_at join public.jobs j on j.id=i.job_id and j.device_id=i.device_id and j.deleted_at is null join public.devices d on d.id=i.device_id and d.deleted_at is null where w.state='exported'and w.verified_at<=now()and(w.verified_at at time zone 'Asia/Dubai')::time between time '10:00'and time '21:00'order by w.verified_at,w.box_id limit 1;
   select r.dispatched_at into stock_out_time from public.stock_out_records r join public.jobs j on j.id=r.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null where r.dispatched_at<=now()and(r.dispatched_at at time zone 'Asia/Dubai')::time between time '10:00'and time '21:00'order by r.dispatched_at,r.id limit 1;
   result:=(least(box_time,stock_out_time)at time zone 'Asia/Dubai')::date;
  end if;return result;
 end;$body$;

 create or replace function greenloop_private.rpta_context(day date)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare month_start date:=date_trunc('month',day)::date;lookback date:=(date_trunc('month',day)-interval '3 months')::date;facts jsonb;receipts jsonb;counts jsonb;reports jsonb:='{}';first_days jsonb:='{}';k text;first_day date;month_from date;months integer;days integer;today_total bigint;month_total bigint;daily_total bigint;monthly_total bigint;summary jsonb;names boolean:=coalesce(public.get_my_partner_name_access(),false);
 begin
  select coalesce(jsonb_agg(to_jsonb(f)order by f.kind,f.activity_day,f.device_id),'[]')into facts from greenloop_private.rpta_facts(least(lookback,day-30),day)f;
  select coalesce(jsonb_agg(to_jsonb(r)order by r.receipt_day,r.batch_id),'[]')into receipts from greenloop_private.rsr_receipts(least(lookback,day-30),day)r;
  select count(*)into days from generate_series(1,30)i where extract(dow from day-i)<>0;
  foreach k in array array['ready','export','received']loop
   first_day:=greenloop_private.rpta_first(k);first_days:=first_days||jsonb_build_object(k,first_day);
   month_from:=case when first_day<month_start then greatest(lookback,date_trunc('month',first_day)::date)end;
   months:=case when month_from is null then 0 else extract(year from age(month_start,month_from))::int*12+extract(month from age(month_start,month_from))::int end;
   with units as(select(r->>'activity_day')::date d,1::bigint q from jsonb_array_elements(facts)r where r->>'kind'=k union all select(r->>'receipt_day')::date,(r->>'quantity')::bigint from jsonb_array_elements(receipts)r where k='received')
   select coalesce(sum(q)filter(where d=day),0),coalesce(sum(q)filter(where d>=month_start),0),coalesce(sum(q)filter(where d>=day-30 and d<day and extract(dow from d)<>0),0),coalesce(sum(q)filter(where d>=month_from and d<month_start),0)into today_total,month_total,daily_total,monthly_total from units;
   reports:=reports||jsonb_build_object(k,jsonb_build_object('today',today_total,'month',month_total,'daily_total',daily_total,'daily_average',round(daily_total::numeric/days,2),'monthly_total',monthly_total,'monthly_average',case when months>0 then round(monthly_total::numeric/months,2)end,'monthly_months',months,'monthly_from',month_from,'monthly_to',case when months>0 then month_start-1 end));
  end loop;
  summary:=jsonb_build_object('version','20261117-stock-activity-reports-1','date',day,'as_of',now(),'timezone','Asia/Dubai','month_from',month_start,'month_to',day,'daily_from',day-30,'daily_to',day-1,'daily_days',days,'exclude_sundays',true,'reports',reports,'names_allowed',names);
  summary:=summary||jsonb_build_object('snapshot',md5(jsonb_build_array(day,facts,receipts,first_days,names)::text));
  return jsonb_build_object('summary',summary,'facts',facts,'receipts',receipts);
 end;$body$;

 create or replace function greenloop_private.rpta_scope(ctx jsonb,k text,metric text,period date)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare day date:=(ctx->'summary'->>'date')::date;first date;last date;view text;
 begin
  if k is null or k not in('ready','export','received')or metric is null or metric not in('today','month','daily_average','monthly_average')then raise exception 'Choose a stock activity figure.'using errcode='22023';end if;
  if metric='today'then if period is not null then raise exception 'Today uses the selected activity date.'using errcode='22023';end if;first:=day;last:=day;
  elsif metric='month'and period is null then first:=date_trunc('month',day)::date;last:=day;
  elsif metric='daily_average'then
   first:=day-30;last:=day-1;view:='days';
   if period is not null then if period<first or period>last or extract(dow from period)=0 then raise exception 'Choose a day in this daily-average period.'using errcode='22023';end if;first:=period;last:=period;view:=null;end if;
  else
   first:=(ctx->'summary'->'reports'->k->>'monthly_from')::date;last:=(ctx->'summary'->'reports'->k->>'monthly_to')::date;view:='months';
   if period is not null then if first is null or period<>date_trunc('month',period)::date or period<first or period>last then raise exception 'Choose a completed month in this monthly-average period.'using errcode='22023';end if;first:=period;last:=(period+interval '1 month')::date-1;view:=null;end if;
  end if;
  return jsonb_build_object('from',first,'to',last,'view',coalesce(view,case when k='received'then 'receipts'else 'phones'end));
 end;$body$;

 create or replace function public.get_stock_activity_reports_v1(p_date date default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare day date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);begin perform greenloop_private.rpta_access(day);return greenloop_private.rpta_context(day)->'summary';end;$body$;
 create or replace function public.get_stock_activity_details_v1(p_kind text,p_metric text,p_date date,p_expected text,p_period_date date default null,p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare day date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);ctx jsonb;scope jsonb;first date;last date;rows jsonb;total integer;quantity bigint;names boolean;view text;
 begin
  perform greenloop_private.rpta_access(day,p_metric is distinct from 'today'or p_period_date is not null);
  if p_offset is null or p_offset<0 or p_offset%50<>0 or p_limit is distinct from 50 then raise exception 'Choose a valid50-row activity page.'using errcode='22023';end if;
  ctx:=greenloop_private.rpta_context(day);if p_expected is null or p_expected is distinct from ctx->'summary'->>'snapshot'then raise exception 'Stock activity changed. Refresh the reports and try again.'using errcode='40001';end if;
  scope:=greenloop_private.rpta_scope(ctx,p_kind,p_metric,p_period_date);first:=(scope->>'from')::date;last:=(scope->>'to')::date;view:=scope->>'view';names:=(ctx->'summary'->>'names_allowed')::boolean;
  if view in('days','months')then
   with units as(select(r->>'activity_day')::date d,1::bigint q from jsonb_array_elements(ctx->'facts')r where r->>'kind'=p_kind union all select(r->>'receipt_day')::date,(r->>'quantity')::bigint from jsonb_array_elements(ctx->'receipts')r where p_kind='received'),periods as(
    select x::date lo,case when view='months'then(x+interval '1 month')::date-1 else x::date end hi from generate_series(first::timestamp,last::timestamp,case when view='months'then interval '1 month'else interval '1 day'end)x where view='months'or extract(dow from x)<>0
   )select coalesce(jsonb_agg(jsonb_build_object('from',lo,'to',hi,'quantity',coalesce((select sum(q)from units where d between lo and hi),0))order by lo),'[]')into rows from periods;
  elsif view='receipts'then
   select coalesce(jsonb_agg(jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'quantity',(r->>'quantity')::bigint,'planned_quantity',b.planned_quantity,'received_at',b.received_at,'supplier_code',s.supplier_code,'supplier_name',case when names then s.company_name end)order by b.received_at,b.id),'[]')into rows from jsonb_array_elements(ctx->'receipts')r join public.receiving_batches b on b.id=(r->>'batch_id')::uuid left join public.suppliers s on s.id=b.supplier_id where(r->>'receipt_day')::date between first and last;
  else
   with roots as materialized(select *from greenloop_private.sc_receipts()where parent_batch_id is null)
   select coalesce(jsonb_agg(jsonb_build_object('imei',d.imei_1,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,'grade',r->>'final_grade','occurred_at',r->>'occurred_at','box_number',r->>'box_number','planned_quantity',coalesce(rb.received_quantity,b.planned_quantity),'batch_number',coalesce(rb.batch_number,b.batch_number),'invoice_number',coalesce(rb.invoice_number,b.invoice_number),'supplier_code',s.supplier_code,'supplier_name',case when names then s.company_name end)order by r->>'occurred_at',d.imei_1),'[]')into rows from jsonb_array_elements(ctx->'facts')r join public.devices d on d.id=(r->>'device_id')::uuid join public.jobs j on j.id=(r->>'job_id')::uuid left join public.receiving_batches b on b.id=j.receiving_batch_id left join roots rb on j.receiving_batch_id=any(rb.descendant_ids)left join public.suppliers s on s.id=coalesce(rb.supplier_id,j.supplier_id,b.supplier_id)where r->>'kind'=p_kind and(r->>'activity_day')::date between first and last;
  end if;
  total:=jsonb_array_length(rows);select coalesce(sum(coalesce((r->>'quantity')::bigint,1)),0)into quantity from jsonb_array_elements(rows)r;
  return jsonb_build_object('version','20261117-stock-activity-reports-1','date',day,'kind',p_kind,'metric',p_metric,'period_date',p_period_date,'scope',scope,'snapshot',p_expected,'offset',p_offset,'limit',50,'total',total,'quantity',quantity,'rows',coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(rows)with ordinality a(r,n)where n>p_offset and n<=p_offset+50),'[]'));
 end;$body$;
create or replace function greenloop_private.rpta_groups(p_mode text,p_date date,p_groups jsonb,p_from date,p_to date,p_group jsonb,p_offset integer,p_limit integer,p_show_color boolean,p_payload jsonb)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare day_value date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);names boolean;result jsonb;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('ready_stock','view');
 if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
 if p_show_color is null then raise exception 'Choose Show Color or Hide Color.'using errcode='22023';end if;
 if p_mode is null or p_mode not in('current','ready','export')then raise exception 'Choose a stock report.'using errcode='22023';end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Choose a valid 50-row page.'using errcode='22023';end if;
 if(p_from is null)<>(p_to is null)or(p_from is not null and p_from>p_to)then raise exception 'Choose a valid date range.'using errcode='22023';end if;

 if p_from is not null or(p_mode<>'current'and day_value<>(now()at time zone 'Asia/Dubai')::date)then perform greenloop_private.pf_cap('ready_stock','search');end if;
 if p_mode<>'current'and day_value>(now()at time zone 'Asia/Dubai')::date then raise exception 'Choose today or an earlier date.'using errcode='22023';end if;
 if p_groups is not null then
  if jsonb_typeof(p_groups)<>'array'or jsonb_array_length(p_groups)not between 1 and 10000 then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_groups)g where jsonb_typeof(g)<>'object'or jsonb_typeof(g->'m')is distinct from 'string'or jsonb_typeof(g->'g')is distinct from 'string'or length(g->>'m')not between 1 and 1000 or length(g->>'g')not between 1 and 200)then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
 end if;
 if p_group is not null then if jsonb_typeof(p_group)<>'array'or jsonb_array_length(p_group)<>6 then raise exception 'Choose a summary line.'using errcode='22023';end if;end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with facts as materialized(select (r->>'job_id')::uuid job_id,(r->>'device_id')::uuid device_id,(r->>'occurred_at')::timestamptz occurred_at,r->>'box_number'box_number,r->>'final_grade'final_grade from jsonb_array_elements(p_payload)r where r->>'kind'=p_mode and(r->>'activity_day')::date between p_from and p_to),
 receipts as materialized(select *from greenloop_private.sc_receipts()where parent_batch_id is null),base as materialized(select f.*,d.imei_1 imei,d.device_number,coalesce(nullif(btrim(d.model),''),'Unknown model')model,d.storage_gb,d.color actual_color,case when p_show_color then d.color end color,coalesce(rb.batch_id,b.id)batch_id,coalesce(rb.batch_number,b.batch_number)batch_number,coalesce(rb.invoice_number,b.invoice_number)invoice_number,coalesce(rb.received_quantity,b.planned_quantity)planned_quantity,sp.id supplier_id,sp.supplier_code,case when names then sp.company_name end supplier_name,
  jsonb_build_array(coalesce(nullif(btrim(d.model),''),'Unknown model'),d.storage_gb,case when p_show_color then d.color end,f.final_grade,coalesce(rb.batch_id,b.id),sp.id)group_key
  from facts f join public.devices d on d.id=f.device_id join public.jobs j on j.id=f.job_id left join public.receiving_batches b on b.id=j.receiving_batch_id left join receipts rb on j.receiving_batch_id=any(rb.descendant_ids)left join public.suppliers sp on sp.id=coalesce(rb.supplier_id,j.supplier_id,b.supplier_id)),
 grouped as materialized(select group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,planned_quantity,supplier_code,supplier_name,count(*)quantity from base group by group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,planned_quantity,supplier_code,supplier_name),
 summary_page as(select *from grouped order by model,storage_gb,color,final_grade,batch_number,group_key offset p_offset limit p_limit),
 phone_page as(select *from base where group_key=p_group order by imei,device_id,occurred_at offset p_offset limit p_limit)
 select jsonb_build_object('mode',p_mode,'show_color',p_show_color,'date',case when p_mode<>'current'then day_value end,'view',case when p_group is null then 'groups'else 'phones'end,'offset',p_offset,'limit',p_limit,
  'total',case when p_group is null then(select count(*)from grouped)else(select count(*)from base where group_key=p_group)end,'phone_total',(select count(*)from base),
  'rows',case when p_group is null then coalesce((select jsonb_agg(to_jsonb(s)order by model,storage_gb,color,final_grade,batch_number,group_key)from summary_page s),'[]'::jsonb)else coalesce((select jsonb_agg(jsonb_build_object('imei',imei,'device_number',device_number,'model',model,'storage_gb',storage_gb,'color',actual_color,'final_grade',final_grade,'batch_number',batch_number,'invoice_number',invoice_number,'planned_quantity',planned_quantity,'supplier_code',supplier_code,'supplier_name',supplier_name,'occurred_at',occurred_at,'box_number',box_number)order by imei,device_id,occurred_at)from phone_page),'[]'::jsonb)end)into result;
 return result;
end;$$;
create or replace function greenloop_private.rpta_models(p_mode text,p_date date,p_groups jsonb,p_from date,p_to date,p_view text,p_model text,p_cell jsonb,p_offset integer,p_limit integer,p_expected_snapshot text,p_payload jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare day_value date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);names boolean;result jsonb;payload jsonb;token text;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('ready_stock','view');
 if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
 if p_mode is null or p_mode not in('current','ready','export')then raise exception 'Choose a stock report.'using errcode='22023';end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Choose a valid 50-row page.'using errcode='22023';end if;
 if(p_from is null)<>(p_to is null)or(p_from is not null and p_from>p_to)then raise exception 'Choose a valid date range.'using errcode='22023';end if;

 if p_from is not null or(p_mode<>'current'and day_value<>(now()at time zone 'Asia/Dubai')::date)then perform greenloop_private.pf_cap('ready_stock','search');end if;
 if p_mode<>'current'and day_value>(now()at time zone 'Asia/Dubai')::date then raise exception 'Choose today or an earlier date.'using errcode='22023';end if;
 if p_groups is not null then
  if jsonb_typeof(p_groups)<>'array'or jsonb_array_length(p_groups)not between 1 and 10000 then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_groups)g where jsonb_typeof(g)<>'object'or jsonb_typeof(g->'m')is distinct from 'string'or jsonb_typeof(g->'g')is distinct from 'string'or length(g->>'m')not between 1 and 1000 or length(g->>'g')not between 1 and 200)then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
 end if;

 if p_view is null or p_view not in('models','breakdown','phones')or(p_view='models'and(p_model is not null or p_cell is not null))or(p_view<>'models'and(nullif(btrim(p_model),'')is null or length(p_model)>1000))or(p_view<>'phones'and p_cell is not null)then raise exception 'Choose a model summary or exact model.'using errcode='22023';end if;
 if p_view='phones'then
  if jsonb_typeof(p_cell)is distinct from 'object'or not(p_cell?'storage_gb'and p_cell?'grade_key')or(select count(*)from jsonb_object_keys(p_cell))<>2 or jsonb_typeof(p_cell->'grade_key')is distinct from 'string'or length(p_cell->>'grade_key')not between 1 and 200 or jsonb_typeof(p_cell->'storage_gb')not in('number','null')then raise exception 'Choose one GB and grade quantity.'using errcode='22023';end if;
  if p_cell->>'storage_gb'is not null then if(p_cell->>'storage_gb')!~'^[0-9]{1,6}$'then raise exception 'Choose valid GB.'using errcode='22023';end if;end if;
 end if;
 if(p_expected_snapshot is not null and p_expected_snapshot!~'^[a-f0-9]{32}$')or(p_view<>'models'and p_expected_snapshot is null)then raise exception 'Refresh the model summary before opening details.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with facts as materialized(select (r->>'job_id')::uuid job_id,(r->>'device_id')::uuid device_id,(r->>'occurred_at')::timestamptz occurred_at,r->>'box_number'box_number,r->>'final_grade'final_grade from jsonb_array_elements(p_payload)r where r->>'kind'=p_mode and(r->>'activity_day')::date between p_from and p_to),receipts as materialized(select *from greenloop_private.sc_receipts()where parent_batch_id is null),base as materialized(
  select f.*,d.imei_1 imei,coalesce(nullif(regexp_replace(btrim(d.model),'^iPhone\s+','','i'),''),'Unknown model')model,lower(regexp_replace(coalesce(nullif(regexp_replace(btrim(d.model),'^iPhone\s+','','i'),''),'Unknown model'),'\s+',' ','g'))model_key,d.storage_gb,d.color,
   lower(regexp_replace(btrim(coalesce(nullif(btrim(f.final_grade),''),'Unspecified')),'\s+',' ','g'))grade_key,coalesce(rb.batch_id,b.id)batch_id,coalesce(rb.batch_number,b.batch_number)batch_number,coalesce(rb.invoice_number,b.invoice_number)invoice_number,coalesce(rb.received_quantity,b.planned_quantity)planned_quantity,sp.supplier_code,case when names then sp.company_name end supplier_name
  from facts f join public.devices d on d.id=f.device_id join public.jobs j on j.id=f.job_id left join public.receiving_batches b on b.id=j.receiving_batch_id left join receipts rb on j.receiving_batch_id=any(rb.descendant_ids)left join public.suppliers sp on sp.id=coalesce(rb.supplier_id,j.supplier_id,b.supplier_id)
 )select coalesce(jsonb_agg(to_jsonb(b)order by b.model_key,b.storage_gb,b.grade_key,b.imei,b.job_id,b.occurred_at),'[]')into payload from base b;
 token:=md5(jsonb_build_array(p_mode,case when p_mode<>'current'then day_value end,p_groups,p_from,p_to,payload)::text);
 if p_expected_snapshot is not null and p_expected_snapshot<>token then raise exception 'Ready Stock changed. Refresh Model Summary before opening details.'using errcode='40001';end if;
 with base as materialized(select value r from jsonb_array_elements(payload)),models as materialized(select r->>'model_key'key,min(r->>'model')model,count(*)quantity from base group by r->>'model_key'),selected as materialized(select r from base where r->>'model_key'=p_model),grades as materialized(
  select r->>'grade_key'key,case when r->>'grade_key'in('a','b','d','ba','bb','rma')then upper(r->>'grade_key')else min(r->>'final_grade')end label,count(*)quantity from selected group by r->>'grade_key'
 ),buckets as materialized(select nullif(r->>'storage_gb','')::integer storage_gb,count(*)quantity from selected group by nullif(r->>'storage_gb','')::integer),cells as materialized(select nullif(r->>'storage_gb','')::integer storage_gb,r->>'grade_key'grade_key,count(*)quantity from selected group by nullif(r->>'storage_gb','')::integer,r->>'grade_key'),phones as materialized(select r from selected where nullif(r->>'storage_gb','')::integer is not distinct from nullif(p_cell->>'storage_gb','')::integer and r->>'grade_key'=p_cell->>'grade_key')
 select jsonb_build_object('version','20261113-ready-stock-models-1','mode',p_mode,'date',case when p_mode<>'current'then day_value end,'view',p_view,'offset',p_offset,'limit',p_limit,'snapshot',token,'model_key',p_model,'model',(select model from models where key=p_model),'cell',p_cell,'names_allowed',names,'phone_total',jsonb_array_length(payload),'model_total',(select count(*)from selected),'total',case p_view when 'models'then(select count(*)from models)when 'breakdown'then(select count(*)from buckets)else(select count(*)from phones)end,
 'grades',case when p_view='models'then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(g)order by case key when 'a'then 1 when 'b'then 2 when 'd'then 3 when 'ba'then 4 when 'bb'then 5 when 'rma'then 6 else 7 end,key)from grades g),'[]')end,
 'rows',case p_view when 'models'then coalesce((select jsonb_agg(to_jsonb(m)order by lower(model),key)from(select *from models order by lower(model),key offset p_offset limit p_limit)m),'[]')when 'breakdown'then coalesce((select jsonb_agg(to_jsonb(b)||jsonb_build_object('grades',(select coalesce(jsonb_agg(to_jsonb(c)order by grade_key),'[]')from cells c where c.storage_gb is not distinct from b.storage_gb))order by b.storage_gb nulls last)from(select *from buckets order by storage_gb nulls last offset p_offset limit p_limit)b),'[]')else coalesce((select jsonb_agg(r order by r->>'imei',r->>'job_id')from(select r from phones order by r->>'imei',r->>'job_id'offset p_offset limit p_limit)p),'[]')end)into result;
 return result;
end;$$;

 create or replace function public.get_stock_activity_grouped_v1(p_kind text,p_metric text,p_date date,p_expected text,p_period_date date default null,p_view text default 'groups',p_group jsonb default null,p_model text default null,p_cell jsonb default null,p_offset integer default 0,p_show_color boolean default false,p_model_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare ctx jsonb;scope jsonb;first date;last date;result jsonb;
 begin
  perform greenloop_private.rpta_access(p_date,true);
  ctx:=greenloop_private.rpta_context(p_date);if p_expected is null or p_expected is distinct from ctx->'summary'->>'snapshot'then raise exception 'Stock activity changed. Refresh the reports and try again.'using errcode='40001';end if;
  scope:=greenloop_private.rpta_scope(ctx,p_kind,p_metric,p_period_date);first:=(scope->>'from')::date;last:=(scope->>'to')::date;
  if p_kind='received'or scope->>'view'<>'phones'or first is null or last is null then raise exception 'Choose a production or export phone period.'using errcode='22023';end if;
  if p_view='groups'then
   if p_model is not null or p_cell is not null or p_model_snapshot is not null then raise exception 'Choose a valid stock group.'using errcode='22023';end if;
   result:=greenloop_private.rpta_groups(p_kind,p_date,null,first,last,p_group,p_offset,50,p_show_color,ctx->'facts');
  elsif p_view in('models','breakdown','phones')then
   if p_group is not null then raise exception 'Choose a valid model summary.'using errcode='22023';end if;
   result:=greenloop_private.rpta_models(p_kind,p_date,null,first,last,p_view,p_model,p_cell,p_offset,50,p_model_snapshot,ctx->'facts');
  else raise exception 'Choose a stock group or model.'using errcode='22023';end if;
  return result||jsonb_build_object('activity_snapshot',p_expected);
 end;$body$;
 revoke all on function greenloop_private.rpta_access(date,boolean) from public,anon,authenticated;
 revoke all on function greenloop_private.rpta_facts(date,date) from public,anon,authenticated;
 revoke all on function greenloop_private.rpta_first(text) from public,anon,authenticated;
 revoke all on function greenloop_private.rpta_context(date) from public,anon,authenticated;
 revoke all on function greenloop_private.rpta_scope(jsonb,text,text,date) from public,anon,authenticated;
 revoke all on function public.get_stock_activity_reports_v1(date) from public,anon,authenticated;
 grant execute on function public.get_stock_activity_reports_v1(date) to authenticated;
 revoke all on function public.get_stock_activity_details_v1(text,text,date,text,date,integer,integer) from public,anon,authenticated;
 grant execute on function public.get_stock_activity_details_v1(text,text,date,text,date,integer,integer) to authenticated;
 revoke all on function greenloop_private.rpta_groups(text,date,jsonb,date,date,jsonb,integer,integer,boolean,jsonb) from public,anon,authenticated;
 revoke all on function greenloop_private.rpta_models(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text,jsonb) from public,anon,authenticated;
 revoke all on function public.get_stock_activity_grouped_v1(text,text,date,text,date,text,jsonb,text,jsonb,integer,boolean,text) from public,anon,authenticated;
 grant execute on function public.get_stock_activity_grouped_v1(text,text,date,text,date,text,jsonb,text,jsonb,integer,boolean,text) to authenticated;
 insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_stock_activity_reports_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_stock_activity_details_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_stock_activity_grouped_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_stock_activity_reports_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
 create or replace function public.get_stock_activity_reports_version()returns text language sql stable security definer set search_path=pg_catalog,public as $body$ select case when public.get_ready_stock_received_daily_version()='20261117-ready-stock-received-daily-1'and(select count(*)=11 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.stock_activity_installation)
 and not exists(select 1 from greenloop_private.stock_activity_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='greenloop_private'::regnamespace and(has_function_privilege('anon',p.oid,'EXECUTE')or has_function_privilege('authenticated',p.oid,'EXECUTE')))and exists(select 1 from pg_class where oid='greenloop_private.stock_activity_installation'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.stock_activity_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.stock_activity_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','public.get_stock_activity_reports_v1(date)','EXECUTE')and has_function_privilege('authenticated','public.get_stock_activity_reports_v1(date)','EXECUTE')
 and not has_function_privilege('anon','public.get_stock_activity_details_v1(text,text,date,text,date,integer,integer)','EXECUTE')and has_function_privilege('authenticated','public.get_stock_activity_details_v1(text,text,date,text,date,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','public.get_stock_activity_grouped_v1(text,text,date,text,date,text,jsonb,text,jsonb,integer,boolean,text)','EXECUTE')and has_function_privilege('authenticated','public.get_stock_activity_grouped_v1(text,text,date,text,date,text,jsonb,text,jsonb,integer,boolean,text)','EXECUTE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_activity_reports_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_activity_details_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_activity_grouped_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_activity_reports_version'and rule='{"read":true}'::jsonb)
 and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then '20261117-stock-activity-reports-1'end;$body$;
 revoke all on function public.get_stock_activity_reports_version()from public;grant execute on function public.get_stock_activity_reports_version()to anon,authenticated;
 insert into greenloop_private.stock_activity_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rpta_access(date,boolean)','greenloop_private.rpta_facts(date,date)','greenloop_private.rpta_first(text)','greenloop_private.rpta_context(date)','greenloop_private.rpta_scope(jsonb,text,text,date)','public.get_stock_activity_reports_v1(date)','public.get_stock_activity_details_v1(text,text,date,text,date,integer,integer)','greenloop_private.rpta_groups(text,date,jsonb,date,date,jsonb,integer,integer,boolean,jsonb)','greenloop_private.rpta_models(text,date,jsonb,date,date,text,text,jsonb,integer,integer,text,jsonb)','public.get_stock_activity_grouped_v1(text,text,date,text,date,text,jsonb,text,jsonb,integer,boolean,text)','public.get_stock_activity_reports_version()'])s on conflict(identity)do update set hash=excluded.hash;
 if public.get_stock_activity_reports_version()is distinct from '20261117-stock-activity-reports-1'then raise exception 'Stock activity verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$activity_install$;
select public.get_stock_activity_reports_version()as installed_stock_activity_reports_version;
