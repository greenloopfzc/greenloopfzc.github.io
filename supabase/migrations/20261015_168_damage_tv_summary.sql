-- Read-only TV summary drill-downs and month-to-date technician settlement.
-- Existing damage records, permissions, PDF calculations and resets are unchanged.
begin;
do $$ begin
 if public.get_damage_payable_version() is distinct from '20261007-damage-payable-1'
 or public.get_damage_tv_polish_version() is distinct from '20261006-damage-tv-polish-1' then
  raise exception 'Install the verified Damage Payable and Damage TV updates first.' using errcode='55000';
 end if;
end; $$;

create or replace function public.get_damage_tv_summary_v1(p_scope text,p_offset integer default 0,p_limit integer default 12)
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
 into v_records,v_quantity,v_unpriced from greenloop_private.manual_damage_effective
 where v_from is null or (occurred_at>=v_from::timestamp at time zone 'Asia/Dubai' and occurred_at<(v_to+1)::timestamp at time zone 'Asia/Dubai');
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount) order by currency),'[]'::jsonb) into v_values
 from (select currency,round(sum(price_amount*quantity),2)::text amount from greenloop_private.manual_damage_effective
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
   from greenloop_private.manual_damage_effective r
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
      'deduction','100.00','payable',payable::text,'pending',pending) order by (record_count>0) desc,payable desc nulls first,employee_name,employee_key),'[]'::jsonb),
      count(*),count(*) filter(where pending is not null),coalesce(sum(payable),0)
    into v_employees,v_count,v_pending,v_payable from calculated;
  select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_rows
    from jsonb_array_elements(v_employees) with ordinality where ordinality>p_offset and ordinality<=p_offset::bigint+p_limit;
 else
  v_count:=v_records;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows from (
   select id,damaged_by,department,occurred_at,model,identifier,part_name,quantity,round(price_amount,2)::text price_amount,currency,
    round(price_amount*quantity,2)::text entry_total,part_source,reason,reported_by,created_at
   from greenloop_private.manual_damage_effective
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
revoke all on function public.get_damage_tv_summary_v1(text,integer,integer) from public,anon;
grant execute on function public.get_damage_tv_summary_v1(text,integer,integer) to authenticated;
create table if not exists greenloop_private.damage_tv_summary_installation(singleton boolean primary key default true check(singleton),definition_hash text not null);
alter table greenloop_private.damage_tv_summary_installation enable row level security;
revoke all on greenloop_private.damage_tv_summary_installation from public,anon,authenticated;
insert into greenloop_private.damage_tv_summary_installation values(true,md5(pg_get_functiondef('public.get_damage_tv_summary_v1(text,integer,integer)'::regprocedure)))
 on conflict(singleton) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_tv_summary_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_payable_version()='20261007-damage-payable-1'
 and exists(select 1 from greenloop_private.damage_tv_summary_installation where definition_hash=md5(pg_get_functiondef('public.get_damage_tv_summary_v1(text,integer,integer)'::regprocedure)))
 and not has_function_privilege('anon','public.get_damage_tv_summary_v1(text,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_damage_tv_summary_v1(text,integer,integer)','EXECUTE')
 and not has_table_privilege('anon','greenloop_private.damage_tv_summary_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.damage_tv_summary_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261015-damage-tv-summary-1' end;
$$;
revoke all on function public.get_damage_tv_summary_version() from public;
grant execute on function public.get_damage_tv_summary_version() to anon,authenticated;
do $$ begin if public.get_damage_tv_summary_version() is distinct from '20261015-damage-tv-summary-1' then raise exception 'Damage TV summary verification failed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_damage_tv_summary_version() as installed_damage_tv_summary_version;
