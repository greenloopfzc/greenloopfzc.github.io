-- Read-only, date-filtered snapshot for the A4 Damage Report PDF.
-- No stock, submissions, correction history, permission grants or prices change.
begin;
do $preflight$ begin
 if public.get_manual_damage_quantity_version() is distinct from '20261006-damage-quantity-1' then
  raise exception 'Install the verified Damage Quantity update first.' using errcode='55000';
 end if;
end; $preflight$;

create or replace function public.get_manual_damage_export_v1(p_date_from date,p_date_to date)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $export$
declare v_rows jsonb; v_employees jsonb; v_count bigint;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required.' using errcode='42501';
 end if;
 if p_date_from is null or p_date_to is null or p_date_from>p_date_to
 or p_date_from<date '2000-01-01' or p_date_to>date '2100-12-31' then
  raise exception 'Select a valid start and end date.' using errcode='22023';
 end if;
 select count(*) into v_count from greenloop_private.manual_damage_effective
 where occurred_at>=p_date_from::timestamp at time zone 'Asia/Dubai'
 and occurred_at<(p_date_to+1)::timestamp at time zone 'Asia/Dubai';
 if v_count>2000 then
  raise exception 'This range contains too many entries for a four-page report. Select a shorter date range.' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'employee_key',coalesce(r.employee_id::text,'legacy:'||greenloop_private.manual_damage_normalized(r.damaged_by)),
  'employee_name',r.damaged_by,'occurred_at',r.occurred_at,'model',r.model,'part_name',r.part_name,
  'quantity',r.quantity,'price_amount',r.price_amount::text,'currency',r.currency,'part_source',r.part_source,'reason',r.reason
 ) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from greenloop_private.manual_damage_effective r
 where r.occurred_at>=p_date_from::timestamp at time zone 'Asia/Dubai'
 and r.occurred_at<(p_date_to+1)::timestamp at time zone 'Asia/Dubai';
 -- Active employees are included even with zero damage. Archived employees
 -- with incidents in the selected range are retained through the rows above.
 select coalesce(jsonb_agg(jsonb_build_object('key',e.id::text,'name',e.label)
  order by e.sort_order,e.id),'[]'::jsonb) into v_employees
 from public.manual_damage_options e where e.kind='employee' and e.is_active;
 return jsonb_build_object('version','20261006-damage-report-pdf-1','date_from',p_date_from,'date_to',p_date_to,
  'generated_at',now(),'record_count',v_count,'employees',v_employees,'rows',v_rows);
end;
$export$;
revoke all on function public.get_manual_damage_export_v1(date,date) from public,anon;
grant execute on function public.get_manual_damage_export_v1(date,date) to authenticated;

create table if not exists greenloop_private.manual_damage_export_installation(
 singleton boolean primary key default true check(singleton),definition_hash text not null);
alter table greenloop_private.manual_damage_export_installation enable row level security;
revoke all on greenloop_private.manual_damage_export_installation from public,anon,authenticated;
insert into greenloop_private.manual_damage_export_installation(singleton,definition_hash)
 values(true,md5(pg_get_functiondef('public.get_manual_damage_export_v1(date,date)'::regprocedure)))
 on conflict(singleton) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_manual_damage_export_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_quantity_version()='20261006-damage-quantity-1'
 and exists(select 1 from greenloop_private.manual_damage_export_installation
  where definition_hash=md5(pg_get_functiondef('public.get_manual_damage_export_v1(date,date)'::regprocedure)))
 and not has_function_privilege('anon','public.get_manual_damage_export_v1(date,date)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_export_v1(date,date)','EXECUTE')
 then '20261006-damage-report-pdf-1' else null end;
$version$;
revoke all on function public.get_manual_damage_export_version() from public;
grant execute on function public.get_manual_damage_export_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_manual_damage_export_version() as installed_manual_damage_export_version;
