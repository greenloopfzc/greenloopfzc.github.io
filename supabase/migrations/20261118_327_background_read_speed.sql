-- Fresh read optimization only: complete counters, reports and business checks remain.
do $install$
declare sig text;old text;updated text;api text;api_oid oid;target_oid oid;office_oid oid;n integer;t record;c record;b record;verified boolean;
 reviewed jsonb:='[]';sealed text[]:='{}';source_view_hash text;
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_background_read_speed_version()')is not null then
  if public.get_background_read_speed_version()is distinct from '20261118-background-read-speed-1'then raise exception 'Existing background read integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_operational_loading_version()is distinct from '20261118-operational-loading-1'or public.get_issuance_grade_edit_version()is distinct from '20261118-issuance-grade-edit-1'then raise exception 'Install the verified operational loading and Issuance Grade prerequisites first.';end if;
 create table greenloop_private.background_read_installation(identity text primary key,hash text not null);
 alter table greenloop_private.background_read_installation enable row level security;
 revoke all on greenloop_private.background_read_installation from public,anon,authenticated;
 create table greenloop_private.background_read_sources(source text primary key,hash text not null);
 alter table greenloop_private.background_read_sources enable row level security;
 revoke all on greenloop_private.background_read_sources from public,anon,authenticated;
sig:='greenloop_private.lab_stays_v1(uuid)';
old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for c in select *from(values('identity','hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2)',t.name,c.idcol,c.hashcol)into verified using sig,md5(old);exit when verified;
 end loop;exit when verified;
end loop;
if not verified then raise exception 'Source integrity differs: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,'FUNCTION\s+greenloop_private\.lab_stays_v1\(','g');if n<>1 then raise exception 'Lab stay source boundary differs.';end if;
updated:=regexp_replace(updated,'FUNCTION\s+greenloop_private\.lab_stays_v1\(','FUNCTION greenloop_private.bgr_stays(','g');
select count(*)into n from regexp_matches(updated,$pat$\),\s*entries\s*as\s*\(\s*select\s*e\.device_id,e\.job_id,e\.moved_at,\(select\s*min\(x\.moved_at\)\s*from\s*movements\s*x\s*where\s*x\.job_id=e\.job_id\s*and\s*x\.device_id=e\.device_id\s*and\s*x\.from_lab\s*and\s*not\s*x\.to_lab\s*and\s*x\.moved_at>=e\.moved_at\)\s*ended\s*from\s*movements\s*e\s*where\s*e\.to_lab\s*and\s*not\s*e\.from_lab\s*\),\s*stays\s*as$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$\),\s*entries\s*as\s*\(\s*select\s*e\.device_id,e\.job_id,e\.moved_at,\(select\s*min\(x\.moved_at\)\s*from\s*movements\s*x\s*where\s*x\.job_id=e\.job_id\s*and\s*x\.device_id=e\.device_id\s*and\s*x\.from_lab\s*and\s*not\s*x\.to_lab\s*and\s*x\.moved_at>=e\.moved_at\)\s*ended\s*from\s*movements\s*e\s*where\s*e\.to_lab\s*and\s*not\s*e\.from_lab\s*\),\s*stays\s*as$pat$,$repl$), sequenced as (
 select e.*,min(e.moved_at)filter(where e.from_lab and not e.to_lab)over(partition by e.job_id,e.device_id order by e.moved_at range between current row and unbounded following) ended from movements e
 ),entries as(select device_id,job_id,moved_at,ended from sequenced where to_lab and not from_lab), stays as$repl$,'g');
execute updated;
revoke all on function greenloop_private.bgr_stays(uuid)from public,anon,authenticated;sealed:=array_append(sealed,'greenloop_private.bgr_stays(uuid)');
sig:=$sql$greenloop_private.sbn_counts()$sql$;
old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for c in select *from(values('identity','hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2)',t.name,c.idcol,c.hashcol)into verified using sig,md5(old);exit when verified;
 end loop;exit when verified;
end loop;
if not verified then raise exception 'Source integrity differs: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,$pat$select\s*coalesce\(sum\(remaining_quantity\),0\)into\s*n\s*from\s*public\.get_open_stock_entry_batches_with_lines\(\);$pat$,'g');
if n=0 then if not(position('greenloop_private.supplier_return_batch(b.id)'in updated)>0)then raise exception 'Count boundary changed: %',sig;end if;else
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$select\s*coalesce\(sum\(remaining_quantity\),0\)into\s*n\s*from\s*public\.get_open_stock_entry_batches_with_lines\(\);$pat$,$repl$if not public.is_active_staff()or not(public.has_page_access('imei_entry')or public.has_page_access('stock_received'))then raise exception 'Stock Received or IMEI Entry view permission is required.'using errcode='42501';end if;
 select coalesce(sum(remaining),0)into n from(
 select (greenloop_private.supplier_return_batch(b.id)->>'remaining_quantity')::integer remaining
 from public.receiving_batches b join public.stock_channels c on c.id=b.stock_channel_id join public.suppliers sp on sp.id=b.supplier_id
 where b.planned_quantity is not null and c.is_active and sp.is_active and sp.deleted_at is null offset 0)x where remaining>0;$repl$,'g');
end if;
select count(*)into n from regexp_matches(updated,$pat$select\s*count\(\*\)into\s*n\s*from\s*greenloop_private\.qcis_rows\(null\);$pat$,'g');
if n=0 then if not(position('greenloop_private.qc_saved_issuance'in updated)>0 and position('greenloop_private.qcis_rows(null)'in updated)=0)then raise exception 'Count boundary changed: %',sig;end if;else
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$select\s*count\(\*\)into\s*n\s*from\s*greenloop_private\.qcis_rows\(null\);$pat$,$repl$select count(*)into n from greenloop_private.qc_saved_issuance s
 join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id
 join public.jobs j on j.id=s.job_id and j.deleted_at is null and greenloop_private.company_job_available(j.id)and j.current_status='initial_qc_pending'
 join public.devices d on d.id=s.device_id and d.deleted_at is null where s.state='awaiting_issuance';$repl$,'g');
end if;
select count(*)into n from regexp_matches(updated,$pat$from\s*greenloop_private\.parts_flow_orders\s*o\s*join\s*greenloop_private\.parts_flow_requests$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$from\s*greenloop_private\.parts_flow_orders\s*o\s*join\s*greenloop_private\.parts_flow_requests$pat$,$repl$from greenloop_private.parts_flow_orders o join bgr_cycles bc on bc.id=o.id join greenloop_private.parts_flow_requests$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$greenloop_private\.pf_cycle\(o\.job_id\)$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$greenloop_private\.pf_cycle\(o\.job_id\)$pat$,$repl$(bc.cycle)$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$select\s*count\(distinct\s*imei\)into\s*n\s*from\($pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$select\s*count\(distinct\s*imei\)into\s*n\s*from\($pat$,$repl$with bgr_stay_counts as materialized(select device_id,job_id,count(*)::integer cycle from greenloop_private.bgr_stays(null)group by device_id,job_id),bgr_cycles as materialized (
 select o.id,coalesce(st.cycle,0)cycle
 from greenloop_private.parts_flow_orders o join public.jobs j on j.id=o.job_id
 left join bgr_stay_counts st on st.job_id=j.id and st.device_id=j.device_id
 where o.completed_at is null and j.deleted_at is null
 and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
) select count(distinct imei)into n from($repl$,'g');
execute updated;
sig:=$sql$greenloop_private.loc_rows()$sql$;
old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for c in select *from(values('identity','hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2)',t.name,c.idcol,c.hashcol)into verified using sig,md5(old);exit when verified;
 end loop;exit when verified;
end loop;
if not verified then raise exception 'Source integrity differs: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,$pat$greenloop_private\.tv_work_seconds\(st\.entered_at,now\(\)\)$pat$,'g');
if n<>2 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$greenloop_private\.tv_work_seconds\(st\.entered_at,now\(\)\)$pat$,$repl$st.elapsed_work$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$from\s*greenloop_private\.lab_stays_v1\(null\)st$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$from\s*greenloop_private\.lab_stays_v1\(null\)st$pat$,$repl$from overdue_stays st$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$left\s*join\s*greenloop_private\.sc_receipts\(\)r$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$left\s*join\s*greenloop_private\.sc_receipts\(\)r$pat$,$repl$left join receipt_labels r$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$select\s*distinct\s*on\(st\.device_id\)$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$select\s*distinct\s*on\(st\.device_id\)$pat$,$repl$with names as materialized(select coalesce(public.get_my_partner_name_access(),false)allowed),
 receipt_labels as materialized(select b.id batch_id,b.planned_quantity::bigint received_quantity,s.supplier_code,case when n.allowed then s.company_name end supplier_name,b.batch_number,b.invoice_number from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id cross join names n),
 overdue_stays as materialized(select st.*,greenloop_private.tv_work_seconds(st.entered_at,now()) elapsed_work from greenloop_private.bgr_stays(null)st where st.ongoing)
 select distinct on(st.device_id)$repl$,'g');
execute updated;
sig:=$sql$greenloop_private.tvm_tv_read_get_manual_damage_cards_v6(integer,integer,integer)$sql$;
old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for c in select *from(values('identity','hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
 and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2)',t.name,c.idcol,c.hashcol)into verified using sig,md5(old);exit when verified;
 end loop;exit when verified;
end loop;
if not verified then raise exception 'Source integrity differs: %',sig;end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);updated:=old;
if position('tvm_tv_read_get_manual_damage_cards_v5'in old)=0 or position('tvm_tv_selected_damage_copy_values'in old)=0 then raise exception 'TV card boundary changed.';end if;
execute $definition$create or replace function greenloop_private.tvm_tv_read_get_manual_damage_cards_v6(p_offset integer default 0,p_limit integer default 100,p_row_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $tv$
declare result jsonb;v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,4),100));v_rows integer:=greatest(1,least(coalesce(p_row_limit,6),100));
 v_today date:=(now()at time zone 'Asia/Dubai')::date;v_month timestamp:=date_trunc('month',now()at time zone 'Asia/Dubai');
begin
 if not greenloop_private.damage_tv_access()then raise exception 'Damage Report view permission required.'using errcode='42501';end if;
 -- One fresh, account-scoped source for the entire board. No persisted snapshot.
 with damage as materialized(select *from greenloop_private.tv_month_damage),
 options as materialized(select id,label,normalized_label,sort_order from greenloop_private.tv_selected_options where kind='employee'and is_active),
 employee_page as materialized(select *from options order by sort_order,id offset v_offset limit v_limit),
 matches as materialized(select e.id _employee_id,d.*from employee_page e join damage d on d.employee_id=e.id or(d.employee_id is null and greenloop_private.manual_damage_normalized(d.damaged_by)=e.normalized_label)),
 totals as materialized(select _employee_id,count(*) record_count,sum(quantity) total_damage,
  coalesce(sum(quantity)filter(where price_amount is null or currency is null),0) unpriced_quantity,
  coalesce(sum(quantity)filter(where copy_price_amount is null or currency is null),0) copy_unpriced_quantity from matches group by _employee_id),
 value_lines as materialized(select _employee_id,currency,round(sum(price_amount*quantity),2)::text amount,sum(quantity) quantity from matches where price_amount is not null and currency is not null group by _employee_id,currency),
 copy_lines as materialized(select _employee_id,currency,round(sum(copy_price_amount*quantity),2)::text amount,sum(quantity)::bigint quantity from matches where copy_price_amount is not null and currency is not null group by _employee_id,currency),
 values_all as(select currency,round(sum(price_amount*quantity),2)::text amount,sum(quantity) quantity from damage where price_amount is not null and currency is not null group by currency),
 copies_all as(select currency,round(sum(copy_price_amount*quantity),2)::text amount,sum(quantity)::bigint quantity from damage where copy_price_amount is not null and currency is not null group by currency),
 employees as (
 select e.sort_order,e.id,jsonb_build_object('id',e.id,'name',e.label,'total_damage',coalesce(t.total_damage,0),'record_count',coalesce(t.record_count,0),'has_more',v_rows<coalesce(t.record_count,0),
 'value_totals',coalesce((select jsonb_agg(jsonb_build_object('currency',currency,'amount',amount,'quantity',quantity)order by currency)from value_lines v where v._employee_id=e.id),'[]'::jsonb),
 'unpriced_quantity',coalesce(t.unpriced_quantity,0),
 'copy_value_totals',coalesce((select jsonb_agg(jsonb_build_object('currency',currency,'amount',amount,'quantity',quantity)order by currency)from copy_lines v where v._employee_id=e.id),'[]'::jsonb),
 'copy_unpriced_quantity',coalesce(t.copy_unpriced_quantity,0),
 'rows',coalesce((select jsonb_agg(to_jsonb(r)order by r.occurred_at desc,r.id desc)from(select id,occurred_at,model,part_name,reason,identifier,reported_by,created_at,quantity,price_amount,currency_id,currency,part_source_id,part_source,copy_price_amount from matches m where m._employee_id=e.id order by occurred_at desc,id desc limit v_rows)r),'[]'::jsonb)) data
 from employee_page e left join totals t on t._employee_id=e.id
 ),activity as(select id,damaged_by,model,identifier,part_name,quantity,price_amount,currency,part_source,reason,occurred_at,reported_by,created_at,copy_price_amount from damage order by created_at desc,id desc limit 5)
 select jsonb_build_object('employee_count',(select count(*)from options),'today_count',coalesce(sum(quantity)filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai'and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),0),
 'month_count',coalesce(sum(quantity)filter(where occurred_at>=v_month at time zone 'Asia/Dubai'and occurred_at<(v_month+interval '1 month')at time zone 'Asia/Dubai'),0),
 'total_count',coalesce(sum(quantity),0),'record_count',count(*),'has_more',v_offset::bigint+v_limit<(select count(*)from options),
 'employees',coalesce((select jsonb_agg(e.data order by e.sort_order,e.id)from employees e),'[]'::jsonb),
 'activity',coalesce((select jsonb_agg(to_jsonb(a)order by a.created_at desc,a.id desc)from activity a),'[]'::jsonb),
 'value_totals',coalesce((select jsonb_agg(to_jsonb(v)order by currency)from values_all v),'[]'::jsonb),
 'unpriced_quantity',coalesce(sum(quantity)filter(where price_amount is null or currency is null),0),
 'copy_value_totals',coalesce((select jsonb_agg(to_jsonb(v)order by currency)from copies_all v),'[]'::jsonb),
 'copy_unpriced_quantity',coalesce(sum(quantity)filter(where copy_price_amount is null or currency is null),0))into result from damage;
 return result;
end;$tv$;$definition$;
api:='public.get_parts_pending_imei_counts_v1()';api_oid:=to_regprocedure(api);
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,office_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if n<>1 or office_oid is null then raise exception 'Missing or ambiguous Parts Office implementation.';end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=office_oid and original_hash=md5(pg_get_functiondef(office_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Parts Office integrity differs.';end if;
if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=office_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Parts Office implementation.';end if;
target_oid:=office_oid;
if position('into ordered'in pg_get_functiondef(target_oid))=0 then
 select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.capability_routines where to_regprocedure(identity)in(api_oid,office_oid);
 if n<>1 or target_oid is null then raise exception 'Missing or ambiguous Parts capability implementation.';end if;
 if not exists(select 1 from greenloop_private.capability_routines where to_regprocedure(implementation)=target_oid and to_regprocedure(identity)in(api_oid,office_oid)and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Parts capability integrity differs.';end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(office_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Parts capability implementation.';end if;
end if;
if not exists(select 1 from pg_proc where oid=target_oid and pronamespace='greenloop_private'::regnamespace and prosecdef and pronargs=0 and prorettype='jsonb'::regtype)then raise exception 'Parts implementation shape differs.';end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);sealed:=array_append(sealed,api);sealed:=array_append(sealed,office_oid::regprocedure::text);
select count(*)into n from regexp_matches(updated,$pat$from\s*greenloop_private\.parts_flow_orders\s*o\s*join\s*greenloop_private\.parts_flow_requests$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$from\s*greenloop_private\.parts_flow_orders\s*o\s*join\s*greenloop_private\.parts_flow_requests$pat$,$repl$from greenloop_private.parts_flow_orders o join bgr_cycles bc on bc.id=o.id join greenloop_private.parts_flow_requests$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$greenloop_private\.pf_cycle\(o\.job_id\)$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$greenloop_private\.pf_cycle\(o\.job_id\)$pat$,$repl$(bc.cycle)$repl$,'g');
select count(*)into n from regexp_matches(updated,$pat$select\s*count\(distinct\s*d\.id\)::bigint\s*into\s*ordered$pat$,'g');
if n<>1 then raise exception 'Read boundary changed: %',sig;end if;updated:=regexp_replace(updated,$pat$select\s*count\(distinct\s*d\.id\)::bigint\s*into\s*ordered$pat$,$repl$with bgr_stay_counts as materialized(select device_id,job_id,count(*)::integer cycle from greenloop_private.bgr_stays(null)group by device_id,job_id),bgr_cycles as materialized (
 select o.id,coalesce(st.cycle,0)cycle
 from greenloop_private.parts_flow_orders o join public.jobs j on j.id=o.job_id
 left join bgr_stay_counts st on st.job_id=j.id and st.device_id=j.device_id
 where o.completed_at is null and j.deleted_at is null
 and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
) select count(distinct d.id)::bigint into ordered$repl$,'g');
execute updated;

-- Advance only receipts that still exactly match the reviewed prior definition.
for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
end loop;
insert into greenloop_private.background_read_sources values('greenloop_private.tv_month_damage',md5(pg_get_viewdef('greenloop_private.tv_month_damage'::regclass,true)));
create or replace function public.get_background_read_speed_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_operational_loading_version()='20261118-operational-loading-1'and public.get_issuance_grade_edit_version()='20261118-issuance-grade-edit-1'
and(select count(*)>=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.background_read_installation)
and(select count(*)=1 and bool_and(hash=md5(pg_get_viewdef(source::regclass,true)))from greenloop_private.background_read_sources)
and not exists(select 1 from greenloop_private.background_read_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and not exists(select 1 from pg_class where oid in('greenloop_private.background_read_installation'::regclass,'greenloop_private.background_read_sources'::regclass)and not relrowsecurity)
and not has_table_privilege('anon','greenloop_private.background_read_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.background_read_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and not has_table_privilege('anon','greenloop_private.background_read_sources','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.background_read_sources','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261118-background-read-speed-1'end;$version$;
revoke all on function public.get_background_read_speed_version()from public;grant execute on function public.get_background_read_speed_version()to anon,authenticated;
sealed:=array_append(sealed,'public.get_background_read_speed_version()');
execute replace(pg_get_functiondef('public.get_background_read_speed_version()'::regprocedure),'count(*)>=6','count(*)='||(select count(distinct s)::text from unnest(sealed)s));
insert into greenloop_private.background_read_installation select distinct identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_background_read_speed_version()is distinct from '20261118-background-read-speed-1'then raise exception 'Background read verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_background_read_speed_version()as installed_background_read_speed_version;
