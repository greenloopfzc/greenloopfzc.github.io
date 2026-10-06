-- Read-only board totals include archived employees and every effective entry.
begin;
do $preflight$ begin
 if public.get_damage_employee_totals_version() is distinct from '20261006-damage-employee-totals-1' then
  raise exception 'Install Employee Damage Totals first.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_damage_tv_polish_version()') is not null then
  if public.get_damage_tv_polish_version() is distinct from '20261006-damage-tv-polish-1' then
   raise exception 'Existing Damage TV update differs. Nothing installed.' using errcode='55000';
  end if;
 elsif to_regprocedure('public.get_manual_damage_cards_v5(integer,integer,integer)') is not null
 or to_regclass('greenloop_private.damage_tv_polish_installation') is not null then
  raise exception 'Unexpected Damage TV objects. Nothing installed.' using errcode='55000';
 end if;
end; $preflight$;
create or replace function public.get_manual_damage_cards_v5(p_offset integer default 0,p_limit integer default 4,p_row_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $cards$
declare v_board jsonb;v_values jsonb;v_unpriced bigint;
begin
 if not greenloop_private.damage_report_access() then raise exception 'Damage Report view permission is required.' using errcode='42501'; end if;
 v_board:=public.get_manual_damage_cards_v4(p_offset,p_limit,p_row_limit);
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount,'quantity',quantity) order by currency),'[]'::jsonb)
 into v_values from (
  select currency,round(sum(price_amount*quantity),2)::text as amount,sum(quantity) as quantity
  from greenloop_private.manual_damage_effective where price_amount is not null and currency is not null group by currency
 ) totals;
 select coalesce(sum(quantity),0) into v_unpriced from greenloop_private.manual_damage_effective where price_amount is null or currency is null;
 return v_board||jsonb_build_object('value_totals',v_values,'unpriced_quantity',v_unpriced);
end; $cards$;
revoke all on function public.get_manual_damage_cards_v5(integer,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_cards_v5(integer,integer,integer) to authenticated;
create table if not exists greenloop_private.damage_tv_polish_installation(singleton boolean primary key default true check(singleton),definition_hash text not null);
alter table greenloop_private.damage_tv_polish_installation enable row level security;
revoke all on greenloop_private.damage_tv_polish_installation from public,anon,authenticated;
insert into greenloop_private.damage_tv_polish_installation(singleton,definition_hash)
values(true,md5(pg_get_functiondef('public.get_manual_damage_cards_v5(integer,integer,integer)'::regprocedure)))
on conflict(singleton) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_tv_polish_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_damage_employee_totals_version()='20261006-damage-employee-totals-1'
 and exists(select 1 from greenloop_private.damage_tv_polish_installation where definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v5(integer,integer,integer)'::regprocedure)))
 and not has_function_privilege('anon','public.get_manual_damage_cards_v5(integer,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_cards_v5(integer,integer,integer)','EXECUTE')
 then '20261006-damage-tv-polish-1' else null end;
$version$;
revoke all on function public.get_damage_tv_polish_version() from public;
grant execute on function public.get_damage_tv_polish_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_damage_tv_polish_version() as installed_damage_tv_polish_version;
