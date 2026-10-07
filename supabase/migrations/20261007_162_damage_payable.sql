-- Monthly technician payable. Original entries remain immutable; legacy departments stay unassigned.
begin;
do $preflight$ begin
 if public.get_damage_tv_polish_version() is distinct from '20261006-damage-tv-polish-1'
 or public.get_manual_damage_export_version() is distinct from '20261006-damage-report-pdf-1' then
  raise exception 'Install the verified Damage TV and PDF updates first.' using errcode='55000';end if;
 if to_regprocedure('public.get_damage_payable_version()') is not null then
  if public.get_damage_payable_version() is distinct from '20261007-damage-payable-1' then raise exception 'Existing payable update differs. Nothing installed.' using errcode='55000';end if;
 elsif to_regclass('greenloop_private.manual_damage_submission_departments') is not null then
  raise exception 'Unexpected department objects. Nothing installed.' using errcode='55000';end if;
end;$preflight$;
create table if not exists greenloop_private.manual_damage_submission_departments(
 report_id uuid primary key,department text not null check(department in ('glass','other')));
alter table greenloop_private.manual_damage_submission_departments enable row level security;
revoke all on greenloop_private.manual_damage_submission_departments from public,anon,authenticated;
drop trigger if exists manual_damage_departments_immutable on greenloop_private.manual_damage_submission_departments;
create trigger manual_damage_departments_immutable before update or delete or truncate on greenloop_private.manual_damage_submission_departments for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();
create or replace function greenloop_private.require_manual_damage_department()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $guard$
begin
 if coalesce(current_setting('greenloop.damage_department',true),'') not in ('glass','other') then
  raise exception 'Department is required. Refresh Damage Entry and select the technician department.' using errcode='22023';end if;
 return new;
end;$guard$;
revoke all on function greenloop_private.require_manual_damage_department() from public,anon,authenticated;
drop trigger if exists manual_damage_department_required on public.manual_damage_reports;
create trigger manual_damage_department_required before insert on public.manual_damage_reports for each row execute function greenloop_private.require_manual_damage_department();
create or replace view greenloop_private.manual_damage_effective as
 select r.*,
  case when s.row_data ? 'price_amount' then (s.row_data->>'price_amount')::numeric else p.price_amount end as price_amount,
  case when s.row_data ? 'currency_id' then (s.row_data->>'currency_id')::uuid else p.currency_id end as currency_id,
  case when s.row_data ? 'currency' then s.row_data->>'currency' else p.currency end as currency,
  case when s.row_data ? 'part_source_id' then (s.row_data->>'part_source_id')::uuid else p.part_source_id end as part_source_id,
  case when s.row_data ? 'part_source' then s.row_data->>'part_source' else p.part_source end as part_source,
  case when s.row_data ? 'quantity' then (s.row_data->>'quantity')::integer else coalesce(q.quantity,1) end as quantity,
  case when s.row_data ? 'department' then s.row_data->>'department' else d.department end as department
 from public.manual_damage_reports b
 left join greenloop_private.manual_damage_state s on s.report_id=b.id
 left join greenloop_private.manual_damage_submission_prices p on p.report_id=b.id
 left join greenloop_private.manual_damage_submission_quantities q on q.report_id=b.id
 left join greenloop_private.manual_damage_submission_departments d on d.report_id=b.id
 cross join lateral jsonb_populate_record(null::public.manual_damage_reports,coalesce(s.row_data,to_jsonb(b))) r
 where not coalesce(s.deleted,false);

revoke all on greenloop_private.manual_damage_effective from public,anon,authenticated;
create or replace function public.create_manual_damage_report_v5(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric,p_department text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $create$
declare v_id uuid;v_department text;v_result jsonb;v_previous text;begin
 if not greenloop_private.manual_damage_access(true) then raise exception 'Damage Entry edit permission is required.' using errcode='42501';end if;
 if p_department is null or p_department not in ('glass','other') then raise exception 'Select Glass Department or Other Department.' using errcode='22023';end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_request_id::text,0));
 lock table public.manual_damage_reports in share row exclusive mode;
 select r.id,d.department into v_id,v_department from public.manual_damage_reports r left join greenloop_private.manual_damage_submission_departments d on d.report_id=r.id where r.reported_by_user_id=auth.uid() and r.request_id=p_request_id;
 if v_id is not null and v_department is distinct from p_department then raise exception 'This request ID was already used for another department. Use Data Correction for a saved entry.' using errcode='22023';end if;
 v_previous:=current_setting('greenloop.damage_department',true);
 perform set_config('greenloop.damage_department',p_department,true);
 v_result:=public.create_manual_damage_report_v4(p_request_id,p_employee_id,p_model_id,p_part_id,p_reason_id,p_identifier,p_occurred_at,p_price_amount,p_currency_id,p_part_source_id,p_quantity);
 perform set_config('greenloop.damage_department',coalesce(v_previous,''),true);
 if v_id is null then insert into greenloop_private.manual_damage_submission_departments values((v_result->>'id')::uuid,p_department);end if;
 return v_result||jsonb_build_object('department',p_department);
end;$create$;
create or replace function public.get_manual_damage_department_defaults_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $defaults$
declare result jsonb;begin
 if not greenloop_private.manual_damage_access() then raise exception 'Damage Entry view permission is required.' using errcode='42501';end if;
 select coalesce(jsonb_object_agg(employee_id,department),'{}'::jsonb) into result from (
 select employee_id,min(department) department from greenloop_private.manual_damage_effective where employee_id is not null and department is not null group by employee_id having count(distinct department)=1) r;
 return result;
end;$defaults$;
create or replace function public.get_manual_damage_export_v2(p_date_from date,p_date_to date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $export$
declare result jsonb;v_rows jsonb;begin
 result:=public.get_manual_damage_export_v1(p_date_from,p_date_to);
 if extract(day from p_date_from)<>1 then raise exception 'Monthly payable must start on the first day of a month. Choose day 01; the end date may be any day.' using errcode='22023';end if;
 select coalesce(jsonb_agg(j.value||jsonb_build_object('department',r.department,'is_lcd',lower(btrim(coalesce(r.part_name,'')))='lcd') order by j.ordinality),'[]'::jsonb)
 into v_rows from jsonb_array_elements(result->'rows') with ordinality j(value,ordinality)
 join greenloop_private.manual_damage_effective r on r.id=(j.value->>'id')::uuid;
 return result||jsonb_build_object('version','20261007-damage-payable-1','rows',v_rows);
end;$export$;
create or replace function public.correct_manual_damage_report_v4(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid,p_quantity numeric,p_department text,p_apply_department_to_unassigned boolean default false
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
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation,'department',p_department,'apply_department_to_unassigned',coalesce(p_apply_department_to_unassigned,false),'quantity',p_quantity::integer,'price_amount',p_price_amount,'currency_id',p_currency_id,'part_source_id',p_part_source_id);
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
  'quantity',p_quantity::integer,'price_amount',p_price_amount,'currency_id',p_currency_id,
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

revoke all on function public.create_manual_damage_report_v5(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text) from public,anon;
grant execute on function public.create_manual_damage_report_v5(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text) to authenticated;
revoke all on function public.correct_manual_damage_report_v4(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,boolean) from public,anon;
grant execute on function public.correct_manual_damage_report_v4(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,boolean) to authenticated;
revoke all on function public.get_manual_damage_export_v2(date,date) from public,anon;
grant execute on function public.get_manual_damage_export_v2(date,date) to authenticated;
revoke all on function public.get_manual_damage_department_defaults_v1() from public,anon;
grant execute on function public.get_manual_damage_department_defaults_v1() to authenticated;

-- The effective view gains one nullable department. Refresh only the known schema fingerprints.
update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema() where object_kind='schema' and object_identity='manual_damage_management_schema';
update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema() where object_kind='schema' and object_identity='manual_damage_price_schema';
update greenloop_private.manual_damage_quantity_installation set definition_hash=greenloop_private.manual_damage_quantity_schema() where object_kind='schema' and object_identity='manual_damage_quantity_schema';
create table if not exists greenloop_private.damage_payable_installation(object_identity text primary key,definition_hash text not null);
alter table greenloop_private.damage_payable_installation enable row level security;
revoke all on greenloop_private.damage_payable_installation from public,anon,authenticated;
create or replace function greenloop_private.damage_payable_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $schema$
 select md5(jsonb_build_object(
 'columns',(select jsonb_agg(jsonb_build_array(attname,atttypid::regtype::text,attnotnull) order by attnum) from pg_attribute where attrelid='greenloop_private.manual_damage_submission_departments'::regclass and attnum>0),
 'constraints',(select jsonb_agg(pg_get_constraintdef(oid) order by conname) from pg_constraint where conrelid='greenloop_private.manual_damage_submission_departments'::regclass),
 'triggers',(select jsonb_agg(pg_get_triggerdef(oid)||tgenabled::text order by tgname) from pg_trigger where (tgrelid='greenloop_private.manual_damage_submission_departments'::regclass or (tgrelid='public.manual_damage_reports'::regclass and tgname='manual_damage_department_required')) and not tgisinternal),
 'view',pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true))::text);
$schema$;
revoke all on function greenloop_private.damage_payable_schema() from public,anon,authenticated;
insert into greenloop_private.damage_payable_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in ('public.create_manual_damage_report_v5(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid,numeric,text)'::regprocedure,'public.correct_manual_damage_report_v4(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid,numeric,text,boolean)'::regprocedure,'public.get_manual_damage_export_v2(date,date)'::regprocedure,'public.get_manual_damage_department_defaults_v1()'::regprocedure,'greenloop_private.require_manual_damage_department()'::regprocedure,'greenloop_private.damage_payable_schema()'::regprocedure) on conflict(object_identity) do update set definition_hash=excluded.definition_hash;

insert into greenloop_private.damage_payable_installation values('schema',greenloop_private.damage_payable_schema()) on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_payable_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_export_version()='20261006-damage-report-pdf-1'
 and public.get_damage_tv_polish_version()='20261006-damage-tv-polish-1'
 and (select count(*)=6 and bool_and(to_regprocedure(object_identity) is not null and definition_hash=md5(pg_get_functiondef(to_regprocedure(object_identity))) and not has_function_privilege('anon',to_regprocedure(object_identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(object_identity),'EXECUTE')=(object_identity not like 'greenloop_private.%')) from greenloop_private.damage_payable_installation where object_identity<>'schema')
 and exists(select 1 from greenloop_private.damage_payable_installation where object_identity='schema' and definition_hash=greenloop_private.damage_payable_schema())
 and not exists(select 1 from unnest(array['greenloop_private.damage_payable_installation','greenloop_private.manual_damage_submission_departments']) t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and (select relrowsecurity from pg_class where oid='greenloop_private.manual_damage_submission_departments'::regclass)
 then '20261007-damage-payable-1' end;
$version$;
revoke all on function public.get_damage_payable_version() from public;
grant execute on function public.get_damage_payable_version() to anon,authenticated;
do $verify$ begin if public.get_damage_payable_version() is distinct from '20261007-damage-payable-1' then raise exception 'Damage payable verification failed. Nothing installed.' using errcode='55000';end if;end;$verify$;
notify pgrst,'reload schema';
commit;
select public.get_damage_payable_version() as installed_damage_payable_version;
