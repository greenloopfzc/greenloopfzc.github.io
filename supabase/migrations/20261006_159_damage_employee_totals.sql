-- Exact all-history damage values, separate currencies and unpriced quantities.
-- Read-only wrappers preserve existing records and installed function definitions.
begin;
do $preflight$ begin
 if public.get_damage_live_details_version() is distinct from '20261006-damage-live-details-1' then
  raise exception 'Install the verified Live Damage Details update first.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_damage_employee_totals_version()') is not null then
  if public.get_damage_employee_totals_version() is distinct from '20261006-damage-employee-totals-1' then
   raise exception 'Existing Employee Damage Totals update differs. Nothing installed.' using errcode='55000';
  end if;
 elsif to_regprocedure('public.get_manual_damage_cards_v4(integer,integer,integer)') is not null
 or to_regprocedure('public.get_manual_damage_employee_rows_v3(uuid,integer,integer)') is not null
 or to_regprocedure('greenloop_private.manual_damage_employee_value(uuid)') is not null
 or to_regclass('greenloop_private.damage_employee_totals_installation') is not null then
  raise exception 'Unexpected Employee Damage Totals objects. Nothing installed.' using errcode='55000';
 end if;
end; $preflight$;

create or replace function greenloop_private.manual_damage_employee_value(p_employee_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $value$
declare v_normalized text;v_values jsonb;v_unpriced bigint;
begin
 select normalized_label into v_normalized from public.manual_damage_options
 where id=p_employee_id and kind='employee' and is_active;
 if not found then raise exception 'This employee does not exist.' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount,'quantity',quantity) order by currency),'[]'::jsonb)
 into v_values from (
  select currency,round(sum(price_amount*quantity),2)::text as amount,sum(quantity) as quantity
  from greenloop_private.manual_damage_effective
  where (employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized))
  and price_amount is not null and currency is not null
  group by currency
 ) totals;
 select coalesce(sum(quantity),0) into v_unpriced from greenloop_private.manual_damage_effective
 where (employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized))
 and (price_amount is null or currency is null);
 return jsonb_build_object('value_totals',v_values,'unpriced_quantity',v_unpriced);
end;
$value$;
revoke all on function greenloop_private.manual_damage_employee_value(uuid) from public,anon,authenticated;

create or replace function public.get_manual_damage_employee_rows_v3(p_employee_id uuid,p_offset integer default 0,p_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $rows$
declare v_rows jsonb;
begin
 if not greenloop_private.damage_report_access() then raise exception 'Damage Report view permission is required.' using errcode='42501'; end if;
 v_rows:=public.get_manual_damage_employee_rows_v2(p_employee_id,p_offset,p_limit);
 return v_rows||greenloop_private.manual_damage_employee_value(p_employee_id);
end;
$rows$;
revoke all on function public.get_manual_damage_employee_rows_v3(uuid,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_employee_rows_v3(uuid,integer,integer) to authenticated;

create or replace function public.get_manual_damage_cards_v4(p_offset integer default 0,p_limit integer default 4,p_row_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $cards$
declare v_board jsonb;v_employees jsonb;
begin
 if not greenloop_private.damage_report_access() then raise exception 'Damage Report view permission is required.' using errcode='42501'; end if;
 v_board:=public.get_manual_damage_cards_v3(p_offset,p_limit,p_row_limit);
 select coalesce(jsonb_agg(employee||greenloop_private.manual_damage_employee_value((employee->>'id')::uuid) order by position),'[]'::jsonb)
 into v_employees from jsonb_array_elements(v_board->'employees') with ordinality as list(employee,position);
 return jsonb_set(v_board,'{employees}',v_employees);
end;
$cards$;
revoke all on function public.get_manual_damage_cards_v4(integer,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_cards_v4(integer,integer,integer) to authenticated;

create table if not exists greenloop_private.damage_employee_totals_installation(singleton boolean primary key default true check(singleton),definition_hash text not null);
alter table greenloop_private.damage_employee_totals_installation enable row level security;
revoke all on greenloop_private.damage_employee_totals_installation from public,anon,authenticated;
insert into greenloop_private.damage_employee_totals_installation(singleton,definition_hash)
 select true,md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature))
 from unnest(array['greenloop_private.manual_damage_employee_value(uuid)','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','public.get_manual_damage_cards_v4(integer,integer,integer)']) signature
 on conflict(singleton) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_employee_totals_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_damage_live_details_version()='20261006-damage-live-details-1'
 and exists(select 1 from greenloop_private.damage_employee_totals_installation where definition_hash=(
  select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature))
  from unnest(array['greenloop_private.manual_damage_employee_value(uuid)','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','public.get_manual_damage_cards_v4(integer,integer,integer)']) signature))
 and not has_function_privilege('anon','public.get_manual_damage_cards_v4(integer,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_cards_v4(integer,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.manual_damage_employee_value(uuid)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.manual_damage_employee_value(uuid)','EXECUTE')
 then '20261006-damage-employee-totals-1' else null end;
$version$;
revoke all on function public.get_damage_employee_totals_version() from public;
grant execute on function public.get_damage_employee_totals_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_damage_employee_totals_version() as installed_damage_employee_totals_version;
