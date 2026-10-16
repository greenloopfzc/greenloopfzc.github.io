-- Independent Original and Copy valuations. No historical prices are rewritten.
begin;
do $$ begin
 if public.get_damage_tv_summary_version() is distinct from '20261015-damage-tv-summary-1' then
 raise exception 'Install the verified Damage TV Summary update first.' using errcode='55000'; end if;
 if to_regprocedure('public.get_damage_dual_price_version()') is not null then
 if public.get_damage_dual_price_version() is distinct from '20261016-damage-dual-price-1' then raise exception 'Existing dual-price installation differs.' using errcode='55000'; end if;
 elsif to_regclass('greenloop_private.manual_damage_submission_copy_prices') is not null then raise exception 'Unexpected copy-price storage.' using errcode='55000'; end if;
end; $$;
create table if not exists greenloop_private.manual_damage_submission_copy_prices(
 report_id uuid primary key, copy_price_amount numeric check(copy_price_amount is null or (copy_price_amount>=0 and copy_price_amount<=99999999.99 and scale(copy_price_amount)<=2)));
alter table greenloop_private.manual_damage_submission_copy_prices enable row level security;
revoke all on greenloop_private.manual_damage_submission_copy_prices from public,anon,authenticated;
drop trigger if exists manual_damage_copy_prices_immutable on greenloop_private.manual_damage_submission_copy_prices;
create trigger manual_damage_copy_prices_immutable before update or delete or truncate on greenloop_private.manual_damage_submission_copy_prices for each statement execute function greenloop_private.prevent_manual_damage_price_changes();
create or replace view greenloop_private.manual_damage_effective as
 select r.*,
  case when s.row_data ? 'price_amount' then (s.row_data->>'price_amount')::numeric else p.price_amount end as price_amount,
  case when s.row_data ? 'currency_id' then (s.row_data->>'currency_id')::uuid else p.currency_id end as currency_id,
  case when s.row_data ? 'currency' then s.row_data->>'currency' else p.currency end as currency,
  case when s.row_data ? 'part_source_id' then (s.row_data->>'part_source_id')::uuid else p.part_source_id end as part_source_id,
  case when s.row_data ? 'part_source' then s.row_data->>'part_source' else p.part_source end as part_source,
  case when s.row_data ? 'quantity' then (s.row_data->>'quantity')::integer else coalesce(q.quantity,1) end as quantity,
  case when s.row_data ? 'department' then s.row_data->>'department' else d.department end as department,
  case when s.row_data ? 'copy_price_amount' then (s.row_data->>'copy_price_amount')::numeric else cp.copy_price_amount end as copy_price_amount
 from public.manual_damage_reports b
 left join greenloop_private.manual_damage_state s on s.report_id=b.id
 left join greenloop_private.manual_damage_submission_prices p on p.report_id=b.id
 left join greenloop_private.manual_damage_submission_quantities q on q.report_id=b.id
 left join greenloop_private.manual_damage_submission_departments d on d.report_id=b.id
 left join greenloop_private.manual_damage_submission_copy_prices cp on cp.report_id=b.id
 cross join lateral jsonb_populate_record(null::public.manual_damage_reports,coalesce(s.row_data,to_jsonb(b))) r
 where not coalesce(s.deleted,false);

revoke all on greenloop_private.manual_damage_effective from public,anon,authenticated;

create or replace function public.create_manual_damage_report_v6(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric,p_department text,p_copy_price_amount numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;v_copy numeric;v_result jsonb; begin
 if not greenloop_private.manual_damage_access(true) then raise exception 'Damage Entry edit permission is required.' using errcode='42501'; end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023'; end if;
 perform greenloop_private.validate_manual_damage_price(p_copy_price_amount,p_currency_id);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_request_id::text,0));
 lock table public.manual_damage_reports in share row exclusive mode;
 select r.id,cp.copy_price_amount into v_id,v_copy from public.manual_damage_reports r left join greenloop_private.manual_damage_submission_copy_prices cp on cp.report_id=r.id where r.reported_by_user_id=auth.uid() and r.request_id=p_request_id;
 if v_id is not null and v_copy is distinct from p_copy_price_amount then raise exception 'This request ID was already used for another copy price. Use Data Correction for saved entries.' using errcode='22023'; end if;
 v_result:=public.create_manual_damage_report_v5(p_request_id,p_employee_id,p_model_id,p_part_id,p_reason_id,p_identifier,p_occurred_at,p_price_amount,p_currency_id,p_part_source_id,p_quantity,p_department);
 if v_id is null then insert into greenloop_private.manual_damage_submission_copy_prices values((v_result->>'id')::uuid,p_copy_price_amount); end if;
 return v_result||jsonb_build_object('copy_price_amount',p_copy_price_amount);
end; $$;
create or replace function public.correct_manual_damage_report_v5(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric,p_department text,p_copy_price_amount numeric,p_apply_department_to_unassigned boolean default false
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $correct$
declare
 v_actor uuid:=auth.uid();v_name text;v_operation uuid:=gen_random_uuid();v_result jsonb;v_payload jsonb;v_previous greenloop_private.manual_damage_operations%rowtype;
 v_currency public.manual_damage_options%rowtype;v_source public.manual_damage_options%rowtype;
 v_before jsonb;v_after jsonb;v_row jsonb;
 v_employee public.manual_damage_options%rowtype;v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;v_reason public.manual_damage_options%rowtype;
 v_bulk jsonb:='[]'::jsonb;v_item jsonb;v_affected integer:=1;
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_explanation text:=btrim(coalesce(p_correction_reason,''),E' \t\n\r\f');
begin
 if not greenloop_private.manual_damage_management_access(true) then
  raise exception 'Reports edit and Damage Entry edit permission are required to correct manual damage.' using errcode='42501';
 end if;
 if p_department is null or p_department not in ('glass','other') then raise exception 'Select Glass Department or Other Department.' using errcode='22023';end if;
 perform greenloop_private.validate_manual_damage_quantity(p_quantity);
 perform greenloop_private.validate_manual_damage_price(p_price_amount,p_currency_id);
 perform greenloop_private.validate_manual_damage_price(p_copy_price_amount,p_currency_id);
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation,'department',p_department,'apply_department_to_unassigned',coalesce(p_apply_department_to_unassigned,false),'quantity',p_quantity::integer,'price_amount',p_price_amount,'copy_price_amount',p_copy_price_amount,'currency_id',p_currency_id,'part_source_id',p_part_source_id);
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
 v_after:=v_before||jsonb_build_object('department',p_department,'employee_id',v_employee.id,'damaged_by',v_employee.label,'model',v_model.label,
  'part_name',v_part.label,'damage',v_part.label,'reason',v_reason.label,'identifier',v_identifier,'occurred_at',p_occurred_at,
  'quantity',p_quantity::integer,'price_amount',p_price_amount,'copy_price_amount',p_copy_price_amount,'currency_id',p_currency_id,
  'currency',case when p_currency_id=(v_before->>'currency_id')::uuid then v_before->>'currency' else v_currency.label end,
  'part_source_id',p_part_source_id,
  'part_source',case when p_part_source_id=(v_before->>'part_source_id')::uuid then v_before->>'part_source' else v_source.label end);
 if v_after=v_before and not coalesce(p_apply_department_to_unassigned,false) then raise exception 'Change at least one entry field before saving a correction.' using errcode='22023'; end if;
 if coalesce(p_apply_department_to_unassigned,false) then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_bulk from greenloop_private.manual_damage_effective r
  where r.id<>p_id and r.department is null and (r.employee_id=p_employee_id or
   (r.employee_id is null and greenloop_private.manual_damage_normalized(r.damaged_by)=v_employee.normalized_label));
 end if;
 insert into greenloop_private.manual_damage_state(report_id,row_data,revision,deleted) values(p_id,v_after,1,false)
 on conflict(report_id) do update set row_data=excluded.row_data,revision=manual_damage_state.revision+1;
 select greenloop_private.manual_damage_management_row(to_jsonb(r)) into v_row from greenloop_private.manual_damage_effective r where id=p_id;
 for v_item in select value from jsonb_array_elements(v_bulk) loop
  insert into greenloop_private.manual_damage_state(report_id,row_data,revision,deleted)
   values((v_item->>'id')::uuid,v_item||jsonb_build_object('department',p_department),1,false)
   on conflict(report_id) do update set row_data=excluded.row_data,revision=manual_damage_state.revision+1;
 end loop;
 v_affected:=1+jsonb_array_length(v_bulk);
 v_result:=jsonb_build_object('operation_id',v_operation,'action','correct','affected_count',v_affected,'row',v_row);
 select coalesce(nullif(btrim(full_name),''),nullif(btrim(login_username),''),'Staff') into v_name from public.user_profiles where id=v_actor;
 insert into greenloop_private.manual_damage_operations(id,actor_user_id,actor_name,request_id,payload,action,reason,affected_count,result)
 values(v_operation,v_actor,coalesce(v_name,'Staff'),p_request_id,v_payload,'correct',v_explanation,v_affected,v_result);
 insert into greenloop_private.manual_damage_audit(operation_id,report_id,before_data,after_data) values(v_operation,p_id,v_before,v_after);
 for v_item in select value from jsonb_array_elements(v_bulk) loop
  insert into greenloop_private.manual_damage_audit(operation_id,report_id,before_data,after_data) values(v_operation,(v_item->>'id')::uuid,v_item,v_item||jsonb_build_object('department',p_department));
 end loop;
 return v_result;
end;
$correct$;


-- Also protect a saved copy valuation when a stale client corrects another field.
create or replace function greenloop_private.validate_damage_copy_state()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_copy numeric;v_currency uuid;begin
 if new.deleted then return new;end if;
 if new.row_data ? 'copy_price_amount' then v_copy:=(new.row_data->>'copy_price_amount')::numeric;
 else select copy_price_amount into v_copy from greenloop_private.manual_damage_submission_copy_prices where report_id=new.report_id;end if;
 if new.row_data ? 'currency_id' then v_currency:=(new.row_data->>'currency_id')::uuid;
 else select currency_id into v_currency from greenloop_private.manual_damage_submission_prices where report_id=new.report_id;end if;
 perform greenloop_private.validate_manual_damage_price(v_copy,v_currency);
 return new;
end; $$;
drop trigger if exists damage_copy_state_valid on greenloop_private.manual_damage_state;
create trigger damage_copy_state_valid before insert or update on greenloop_private.manual_damage_state for each row execute function greenloop_private.validate_damage_copy_state();

create or replace function greenloop_private.damage_copy_rows(p_rows jsonb)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(j.value||jsonb_build_object('copy_price_amount',r.copy_price_amount) order by j.ordinality),'[]'::jsonb)
 from jsonb_array_elements(p_rows) with ordinality j(value,ordinality) join greenloop_private.manual_damage_effective r on r.id=(j.value->>'id')::uuid;
$$;
create or replace function greenloop_private.damage_copy_values(p_employee_id uuid default null)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with rows as (select r.* from greenloop_private.manual_damage_effective r
 where p_employee_id is null or r.employee_id=p_employee_id or (r.employee_id is null and greenloop_private.manual_damage_normalized(r.damaged_by)=(select normalized_label from public.manual_damage_options where id=p_employee_id and kind='employee'))),
 totals as (select currency,round(sum(copy_price_amount*quantity),2)::text amount,sum(quantity)::bigint quantity from rows where copy_price_amount is not null and currency is not null group by currency)
 select jsonb_build_object('copy_value_totals',coalesce((select jsonb_agg(to_jsonb(t) order by currency) from totals t),'[]'::jsonb),'copy_unpriced_quantity',(select coalesce(sum(quantity),0) from rows where copy_price_amount is null or currency is null));
$$;
create or replace function public.get_manual_damage_cards_v6(p_offset integer default 0,p_limit integer default 100,p_row_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r jsonb;e jsonb;begin
 r:=public.get_manual_damage_cards_v5(p_offset,p_limit,p_row_limit);
 select coalesce(jsonb_agg(j.value||greenloop_private.damage_copy_values((j.value->>'id')::uuid)||jsonb_build_object('rows',greenloop_private.damage_copy_rows(j.value->'rows')) order by j.ordinality),'[]'::jsonb) into e from jsonb_array_elements(r->'employees') with ordinality j(value,ordinality);
 return r||greenloop_private.damage_copy_values()||jsonb_build_object('employees',e,'activity',greenloop_private.damage_copy_rows(r->'activity'));
end; $$;
create or replace function public.get_manual_damage_employee_rows_v4(p_employee_id uuid,p_offset integer default 0,p_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r jsonb;begin
 r:=public.get_manual_damage_employee_rows_v3(p_employee_id,p_offset,p_limit);
 return r||greenloop_private.damage_copy_values(p_employee_id)||jsonb_build_object('rows',greenloop_private.damage_copy_rows(r->'rows'));
end; $$;
create or replace function public.get_manual_damage_export_v3(p_date_from date,p_date_to date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r jsonb;v_rows jsonb;begin
 r:=public.get_manual_damage_export_v2(p_date_from,p_date_to);
 select coalesce(jsonb_agg(j.value||jsonb_build_object('copy_price_amount',round(e.copy_price_amount,2)::text) order by j.ordinality),'[]'::jsonb) into v_rows from jsonb_array_elements(r->'rows') with ordinality j(value,ordinality) join greenloop_private.manual_damage_effective e on e.id=(j.value->>'id')::uuid;
 return r||jsonb_build_object('version','20261016-damage-dual-price-1','rows',v_rows);
end; $$;
-- One calculation, evaluated independently for each valuation. Neither amount
-- is added to the other. Null prices remain pending on that basis only.
create or replace function greenloop_private.damage_basis_rows(p_copy boolean)
returns setof greenloop_private.manual_damage_effective language sql stable security definer set search_path=pg_catalog,public as $$
 select (jsonb_populate_record(null::greenloop_private.manual_damage_effective,to_jsonb(r)||jsonb_build_object('price_amount',case when p_copy then r.copy_price_amount else r.price_amount end))).* from greenloop_private.manual_damage_effective r;
$$;
create or replace function greenloop_private.damage_basis_summary(p_scope text,p_offset integer,p_limit integer,p_copy boolean)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare
 v_today date := (now() at time zone 'Asia/Dubai')::date;
 v_from date; v_to date; v_rows jsonb; v_employees jsonb; v_values jsonb;
 v_records bigint; v_quantity bigint; v_unpriced bigint; v_count bigint; v_pending bigint; v_payable numeric;
begin
 if not greenloop_private.damage_report_access() then raise exception 'Damage Report view permission is required.' using errcode='42501'; end if;
 if p_scope is null or p_scope not in ('today','month','all','value','payable')
 or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 then
  raise exception 'Choose a valid damage summary page.' using errcode='22023';
 end if;
 v_from:=case when p_scope='today' then v_today when p_scope in ('month','payable') then date_trunc('month',v_today)::date end;
 v_to:=case when v_from is not null then v_today end;
 select count(*),coalesce(sum(quantity),0),coalesce(sum(quantity) filter(where price_amount is null or currency is null),0)
 into v_records,v_quantity,v_unpriced from greenloop_private.damage_basis_rows(p_copy)
 where v_from is null or (occurred_at>=v_from::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_to+1)::timestamp at time zone 'Asia/Dubai');
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount) order by currency),'[]'::jsonb) into v_values
 from (select currency,round(sum(price_amount*quantity),2)::text amount from greenloop_private.damage_basis_rows(p_copy)
 where price_amount is not null and currency is not null
 and (v_from is null or (occurred_at>=v_from::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_to+1)::timestamp at time zone 'Asia/Dubai')) group by currency) totals;

 if p_scope='payable' then
  -- Match legacy names to one active employee exactly as the existing PDF does.
  -- Catalog IDs are never merged, including archived employees with damage.
  with roster as (
   select id::text employee_key,label employee_name,normalized_label from public.manual_damage_options where kind='employee' and is_active
  ), base as (
   select r.*,coalesce(r.employee_id::text,
     (select min(e.employee_key) from roster e where e.normalized_label=greenloop_private.manual_damage_normalized(r.damaged_by) having count(*)=1),
     'legacy:'||greenloop_private.manual_damage_normalized(r.damaged_by)) employee_key
   from greenloop_private.damage_basis_rows(p_copy) r
   where r.occurred_at>=v_from::timestamp at time zone 'Asia/Dubai' and r.occurred_at<(v_to+1)::timestamp at time zone 'Asia/Dubai'
  ), names as (
   select employee_key,employee_name from roster union all
   select employee_key,min(damaged_by) from base b where not exists(select 1 from roster e where e.employee_key=b.employee_key) group by employee_key
  ), grouped as (
   select n.employee_key,n.employee_name,count(b.id) record_count,coalesce(sum(b.quantity),0) quantity,
    min(b.department) department,
    case when bool_or(b.id is not null and b.department is null) then 'Department pending'
      when count(distinct b.department)>1 then 'Department conflict'
      when bool_or(b.price_amount is null and b.id is not null) then 'Price pending'
      when bool_or(b.id is not null and (b.currency is null or b.currency<>'AED')) then 'AED settlement pending' else null end pending,
    coalesce(sum(b.price_amount*b.quantity) filter(where b.currency='AED'),0) aed_value,
    coalesce(sum(b.quantity) filter(where lower(btrim(b.part_name))='lcd'),0) lcd_quantity,
    coalesce(sum(b.price_amount*b.quantity) filter(where lower(btrim(b.part_name))='lcd'),0) lcd_value,
    coalesce((select jsonb_agg(jsonb_build_object('currency',currency,'amount',amount) order by currency) from
      (select currency,round(sum(price_amount*quantity),2)::text amount from base x where x.employee_key=n.employee_key and price_amount is not null and currency is not null group by currency) t),'[]'::jsonb) value_totals
   from names n left join base b on b.employee_key=n.employee_key group by n.employee_key,n.employee_name
  ), allowance as (
   select g.*,least(lcd_quantity,case when department='glass' then 4 else 1 end) waived_quantity from grouped g
  ), calculated as (
   select a.*,case when lcd_quantity>0 then lcd_value/lcd_quantity else 0 end lcd_average,
    case when lcd_quantity>0 then lcd_value*waived_quantity/lcd_quantity else 0 end waived_value,
    -- Keep the weighted average unrounded until the final employee payable.
    case when pending is null then round(greatest(0,((aed_value-100)*greatest(lcd_quantity,1)-lcd_value*waived_quantity)/(greatest(lcd_quantity,1)*2)),2) end payable
   from allowance a
  ) select coalesce(jsonb_agg(jsonb_build_object('employee_key',employee_key,'employee_name',employee_name,'department',department,
      'quantity',quantity,'record_count',record_count,'value_totals',value_totals,'lcd_quantity',lcd_quantity,
      'lcd_average',round(lcd_average,2)::text,'waived_quantity',waived_quantity,'waived_value',round(waived_value,2)::text,
      'deduction','100.00','payable',payable::text,'pending',pending) order by (record_count>0) desc,employee_name,employee_key),'[]'::jsonb),
      count(*),count(*) filter(where pending is not null),coalesce(sum(payable),0)
    into v_employees,v_count,v_pending,v_payable from calculated;
  select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_rows
    from jsonb_array_elements(v_employees) with ordinality where ordinality>p_offset and ordinality<=p_offset::bigint+p_limit;
 else
  v_count:=v_records;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows from (
   select id,damaged_by,department,occurred_at,model,identifier,part_name,quantity,round(price_amount,2)::text price_amount,currency,
    round(price_amount*quantity,2)::text entry_total,part_source,reason,reported_by,created_at
   from greenloop_private.damage_basis_rows(p_copy)
   where v_from is null or (occurred_at>=v_from::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_to+1)::timestamp at time zone 'Asia/Dubai')
   order by occurred_at desc,id desc offset p_offset limit p_limit
  ) r;
 end if;
 return jsonb_build_object('version','20261015-damage-tv-summary-1','scope',p_scope,'date_from',v_from,'date_to',v_to,'generated_at',now(),
  'record_count',v_records,'quantity',v_quantity,'unpriced_quantity',v_unpriced,'value_totals',v_values,
  'result_count',v_count,'offset',p_offset,'has_more',p_offset::bigint+p_limit<v_count,'rows',v_rows,
  'pending_count',v_pending,'payable',case when v_pending=0 then round(v_payable,2)::text end,
  'confirmed_payable',case when p_scope='payable' then round(v_payable,2)::text end);
end; $$;

create or replace function public.get_damage_tv_summary_v2(p_scope text,p_offset integer default 0,p_limit integer default 12)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare o jsonb;c jsonb;v_rows jsonb;begin
 o:=greenloop_private.damage_basis_summary(p_scope,p_offset,p_limit,false);
 c:=greenloop_private.damage_basis_summary(p_scope,p_offset,p_limit,true);
 select coalesce(jsonb_agg(a.value||case when p_scope='payable' then jsonb_build_object(
 'copy_value_totals',b.value->'value_totals','copy_lcd_average',b.value->'lcd_average','copy_waived_value',b.value->'waived_value','copy_payable',b.value->'payable','copy_pending',b.value->'pending')
 else jsonb_build_object('copy_price_amount',b.value->'price_amount','copy_entry_total',b.value->'entry_total') end order by a.ordinality),'[]'::jsonb)
 into v_rows from jsonb_array_elements(o->'rows') with ordinality a(value,ordinality) join jsonb_array_elements(c->'rows') with ordinality b(value,ordinality) on a.ordinality=b.ordinality;
 return o||jsonb_build_object('version','20261016-damage-dual-price-1','rows',v_rows,'copy_value_totals',c->'value_totals','copy_unpriced_quantity',c->'unpriced_quantity','copy_pending_count',c->'pending_count','copy_payable',c->'payable','copy_confirmed_payable',c->'confirmed_payable');
end; $$;
create or replace function public.get_sorted_filter_records_v2(p_source text,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_by text default null,p_sort_direction text default 'asc')
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source_rows jsonb;matched jsonb;keys text[];facet_keys text[];date_key text;v_page_key text;facets jsonb;result jsonb;metadata jsonb;sort_keys text[];number_keys text[];date_keys text[];sort_type text;
begin
 if p_source is null or jsonb_typeof(p_filters) is distinct from 'object' or octet_length(p_filters::text)>5000 or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>200 then raise exception 'Invalid table filters or page.' using errcode='22023';end if;
 if nullif(p_filters->>'_from','')::date>nullif(p_filters->>'_to','')::date then raise exception 'From date must be on or before To date.' using errcode='22023';end if;
 v_page_key:=case p_source when 'inventory_receipts' then 'inventory' when 'part_returns' then 'parts' when 'frame_results' then 'frame_department' when 'journey' then 'ready_stock_journey' when 'accounts_supplier' then 'accounts' when 'accounts_customer' then 'accounts' when 'accounts' then 'accounts' when 'stock_exported' then 'stock_exported' when 'damage_entry' then 'tv_manual_entry' when 'damage_management' then 'reports' end;
 if v_page_key is null then raise exception 'Unknown filter source.' using errcode='22023';end if;
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not coalesce(
 (select access_level in ('view','edit') from public.user_page_permissions where user_id=auth.uid() and user_page_permissions.page_key=v_page_key),
 public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then raise exception 'Page view permission is required.' using errcode='42501';end if;
 case p_source
 when 'inventory_receipts' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_part_inventory_receipts(150) r;
  keys:=array['receipt_number','invoice_number','source_origin','sku','part_name','notes'];facet_keys:=array['part_name','source_origin'];date_key:='received_at';
 when 'part_returns' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_part_return_report(null,500) r;
  keys:=array['imei','device_number','job_number','supplier_code','part_name','reason','invoice_number','return_condition','returned_by_name'];facet_keys:=array['supplier_code','part_name','return_condition','returned_by_name'];date_key:='returned_at';
 when 'frame_results' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into source_rows from greenloop_private.filter_get_frame_department_report(250) r;
  keys:=array['imei','supplier_code','model','result','notes','reviewed_by_name'];facet_keys:=array['supplier_code','model','result','reviewed_by_name'];date_key:='reviewed_at';
 when 'journey' then
  source_rows:=greenloop_private.filter_get_stock_journey_v1(null,null,'',0,100)->'rows';
  keys:=array['imei','device_number','device_details','current_stage','current_status','supplier_code','supplier_company','invoice_number','technician_name','box_number','customer_name','company_final_grade'];facet_keys:=array['current_stage','supplier_code','company_final_grade'];date_key:='date_entered';
 when 'accounts_supplier','accounts_customer' then
  source_rows:=greenloop_private.filter_get_accounts_stock_v1(case when p_source='accounts_supplier' then 'supplier' else 'customer' end,null,null,null,0,100)->'rows';
  keys:=array['supplier_code','supplier_name','customer_code','customer_name','invoice_number','batch_number','box_number','model','storage_gb','color','final_grade'];facet_keys:=array['supplier_code','customer_code','model','storage_gb','color','final_grade'];date_key:=case when p_source='accounts_supplier' then 'received_at' else 'exported_at' end;
 when 'accounts','stock_exported' then
  source_rows:=greenloop_private.filter_get_box_queue_v1(p_source,null,null,0,100)->'rows';
  select coalesce(jsonb_agg(value||jsonb_build_object('filter_date',coalesce(value->>'verified_at',value->>'saved_at'))),'[]') into source_rows from jsonb_array_elements(source_rows);
  keys:=array['box_number','customer_code','customer_name','state','saved_by_name','verified_by_name'];facet_keys:=array['state','customer_code','saved_by_name','verified_by_name'];date_key:='filter_date';
 when 'damage_entry','damage_management' then
  if p_source='damage_entry' then perform public.get_manual_damage_report_v2(0,1);
  else metadata:=greenloop_private.filter_get_manual_damage_management_v1('',0,100);end if;
  select coalesce(jsonb_agg(to_jsonb(r)-'request_id'-'reported_by_user_id' order by occurred_at desc,id desc),'[]') into source_rows from greenloop_private.manual_damage_effective r;
  if p_source='damage_management' then source_rows:=metadata->'rows';end if;
  keys:=array['id','damage','damaged_by','department','model','part_name','reason','identifier','part_source','currency','reported_by'];facet_keys:=array['damaged_by','department','model','part_name','part_source','currency'];date_key:='occurred_at';
 else raise exception 'Unknown source';
 end case;

 -- Only typed, visible fields may control ordering. Filtering and privacy run first.
 number_keys:=array['quantity','quantity_received','total_cost','unit_cost','storage_gb','received','in_company','ready','in_process','exported','returned','awaiting_imei','price_amount','total_value','copy_price_amount','copy_total_value','parts_cost'];
 date_keys:=array['received_at','returned_at','reviewed_at','date_entered','date_received','date_completed','export_date','exported_at','saved_at','verified_at','filter_date','occurred_at','created_at'];
 sort_keys:=keys||array[date_key]||case p_source
 when 'inventory_receipts' then array['quantity_received','total_cost','unit_cost']
 when 'part_returns' then array['quantity']
 when 'journey' then array['date_received','date_completed','export_date','parts_cost','quantity_received','stock_channel','battery_health','supplier_grade','company_initial_grade','parts_issued','service_done']
 when 'accounts_supplier' then array['received','in_company','ready','in_process','exported','returned','awaiting_imei']
 when 'accounts_customer' then array['received_at','quantity']
 when 'accounts' then array['saved_at','verified_at','quantity']
 when 'stock_exported' then array['saved_at','verified_at','quantity']
 when 'damage_entry' then array['quantity','price_amount','total_value','copy_price_amount','copy_total_value','created_at']
 when 'damage_management' then array['quantity','price_amount','total_value','copy_price_amount','copy_total_value','created_at']
 else array[]::text[] end;
 if p_sort_direction is null or p_sort_direction not in ('asc','desc') or (p_sort_by is not null and not p_sort_by=any(sort_keys)) then raise exception 'Invalid sort field or direction.' using errcode='22023';end if;
 sort_type:=case when p_sort_by=any(number_keys) then 'number' when p_sort_by=any(date_keys) then 'date' else 'text' end;
 if p_source in ('damage_entry','damage_management') then
  select coalesce(jsonb_agg(value||jsonb_build_object('copy_total_value',nullif(value->>'copy_price_amount','')::numeric*coalesce(nullif(value->>'quantity','')::numeric,1),'total_value',nullif(value->>'price_amount','')::numeric*coalesce(nullif(value->>'quantity','')::numeric,1)) order by ord),'[]') into source_rows from jsonb_array_elements(source_rows) with ordinality r(value,ord);
 end if;
 if exists(select 1 from jsonb_object_keys(p_filters) k where not k=any(keys||array['_from','_to','_search'])) then raise exception 'Unknown filter field.' using errcode='22023';end if;
 select coalesce(jsonb_object_agg(k,values),'{}') into facets from (select k,(select coalesce(jsonb_agg(v order by v),'[]') from (select distinct value->>k v from jsonb_array_elements(source_rows) where nullif(value->>k,'') is not null) vals) values from unnest(facet_keys) k) f;
 select coalesce(jsonb_agg(value order by ord),'[]') into matched from jsonb_array_elements(source_rows) with ordinality r(value,ord) where greenloop_private.filter_record_matches(value,p_filters,keys,date_key);

 -- Sort the whole matching array before taking a page; missing values stay last.
 -- Original ordinal is the final tiebreaker so equal values remain stable.
 if p_sort_by is not null then
  select coalesce(jsonb_agg(value order by
   case when sort_type='number' and p_sort_direction='asc' then nullif(value->>p_sort_by,'')::numeric end asc nulls last,
   case when sort_type='number' and p_sort_direction='desc' then nullif(value->>p_sort_by,'')::numeric end desc nulls last,
   case when sort_type='date' and p_sort_direction='asc' then nullif(value->>p_sort_by,'')::timestamptz end asc nulls last,
   case when sort_type='date' and p_sort_direction='desc' then nullif(value->>p_sort_by,'')::timestamptz end desc nulls last,
   case when sort_type='text' and p_sort_direction='asc' then lower(nullif(btrim(value->>p_sort_by),'')) end asc nulls last,
   case when sort_type='text' and p_sort_direction='desc' then lower(nullif(btrim(value->>p_sort_by),'')) end desc nulls last,
   ord),'[]') into matched from jsonb_array_elements(matched) with ordinality r(value,ord);
 end if;
 select jsonb_build_object('total',jsonb_array_length(matched),'record_count',jsonb_array_length(matched),'total_count',jsonb_array_length(matched),'has_more',p_offset::bigint+p_limit<jsonb_array_length(matched),'facets',facets,
 'rows',coalesce((select jsonb_agg(value order by ord) from (select value,ord from jsonb_array_elements(matched) with ordinality r(value,ord) order by ord offset p_offset limit p_limit) paged),'[]'),
 'totals',jsonb_build_object(
 'received',coalesce((select sum((r->>'received')::numeric) from jsonb_array_elements(matched) r),0),
 'in_company',coalesce((select sum((r->>'in_company')::numeric) from jsonb_array_elements(matched) r),0),
 'ready',coalesce((select sum((r->>'ready')::numeric) from jsonb_array_elements(matched) r),0),
 'in_process',coalesce((select sum((r->>'in_process')::numeric) from jsonb_array_elements(matched) r),0),
 'exported',coalesce((select sum(coalesce(r->>'exported',r->>'quantity')::numeric) from jsonb_array_elements(matched) r),0),
 'returned',coalesce((select sum((r->>'returned')::numeric) from jsonb_array_elements(matched) r),0),
 'quantity',coalesce((select sum(coalesce(r->>'quantity',r->>'quantity_received','0')::numeric) from jsonb_array_elements(matched) r),0),
 'total_cost',coalesce((select sum((r->>'total_cost')::numeric) from jsonb_array_elements(matched) r),0),
 'total_value',coalesce((select sum((r->>'total_value')::numeric) from jsonb_array_elements(matched) r),0),
 'pass',(select count(*) from jsonb_array_elements(matched) r where r->>'result'='pass'),
 'fail',(select count(*) from jsonb_array_elements(matched) r where r->>'result'='fail')
 )) into result;
 return coalesce(metadata,'{}'::jsonb)||result;
end; $$;

revoke all on function public.create_manual_damage_report_v6(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text,numeric) from public,anon,authenticated;
grant execute on function public.create_manual_damage_report_v6(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text,numeric) to authenticated;

revoke all on function public.correct_manual_damage_report_v5(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,numeric,boolean) from public,anon,authenticated;
grant execute on function public.correct_manual_damage_report_v5(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,numeric,boolean) to authenticated;

revoke all on function greenloop_private.validate_damage_copy_state() from public,anon,authenticated;

revoke all on function greenloop_private.damage_copy_rows(jsonb) from public,anon,authenticated;

revoke all on function greenloop_private.damage_copy_values(uuid) from public,anon,authenticated;

revoke all on function public.get_manual_damage_cards_v6(integer,integer,integer) from public,anon,authenticated;
grant execute on function public.get_manual_damage_cards_v6(integer,integer,integer) to authenticated;

revoke all on function public.get_manual_damage_employee_rows_v4(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.get_manual_damage_employee_rows_v4(uuid,integer,integer) to authenticated;

revoke all on function public.get_manual_damage_export_v3(date,date) from public,anon,authenticated;
grant execute on function public.get_manual_damage_export_v3(date,date) to authenticated;

revoke all on function greenloop_private.damage_basis_rows(boolean) from public,anon,authenticated;

revoke all on function greenloop_private.damage_basis_summary(text,integer,integer,boolean) from public,anon,authenticated;

revoke all on function public.get_damage_tv_summary_v2(text,integer,integer) from public,anon,authenticated;
grant execute on function public.get_damage_tv_summary_v2(text,integer,integer) to authenticated;

revoke all on function public.get_sorted_filter_records_v2(text,jsonb,integer,integer,text,text) from public,anon,authenticated;
grant execute on function public.get_sorted_filter_records_v2(text,jsonb,integer,integer,text,text) to authenticated;

-- Reviewed additive view/validation changes; retain earlier version checks.
update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema() where object_kind='schema' and object_identity='manual_damage_management_schema';
update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema() where object_kind='schema' and object_identity='manual_damage_price_schema';
update greenloop_private.manual_damage_quantity_installation set definition_hash=greenloop_private.manual_damage_quantity_schema() where object_kind='schema' and object_identity='manual_damage_quantity_schema';
update greenloop_private.damage_payable_installation set definition_hash=greenloop_private.damage_payable_schema() where object_identity='schema';
create table if not exists greenloop_private.damage_dual_price_installation(object_identity text primary key,definition_hash text not null);
alter table greenloop_private.damage_dual_price_installation enable row level security;
revoke all on greenloop_private.damage_dual_price_installation from public,anon,authenticated;
create or replace function greenloop_private.damage_dual_price_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select md5(jsonb_build_object('view',pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true),
 'columns',(select jsonb_agg(jsonb_build_array(attname,atttypid::regtype::text,attnotnull) order by attnum) from pg_attribute where attrelid='greenloop_private.manual_damage_submission_copy_prices'::regclass and attnum>0),
 'constraints',(select jsonb_agg(pg_get_constraintdef(oid) order by conname) from pg_constraint where conrelid='greenloop_private.manual_damage_submission_copy_prices'::regclass),
 'triggers',(select jsonb_agg(pg_get_triggerdef(oid)||tgenabled::text order by tgname) from pg_trigger where not tgisinternal and (tgrelid='greenloop_private.manual_damage_submission_copy_prices'::regclass or (tgrelid='greenloop_private.manual_damage_state'::regclass and tgname='damage_copy_state_valid'))))::text);
$$;
revoke all on function greenloop_private.damage_dual_price_schema() from public,anon,authenticated;
insert into greenloop_private.damage_dual_price_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in ('public.create_manual_damage_report_v6(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text,numeric)'::regprocedure,'public.correct_manual_damage_report_v5(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,numeric,boolean)'::regprocedure,'greenloop_private.validate_damage_copy_state()'::regprocedure,'greenloop_private.damage_copy_rows(jsonb)'::regprocedure,'greenloop_private.damage_copy_values(uuid)'::regprocedure,'public.get_manual_damage_cards_v6(integer,integer,integer)'::regprocedure,'public.get_manual_damage_employee_rows_v4(uuid,integer,integer)'::regprocedure,'public.get_manual_damage_export_v3(date,date)'::regprocedure,'greenloop_private.damage_basis_rows(boolean)'::regprocedure,'greenloop_private.damage_basis_summary(text,integer,integer,boolean)'::regprocedure,'public.get_damage_tv_summary_v2(text,integer,integer)'::regprocedure,'public.get_sorted_filter_records_v2(text,jsonb,integer,integer,text,text)'::regprocedure,'greenloop_private.damage_dual_price_schema()'::regprocedure) on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.damage_dual_price_installation values('schema',greenloop_private.damage_dual_price_schema()) on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_dual_price_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_tv_summary_version()='20261015-damage-tv-summary-1'
 and (select count(*)=13 and bool_and(to_regprocedure(object_identity) is not null and definition_hash=md5(pg_get_functiondef(to_regprocedure(object_identity))) and not has_function_privilege('anon',to_regprocedure(object_identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(object_identity),'EXECUTE')=(object_identity not like 'greenloop_private.%')) from greenloop_private.damage_dual_price_installation where object_identity<>'schema')
 and exists(select 1 from greenloop_private.damage_dual_price_installation where object_identity='schema' and definition_hash=greenloop_private.damage_dual_price_schema())
 and not exists(select 1 from unnest(array['greenloop_private.manual_damage_submission_copy_prices','greenloop_private.damage_dual_price_installation']) t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and (select relrowsecurity from pg_class where oid='greenloop_private.manual_damage_submission_copy_prices'::regclass)
 then '20261016-damage-dual-price-1' end;
$$;
revoke all on function public.get_damage_dual_price_version() from public;
grant execute on function public.get_damage_dual_price_version() to anon,authenticated;
do $$ begin if public.get_damage_dual_price_version() is distinct from '20261016-damage-dual-price-1' then raise exception 'Dual-price verification failed. Nothing installed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_damage_dual_price_version() as installed_damage_dual_price_version;
