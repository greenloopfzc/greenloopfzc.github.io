-- Read-only technician selection for combined and individual damage PDFs.
begin;
do $$ begin
 if public.get_damage_tv_display_version() is distinct from '20261016-damage-tv-display-1' then
  raise exception 'Install the verified Damage TV Display update first.' using errcode='55000';
 end if;
end; $$;

-- Resolve legacy names only when exactly one catalog employee matches. IDs
-- remain distinct even if two catalog employees happen to share a display name.
create or replace function greenloop_private.damage_pdf_employee_key(p_id uuid,p_name text)
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(p_id::text,
  (select case when count(*)=1 then min(e.id::text) end from public.manual_damage_options e
   where e.kind='employee' and e.normalized_label=greenloop_private.manual_damage_normalized(p_name)),
  'legacy:'||greenloop_private.manual_damage_normalized(p_name));
$$;

create or replace function public.get_damage_pdf_employees_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required.' using errcode='42501';
 end if;
 with history as (
  select greenloop_private.damage_pdf_employee_key(r.employee_id,r.damaged_by) key,min(r.damaged_by) name
  from greenloop_private.manual_damage_effective r group by 1
 ), roster as (
  select e.id::text key,e.label name,not e.is_active archived
  from public.manual_damage_options e where e.kind='employee'
  and (e.is_active or exists(select 1 from history h where h.key=e.id::text))
  union all
  select h.key,h.name,false from history h where not exists(
   select 1 from public.manual_damage_options e where e.kind='employee' and e.id::text=h.key)
 ) select coalesce(jsonb_agg(jsonb_build_object('key',key,'name',name,'archived',archived) order by lower(name),key),'[]'::jsonb)
 into result from roster;
 return jsonb_build_object('employees',result);
end; $$;

create or replace function public.get_manual_damage_export_v4(p_date_from date,p_date_to date,p_employee_key text default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_rows jsonb;v_employees jsonb;v_selected jsonb;v_roster jsonb;v_count bigint;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required.' using errcode='42501';
 end if;
 if p_date_from is null or p_date_to is null or p_date_from>p_date_to
 or p_date_from<date '2000-01-01' or p_date_to>date '2100-12-31' then
  raise exception 'Select a valid start and end date.' using errcode='22023';
 end if;
 if extract(day from p_date_from)<>1 then
  raise exception 'Monthly payable must start on the first day of a month. Choose day 01; the end date may be any day.' using errcode='22023';
 end if;
 v_roster:=public.get_damage_pdf_employees_v1()->'employees';
 if p_employee_key is not null then
  select value into v_selected from jsonb_array_elements(v_roster) where value->>'key'=p_employee_key;
  if v_selected is null then raise exception 'This technician is no longer available. Close the PDF panel and reopen it.' using errcode='22023';end if;
 end if;
 -- Apply the technician filter BEFORE the export size limit. A small individual
 -- report must remain available even when the combined report is too large.
 select count(*) into v_count from greenloop_private.manual_damage_effective r
 where r.occurred_at>=p_date_from::timestamp at time zone 'Asia/Dubai'
 and r.occurred_at<(p_date_to+1)::timestamp at time zone 'Asia/Dubai'
 and (p_employee_key is null or greenloop_private.damage_pdf_employee_key(r.employee_id,r.damaged_by)=p_employee_key);
 if v_count>2000 then raise exception 'This selection contains too many entries. Select one technician or a shorter date range.' using errcode='22023';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'employee_key',greenloop_private.damage_pdf_employee_key(r.employee_id,r.damaged_by),
  'employee_name',r.damaged_by,'occurred_at',r.occurred_at,'model',r.model,'part_name',r.part_name,
  'quantity',r.quantity,'price_amount',round(r.price_amount,2)::text,'copy_price_amount',round(r.copy_price_amount,2)::text,
  'currency',r.currency,'part_source',r.part_source,'reason',r.reason,'department',r.department,
  'is_lcd',lower(btrim(coalesce(r.part_name,'')))='lcd'
 ) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from greenloop_private.manual_damage_effective r
 where r.occurred_at>=p_date_from::timestamp at time zone 'Asia/Dubai'
 and r.occurred_at<(p_date_to+1)::timestamp at time zone 'Asia/Dubai'
 and (p_employee_key is null or greenloop_private.damage_pdf_employee_key(r.employee_id,r.damaged_by)=p_employee_key);
 if p_employee_key is not null then v_employees:=jsonb_build_array(v_selected);
 else
  -- All active employees, plus historical employees who have selected entries.
  select coalesce(jsonb_agg(e.value order by lower(e.value->>'name'),e.value->>'key'),'[]'::jsonb) into v_employees
  from jsonb_array_elements(v_roster) e(value)
  where exists(select 1 from public.manual_damage_options o where o.kind='employee' and o.is_active and o.id::text=e.value->>'key')
   or exists(select 1 from jsonb_array_elements(v_rows) r(value) where r.value->>'employee_key'=e.value->>'key');
 end if;
 return jsonb_build_object('version','20261016-damage-individual-pdf-1','date_from',p_date_from,'date_to',p_date_to,
  'generated_at',now(),'selected_employee_key',p_employee_key,'record_count',v_count,'employees',v_employees,'rows',v_rows);
end; $$;

revoke all on function greenloop_private.damage_pdf_employee_key(uuid,text) from public,anon,authenticated;
revoke all on function public.get_damage_pdf_employees_v1() from public,anon,authenticated;
revoke all on function public.get_manual_damage_export_v4(date,date,text) from public,anon,authenticated;
grant execute on function public.get_damage_pdf_employees_v1(),public.get_manual_damage_export_v4(date,date,text) to authenticated;

create table if not exists greenloop_private.damage_individual_pdf_installation(identity text primary key,hash text not null);
alter table greenloop_private.damage_individual_pdf_installation enable row level security;
revoke all on greenloop_private.damage_individual_pdf_installation from public,anon,authenticated;
insert into greenloop_private.damage_individual_pdf_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname||'.'||p.proname=any(array['greenloop_private.damage_pdf_employee_key','public.get_damage_pdf_employees_v1','public.get_manual_damage_export_v4'])
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_damage_individual_pdf_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_tv_display_version()='20261016-damage-tv-display-1'
 and (select count(*)=3 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
  and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')
  and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%'))
  from greenloop_private.damage_individual_pdf_installation)
 and not has_table_privilege('anon','greenloop_private.damage_individual_pdf_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.damage_individual_pdf_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and (select relrowsecurity from pg_class where oid='greenloop_private.damage_individual_pdf_installation'::regclass)
 then '20261016-damage-individual-pdf-1' end;
$$;
revoke all on function public.get_damage_individual_pdf_version() from public;
grant execute on function public.get_damage_individual_pdf_version() to anon,authenticated;
do $$ begin if public.get_damage_individual_pdf_version() is distinct from '20261016-damage-individual-pdf-1' then
 raise exception 'Individual Damage PDF verification failed. Nothing installed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_damage_individual_pdf_version() as installed_damage_individual_pdf_version;
