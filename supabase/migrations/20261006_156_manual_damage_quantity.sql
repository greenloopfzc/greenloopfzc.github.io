-- Damage Entry quantity. One report can record several identical damaged parts.
-- Original submissions, prices and past audit snapshots remain immutable.
begin;
do $preflight$ begin
 if to_regprocedure('public.get_manual_damage_price_version()') is null or public.get_manual_damage_price_version() is distinct from '20261005-manual-damage-price-1' then
  raise exception 'Install the verified Manual Damage Price update first. Nothing installed.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_manual_damage_quantity_version()') is not null then
  if public.get_manual_damage_quantity_version() is distinct from '20261006-damage-quantity-1' then raise exception 'Existing Damage Quantity update differs. Nothing installed.' using errcode='55000'; end if;
 elsif to_regclass('greenloop_private.manual_damage_submission_quantities') is not null or to_regclass('greenloop_private.manual_damage_quantity_installation') is not null
 or exists(select 1 from pg_proc where pronamespace in ('public'::regnamespace,'greenloop_private'::regnamespace) and proname in ('create_manual_damage_report_v4','correct_manual_damage_report_v3','get_manual_damage_report_v2','get_manual_damage_cards_v2','get_manual_damage_employee_rows_v2','validate_manual_damage_quantity','prevent_manual_damage_quantity_changes','manual_damage_quantity_schema')) then
  raise exception 'Unexpected Damage Quantity objects. Nothing installed.' using errcode='55000';
 end if;
end; $preflight$;
create table if not exists greenloop_private.manual_damage_submission_quantities(report_id uuid primary key,quantity integer not null check(quantity between 1 and 99999));
alter table greenloop_private.manual_damage_submission_quantities enable row level security;
revoke all on greenloop_private.manual_damage_submission_quantities from public,anon,authenticated;
create or replace function greenloop_private.prevent_manual_damage_quantity_changes()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $immutable$
begin raise exception 'Original damage quantities are permanent.' using errcode='42501'; end; $immutable$;
revoke all on function greenloop_private.prevent_manual_damage_quantity_changes() from public,anon,authenticated;
drop trigger if exists manual_damage_submission_quantities_immutable on greenloop_private.manual_damage_submission_quantities;
create trigger manual_damage_submission_quantities_immutable before update or delete or truncate on greenloop_private.manual_damage_submission_quantities for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();
create or replace function greenloop_private.validate_manual_damage_quantity(p_quantity numeric)
returns void language plpgsql immutable set search_path=pg_catalog,public as $quantity$
begin
 if p_quantity is null or p_quantity<1 or p_quantity>99999 or p_quantity<>trunc(p_quantity) then
  raise exception 'Damaged quantity must be a whole number from 1 to 99,999.' using errcode='22023';
 end if;
end; $quantity$;
revoke all on function greenloop_private.validate_manual_damage_quantity(numeric) from public,anon,authenticated;
create or replace view greenloop_private.manual_damage_effective as
 select r.*,
  case when s.row_data ? 'price_amount' then (s.row_data->>'price_amount')::numeric else p.price_amount end as price_amount,
  case when s.row_data ? 'currency_id' then (s.row_data->>'currency_id')::uuid else p.currency_id end as currency_id,
  case when s.row_data ? 'currency' then s.row_data->>'currency' else p.currency end as currency,
  case when s.row_data ? 'part_source_id' then (s.row_data->>'part_source_id')::uuid else p.part_source_id end as part_source_id,
  case when s.row_data ? 'part_source' then s.row_data->>'part_source' else p.part_source end as part_source,
  case when s.row_data ? 'quantity' then (s.row_data->>'quantity')::integer else coalesce(q.quantity,1) end as quantity
 from public.manual_damage_reports b
 left join greenloop_private.manual_damage_state s on s.report_id=b.id
 left join greenloop_private.manual_damage_submission_prices p on p.report_id=b.id
 left join greenloop_private.manual_damage_submission_quantities q on q.report_id=b.id
 cross join lateral jsonb_populate_record(null::public.manual_damage_reports,coalesce(s.row_data,to_jsonb(b))) r
 where not coalesce(s.deleted,false);
revoke all on greenloop_private.manual_damage_effective from public,anon,authenticated;
create or replace function public.create_manual_damage_report_v4(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $create$
declare v_id uuid;v_original integer;v_result jsonb;begin
 if not greenloop_private.manual_damage_access(true) then raise exception 'Damage Entry edit permission is required.' using errcode='42501'; end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023'; end if;
 perform greenloop_private.validate_manual_damage_quantity(p_quantity);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_request_id::text,0));
 lock table public.manual_damage_reports in share row exclusive mode;
 select r.id,coalesce(q.quantity,1) into v_id,v_original from public.manual_damage_reports r left join greenloop_private.manual_damage_submission_quantities q on q.report_id=r.id where r.reported_by_user_id=auth.uid() and r.request_id=p_request_id;
 if v_id is not null and v_original<>p_quantity then raise exception 'This request ID was already used for a different damaged quantity.' using errcode='22023'; end if;
 v_result:=public.create_manual_damage_report_v3(p_request_id,p_employee_id,p_model_id,p_part_id,p_reason_id,p_identifier,p_occurred_at,p_price_amount,p_currency_id,p_part_source_id);
 if v_id is null then insert into greenloop_private.manual_damage_submission_quantities(report_id,quantity) values((v_result->>'id')::uuid,p_quantity::integer); end if;
 return v_result||jsonb_build_object('quantity',p_quantity::integer);
end; $create$;
create or replace function public.correct_manual_damage_report_v3(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $correct$
declare
 v_actor uuid:=auth.uid();v_name text;v_operation uuid:=gen_random_uuid();v_result jsonb;v_payload jsonb;v_previous greenloop_private.manual_damage_operations%rowtype;
 v_currency public.manual_damage_options%rowtype;v_source public.manual_damage_options%rowtype;
 v_before jsonb;v_after jsonb;v_row jsonb;
 v_employee public.manual_damage_options%rowtype;v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;v_reason public.manual_damage_options%rowtype;
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_explanation text:=btrim(coalesce(p_correction_reason,''),E' \t\n\r\f');
begin
 if not greenloop_private.manual_damage_management_access(true) then
  raise exception 'Reports edit and Damage Entry edit permission are required to correct manual damage.' using errcode='42501';
 end if;
 perform greenloop_private.validate_manual_damage_quantity(p_quantity);
 perform greenloop_private.validate_manual_damage_price(p_price_amount,p_currency_id);
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation,'quantity',p_quantity::integer,'price_amount',p_price_amount,'currency_id',p_currency_id,'part_source_id',p_part_source_id);
 -- This lock also conflicts with ordinary submission INSERTs. All management
 -- writers take it before reading state, so a confirmed snapshot stays exact.
 lock table public.manual_damage_reports in share row exclusive mode;
 select * into v_previous from greenloop_private.manual_damage_operations where actor_user_id=v_actor and request_id=p_request_id;
 if found then
  if v_previous.payload is distinct from v_payload then raise exception 'This request ID was already used for different management details.' using errcode='22023'; end if;
  return v_previous.result;
 end if;
 select to_jsonb(r) into v_before from greenloop_private.manual_damage_effective r where id=p_id;
 if not found or greenloop_private.manual_damage_management_row(v_before)->>'version' is distinct from p_expected_version then
  raise exception 'This entry changed or was removed. Refresh it before saving.' using errcode='40001';
 end if;
 perform 1 from public.manual_damage_options where id in (p_employee_id,p_model_id,p_part_id,p_reason_id,p_currency_id,p_part_source_id) order by id for share;
 select * into v_employee from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 select * into v_model from public.manual_damage_options where id=p_model_id and kind='model' and is_active;
 select * into v_part from public.manual_damage_options where id=p_part_id and kind='part' and is_active;
 select * into v_reason from public.manual_damage_options where id=p_reason_id and kind='reason' and is_active;
 if v_employee.id is null or v_model.id is null or v_part.id is null or v_reason.id is null then
  raise exception 'Select an active employee, model, part and reason. Refresh the choices if one was removed.' using errcode='22023';
 end if;
 select * into v_currency from public.manual_damage_options where id=p_currency_id and kind='currency';
 select * into v_source from public.manual_damage_options where id=p_part_source_id and kind='part_source';
 if p_currency_id is not null and (v_currency.id is null or (not v_currency.is_active and p_currency_id is distinct from (v_before->>'currency_id')::uuid)) then
  raise exception 'Select an active currency or retain this entry''s saved currency.' using errcode='22023';
 end if;
 if p_part_source_id is not null and (v_source.id is null or (not v_source.is_active and p_part_source_id is distinct from (v_before->>'part_source_id')::uuid)) then
  raise exception 'Select an active part source or retain this entry''s saved part source.' using errcode='22023';
 end if;
 v_after:=v_before||jsonb_build_object('employee_id',v_employee.id,'damaged_by',v_employee.label,'model',v_model.label,
  'part_name',v_part.label,'damage',v_part.label,'reason',v_reason.label,'identifier',v_identifier,'occurred_at',p_occurred_at,
  'quantity',p_quantity::integer,'price_amount',p_price_amount,'currency_id',p_currency_id,
  'currency',case when p_currency_id=(v_before->>'currency_id')::uuid then v_before->>'currency' else v_currency.label end,
  'part_source_id',p_part_source_id,
  'part_source',case when p_part_source_id=(v_before->>'part_source_id')::uuid then v_before->>'part_source' else v_source.label end);
 if v_after=v_before then raise exception 'Change at least one entry field before saving a correction.' using errcode='22023'; end if;
 insert into greenloop_private.manual_damage_state(report_id,row_data,revision,deleted) values(p_id,v_after,1,false)
 on conflict(report_id) do update set row_data=excluded.row_data,revision=manual_damage_state.revision+1;
 select greenloop_private.manual_damage_management_row(to_jsonb(r)) into v_row from greenloop_private.manual_damage_effective r where id=p_id;
 v_result:=jsonb_build_object('operation_id',v_operation,'action','correct','affected_count',1,'row',v_row);
 select coalesce(nullif(btrim(full_name),''),nullif(btrim(login_username),''),'Staff') into v_name from public.user_profiles where id=v_actor;
 insert into greenloop_private.manual_damage_operations(id,actor_user_id,actor_name,request_id,payload,action,reason,affected_count,result)
 values(v_operation,v_actor,coalesce(v_name,'Staff'),p_request_id,v_payload,'correct',v_explanation,1,v_result);
 insert into greenloop_private.manual_damage_audit(operation_id,report_id,before_data,after_data) values(v_operation,p_id,v_before,v_after);
 return v_result;
end;
$correct$;
create or replace function public.get_manual_damage_employee_rows_v2(
 p_employee_id uuid,p_offset integer default 0,p_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $rows$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,6),100));
 v_normalized text;
 v_count bigint;v_quantity bigint;
 v_rows jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select normalized_label into v_normalized from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 if not found then raise exception 'This employee does not exist.' using errcode='22023'; end if;
 select count(*),coalesce(sum(quantity),0) into v_count,v_quantity from greenloop_private.manual_damage_effective
 where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized);
 select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select id,occurred_at,model,part_name,reason,identifier,reported_by,created_at,quantity,price_amount,currency_id,currency,part_source_id,part_source
  from greenloop_private.manual_damage_effective
  where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized)
  order by occurred_at desc,id desc offset v_offset limit v_limit) r;
 return jsonb_build_object('employee_id',p_employee_id,'total_damage',v_quantity,'record_count',v_count,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_count);
end;
$rows$;
create or replace function public.get_manual_damage_report_v2(p_offset integer default 0,p_limit integer default 8)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $read$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,8),100));
 v_today date:=(now() at time zone 'Asia/Dubai')::date;
 v_month timestamp:=date_trunc('month',now() at time zone 'Asia/Dubai');
 v_today_count bigint; v_month_count bigint; v_total_count bigint; v_record_count bigint;
 v_rows jsonb; v_technicians jsonb;
begin
 if not greenloop_private.manual_damage_access() then
  raise exception 'Damage Entry view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*),coalesce(sum(quantity),0),
  coalesce(sum(quantity) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),0),
  coalesce(sum(quantity) filter(where occurred_at>=v_month at time zone 'Asia/Dubai' and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai'),0)
 into v_record_count,v_total_count,v_today_count,v_month_count from greenloop_private.manual_damage_effective;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.count desc,lower(t.damaged_by),t.damaged_by),'[]'::jsonb)
 into v_technicians from (
  select damaged_by,sum(quantity)::bigint as count from greenloop_private.manual_damage_effective
  where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai'
  group by damaged_by
 ) t;
 select coalesce(jsonb_agg(to_jsonb(r)-'request_id'-'reported_by_user_id'
  order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select * from greenloop_private.manual_damage_effective order by occurred_at desc,id desc
  offset v_offset limit v_limit) r;
 return jsonb_build_object('today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'record_count',v_record_count,'technicians',v_technicians,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_record_count);
end;
$read$;
create or replace function public.get_manual_damage_cards_v2(
 p_offset integer default 0,p_limit integer default 4,p_row_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $cards$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,4),100));
 v_row_limit integer:=greatest(1,least(coalesce(p_row_limit,6),100));
 v_today date:=(now() at time zone 'Asia/Dubai')::date;
 v_month timestamp:=date_trunc('month',now() at time zone 'Asia/Dubai');
 v_employee_count bigint; v_today_count bigint; v_month_count bigint; v_total_count bigint; v_record_count bigint;
 v_employees jsonb; v_activity jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*) into v_employee_count from public.manual_damage_options where kind='employee' and is_active;
 select count(*),coalesce(sum(quantity),0),
  coalesce(sum(quantity) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),0),
  coalesce(sum(quantity) filter(where occurred_at>=v_month at time zone 'Asia/Dubai' and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai'),0)
 into v_record_count,v_total_count,v_today_count,v_month_count from greenloop_private.manual_damage_effective;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.label,
  'total_damage',h.data->'total_damage','record_count',h.data->'record_count','rows',h.data->'rows','has_more',h.data->'has_more') order by e.sort_order,e.id),'[]'::jsonb)
 into v_employees from (select id,label,sort_order from public.manual_damage_options where kind='employee' and is_active
  order by sort_order,id offset v_offset limit v_limit) e
 cross join lateral (select public.get_manual_damage_employee_rows_v2(e.id,0,v_row_limit) as data) h;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc),'[]'::jsonb)
 into v_activity from (
  select id,created_at,occurred_at,damaged_by,model,part_name,reason,quantity,price_amount,currency_id,currency,part_source_id,part_source
  from greenloop_private.manual_damage_effective order by created_at desc,id desc limit 5
 ) r;
 return jsonb_build_object('employee_count',v_employee_count,'today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'record_count',v_record_count,'activity',v_activity,'employees',v_employees,'has_more',v_offset::bigint+v_limit<v_employee_count);
end;
$cards$;
revoke all on function public.create_manual_damage_report_v4(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric) from public,anon;
grant execute on function public.create_manual_damage_report_v4(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric) to authenticated;
revoke all on function public.correct_manual_damage_report_v3(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric) from public,anon;
grant execute on function public.correct_manual_damage_report_v3(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric) to authenticated;
revoke all on function public.get_manual_damage_report_v2(integer,integer) from public,anon;
grant execute on function public.get_manual_damage_report_v2(integer,integer) to authenticated;
revoke all on function public.get_manual_damage_cards_v2(integer,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_cards_v2(integer,integer,integer) to authenticated;
revoke all on function public.get_manual_damage_employee_rows_v2(uuid,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_employee_rows_v2(uuid,integer,integer) to authenticated;
update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema() where object_kind='schema' and object_identity='manual_damage_management_schema';
update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema() where object_kind='schema' and object_identity='manual_damage_price_schema';
create table if not exists greenloop_private.manual_damage_quantity_installation(object_identity text primary key,object_kind text not null check(object_kind in ('function','schema')),definition_hash text not null);
revoke all on greenloop_private.manual_damage_quantity_installation from public,anon,authenticated;
create or replace function greenloop_private.manual_damage_quantity_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $schema$
 select md5(jsonb_build_object(
 'columns',(select jsonb_agg(jsonb_build_array(attname,atttypid::regtype::text,attnotnull,attisdropped) order by attnum) from pg_attribute where attrelid='greenloop_private.manual_damage_submission_quantities'::regclass and attnum>0),
 'constraints',(select jsonb_agg(jsonb_build_array(conname,pg_get_constraintdef(oid),convalidated) order by conname) from pg_constraint where conrelid='greenloop_private.manual_damage_submission_quantities'::regclass),
 'triggers',(select jsonb_agg(jsonb_build_array(tgname,pg_get_triggerdef(oid),tgenabled) order by tgname) from pg_trigger where tgrelid='greenloop_private.manual_damage_submission_quantities'::regclass and not tgisinternal),
 'indexes',(select jsonb_agg(pg_get_indexdef(indexrelid) order by indexrelid) from pg_index where indrelid='greenloop_private.manual_damage_submission_quantities'::regclass),
 'policies',(select jsonb_agg(to_jsonb(p)-'oid' order by polname) from pg_policy p where polrelid='greenloop_private.manual_damage_submission_quantities'::regclass),
 'view',pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true)
 )::text);
$schema$;
revoke all on function greenloop_private.manual_damage_quantity_schema() from public,anon,authenticated;
insert into greenloop_private.manual_damage_quantity_installation select p.oid::regprocedure::text,'function',md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in (
 'public.create_manual_damage_report_v4(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric)'::regprocedure,
 'public.correct_manual_damage_report_v3(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric)'::regprocedure,
 'public.get_manual_damage_report_v2(integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v2(integer,integer,integer)'::regprocedure,
 'public.get_manual_damage_employee_rows_v2(uuid,integer,integer)'::regprocedure,
 'greenloop_private.validate_manual_damage_quantity(numeric)'::regprocedure,
 'greenloop_private.prevent_manual_damage_quantity_changes()'::regprocedure,
 'greenloop_private.manual_damage_quantity_schema()'::regprocedure)
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.manual_damage_quantity_installation values('manual_damage_quantity_schema','schema',greenloop_private.manual_damage_quantity_schema()) on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_manual_damage_quantity_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_price_version()='20261005-manual-damage-price-1'
 and (select count(*)=8 and bool_and(to_regprocedure(i.object_identity) is not null and md5(pg_get_functiondef(to_regprocedure(i.object_identity)))=i.definition_hash and not has_function_privilege('anon',to_regprocedure(i.object_identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(i.object_identity),'EXECUTE')=(i.object_identity not like 'greenloop_private.%')) from greenloop_private.manual_damage_quantity_installation i where object_kind='function')
 and (select count(*)=1 and bool_and(definition_hash=greenloop_private.manual_damage_quantity_schema()) from greenloop_private.manual_damage_quantity_installation where object_kind='schema' and object_identity='manual_damage_quantity_schema')
 and (select relrowsecurity from pg_class where oid='greenloop_private.manual_damage_submission_quantities'::regclass)
 and not exists(select 1 from unnest(array['greenloop_private.manual_damage_submission_quantities','greenloop_private.manual_damage_quantity_installation']) t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 then '20261006-damage-quantity-1' end;
$version$;
revoke all on function public.get_manual_damage_quantity_version() from public;
grant execute on function public.get_manual_damage_quantity_version() to anon,authenticated;
do $verify$ begin if public.get_manual_damage_quantity_version() is distinct from '20261006-damage-quantity-1' then raise exception 'Damage Quantity verification failed. Nothing installed.' using errcode='55000';end if;end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_manual_damage_quantity_version() as installed_manual_damage_quantity_version;
