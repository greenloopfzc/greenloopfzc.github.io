-- Optional price, currency and part source per manually recorded incident.
-- No currency conversion or stock-cost integration; original labels are snapshots.
-- Original 13-column submissions and all prior audits stay byte-for-byte intact.
-- Submitted prices are immutable; corrections use the existing audited overlay.
begin;
do $preflight$
begin
 if to_regprocedure('public.get_manual_damage_management_version()') is null then
  raise exception 'Install verified migration 153 before manual damage price.' using errcode='55000';
 end if;
 if public.get_manual_damage_management_version() is distinct from '20261005-manual-damage-management-1' then
  raise exception 'Manual damage price predecessor verification failed; no changes installed.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_manual_damage_price_version()') is not null then
  if public.get_manual_damage_price_version() is distinct from '20261005-manual-damage-price-1' then
   raise exception 'Existing manual damage price verification failed; no changes installed.' using errcode='55000';
  end if;
 elsif to_regclass('greenloop_private.manual_damage_submission_prices') is not null
 or to_regclass('greenloop_private.manual_damage_price_installation') is not null
 or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='public' and p.proname in ('create_manual_damage_report_v3','correct_manual_damage_report_v2'))
  or (n.nspname='greenloop_private' and p.proname in ('prevent_manual_damage_price_changes','validate_manual_damage_price','manual_damage_submitted_price','manual_damage_price_schema'))) then
  raise exception 'Unexpected manual damage price schema; no changes installed.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_manual_damage_price_version()') is null and (
  not exists(select 1 from pg_constraint where conrelid='public.manual_damage_options'::regclass and conname='manual_damage_options_kind_check'
   and contype='c' and convalidated and regexp_replace(pg_get_constraintdef(oid),'[[:space:]]+','','g')=
    regexp_replace($expected$CHECK ((kind = ANY (ARRAY['employee'::text, 'model'::text, 'part'::text, 'reason'::text])))$expected$,'[[:space:]]+','','g'))
  or not exists(select 1 from pg_constraint where conrelid='public.manual_damage_options'::regclass and conname='manual_damage_options_check'
   and contype='c' and convalidated and regexp_replace(pg_get_constraintdef(oid),'[[:space:]]+','','g')=
    regexp_replace($expected$CHECK (((char_length(label) >= 1) AND (char_length(label) <= CASE kind WHEN 'employee'::text THEN 120 WHEN 'model'::text THEN 160 WHEN 'part'::text THEN 120 ELSE 2000 END)))$expected$,'[[:space:]]+','','g'))
 ) then
  raise exception 'Unexpected manual damage option constraints; no changes installed.' using errcode='55000';
 end if;
end;
$preflight$;

-- Extend only the reviewed catalog kind/label constraints. Existing choices,
-- their IDs, activation state and history stay unchanged on install and replay.
alter table public.manual_damage_options drop constraint manual_damage_options_kind_check;
alter table public.manual_damage_options add constraint manual_damage_options_kind_check
 check(kind in ('employee','model','part','reason','currency','part_source'));
alter table public.manual_damage_options drop constraint manual_damage_options_check;
alter table public.manual_damage_options add constraint manual_damage_options_check
 check(char_length(label) between 1 and case kind when 'employee' then 120 when 'model' then 160 when 'part' then 120 when 'currency' then 20 when 'part_source' then 120 else 2000 end);
insert into public.manual_damage_options(kind,label)
values('currency','AED'),('currency','USD'),('part_source','Local'),('part_source','China')
on conflict(kind,normalized_label) do nothing;

-- Unconstrained numeric avoids PostgreSQL rounding before validation.
create table if not exists greenloop_private.manual_damage_submission_prices(
 report_id uuid primary key,
 price_amount numeric check(price_amount is null or (price_amount>=0 and price_amount<=99999999.99 and scale(price_amount)<=2)),
 currency_id uuid,
 currency text check(currency is null or char_length(currency) between 1 and 20),
 part_source_id uuid,
 part_source text check(part_source is null or char_length(part_source) between 1 and 120),
 check((currency_id is null)=(currency is null)),
 check((part_source_id is null)=(part_source is null)),
 check(price_amount is null or currency_id is not null)
);
comment on table greenloop_private.manual_damage_submission_prices is
 'Immutable original incident amount and currency/source label snapshots, independent of inventory cost. Missing row or NULL means unknown; zero is a recorded price. No catalog foreign keys or cascading deletion.';
alter table greenloop_private.manual_damage_submission_prices enable row level security;
revoke all on greenloop_private.manual_damage_submission_prices from public,anon,authenticated;
create or replace function greenloop_private.prevent_manual_damage_price_changes()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $immutable$
begin
 raise exception 'Original manual damage prices are permanent.' using errcode='42501';
end;
$immutable$;
revoke all on function greenloop_private.prevent_manual_damage_price_changes() from public,anon,authenticated;
drop trigger if exists manual_damage_submission_prices_immutable on greenloop_private.manual_damage_submission_prices;
create trigger manual_damage_submission_prices_immutable before update or delete or truncate on greenloop_private.manual_damage_submission_prices
 for each statement execute function greenloop_private.prevent_manual_damage_price_changes();

create or replace function greenloop_private.validate_manual_damage_price(p_price_amount numeric,p_currency_id uuid)
returns void language plpgsql immutable set search_path=pg_catalog,public as $price$
begin
 if p_price_amount is not null and (p_price_amount<0 or p_price_amount>99999999.99 or scale(p_price_amount)>2) then
  raise exception 'Price must be blank or a number from 0 to 99,999,999.99 with at most two decimal places.' using errcode='22023';
 end if;
 if p_price_amount is not null and p_currency_id is null then
  raise exception 'Select a currency when recording a price.' using errcode='22023';
 end if;
end;
$price$;
revoke all on function greenloop_private.validate_manual_damage_price(numeric,uuid) from public,anon,authenticated;

create or replace function greenloop_private.manual_damage_submitted_price(p_id uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $submitted$
 select coalesce((select to_jsonb(p)-'report_id' from greenloop_private.manual_damage_submission_prices p where report_id=p_id),jsonb_build_object('price_amount',null,'currency_id',null,'currency',null,'part_source_id',null,'part_source',null));
$submitted$;
revoke all on function greenloop_private.manual_damage_submitted_price(uuid) from public,anon,authenticated;

-- JSON overlays created before this migration have no price key: use the
-- immutable source value. An explicit JSON null in a correction clears a price.
create or replace view greenloop_private.manual_damage_effective as
 select r.*,
  case when s.row_data ? 'price_amount' then (s.row_data->>'price_amount')::numeric else p.price_amount end as price_amount,
  case when s.row_data ? 'currency_id' then (s.row_data->>'currency_id')::uuid else p.currency_id end as currency_id,
  case when s.row_data ? 'currency' then s.row_data->>'currency' else p.currency end as currency,
  case when s.row_data ? 'part_source_id' then (s.row_data->>'part_source_id')::uuid else p.part_source_id end as part_source_id,
  case when s.row_data ? 'part_source' then s.row_data->>'part_source' else p.part_source end as part_source
 from public.manual_damage_reports b
 left join greenloop_private.manual_damage_state s on s.report_id=b.id
 left join greenloop_private.manual_damage_submission_prices p on p.report_id=b.id
 cross join lateral jsonb_populate_record(null::public.manual_damage_reports,coalesce(s.row_data,to_jsonb(b))) r
 where not coalesce(s.deleted,false);
revoke all on greenloop_private.manual_damage_effective from public,anon,authenticated;

-- Old create signatures still retry their immutable submitted data. They expose
-- the original price when retrying a newer request and never overwrite it.
create or replace function public.create_manual_damage_report_v1(
 p_request_id uuid,p_damaged_by text,p_model text,p_identifier text,
 p_damage text,p_reason text,p_occurred_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $create$
declare
 v_actor uuid:=auth.uid();
 v_damaged_by text:=btrim(coalesce(p_damaged_by,''),E' \t\n\r\f');
 v_model text:=btrim(coalesce(p_model,''),E' \t\n\r\f');
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_damage text:=btrim(coalesce(p_damage,''),E' \t\n\r\f');
 v_reason text:=btrim(coalesce(p_reason,''),E' \t\n\r\f');
 v_reported_by text;
 v_row public.manual_damage_reports%rowtype;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to record manual damage.' using errcode='42501';
 end if;
 if p_request_id is null then
  raise exception 'A request ID is required.' using errcode='22023';
 end if;
 if char_length(v_damaged_by) not between 1 and 120 then
  raise exception 'Damaged by is required and must be at most 120 characters.' using errcode='22023';
 end if;
 if char_length(v_model) not between 1 and 160 then
  raise exception 'Model is required and must be at most 160 characters.' using errcode='22023';
 end if;
 if char_length(v_identifier)>120 then
  raise exception 'Identifier must be at most 120 characters.' using errcode='22023';
 end if;
 if char_length(v_damage) not between 1 and 300 then
  raise exception 'Damage is required and must be at most 300 characters.' using errcode='22023';
 end if;
 if char_length(v_reason) not between 1 and 2000 then
  raise exception 'Reason is required and must be at most 2000 characters.' using errcode='22023';
 end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 select coalesce(nullif(btrim(u.full_name),''),nullif(btrim(u.login_username),''),'Staff')
 into v_reported_by from public.user_profiles u where u.id=v_actor;

 -- The unique actor/request pair serializes concurrent retries. Never use an
 -- upsert that changes the first incident or its original submitter snapshot.
 insert into public.manual_damage_reports(request_id,reported_by_user_id,reported_by,
  damaged_by,model,identifier,damage,reason,occurred_at)
 values(p_request_id,v_actor,coalesce(v_reported_by,'Staff'),
  v_damaged_by,v_model,v_identifier,v_damage,v_reason,p_occurred_at)
 on conflict(reported_by_user_id,request_id) do nothing
 returning * into v_row;
 if not found then
  select * into strict v_row from public.manual_damage_reports
  where reported_by_user_id=v_actor and request_id=p_request_id;
  if row(v_row.damaged_by,v_row.model,v_row.identifier,v_row.damage,v_row.reason,v_row.occurred_at)
    is distinct from row(v_damaged_by,v_model,v_identifier,v_damage,v_reason,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
 end if;
 return (to_jsonb(v_row)-'request_id'-'reported_by_user_id')||greenloop_private.manual_damage_submitted_price(v_row.id);
end;
$create$;

create or replace function public.create_manual_damage_report_v2(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $create$
declare
 v_actor uuid:=auth.uid();
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_reported_by text;
 v_employee public.manual_damage_options%rowtype;
 v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;
 v_reason public.manual_damage_options%rowtype;
 v_row public.manual_damage_reports%rowtype;
 v_existing boolean;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to record manual damage.' using errcode='42501';
 end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;

 -- Serialize the same actor/request before examining activation. A retry of a
 -- committed request remains valid after any selected choice was archived.
 perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_request_id::text,0));
 select * into v_row from public.manual_damage_reports where reported_by_user_id=v_actor and request_id=p_request_id;
 v_existing:=found;
 -- Lock choices in a fixed order so archive cannot race a new report commit.
 perform 1 from public.manual_damage_options
 where id in (p_employee_id,p_model_id,p_part_id,p_reason_id) order by id for share;
 select * into v_employee from public.manual_damage_options where id=p_employee_id and kind='employee';
 select * into v_model from public.manual_damage_options where id=p_model_id and kind='model';
 select * into v_part from public.manual_damage_options where id=p_part_id and kind='part';
 select * into v_reason from public.manual_damage_options where id=p_reason_id and kind='reason';
 if v_employee.id is null or v_model.id is null or v_part.id is null or v_reason.id is null then
  raise exception 'Select an employee, model, part name, and reason from the available choices.' using errcode='22023';
 end if;
 if v_existing then
  if row(v_row.employee_id,v_row.model,v_row.part_name,v_row.reason,v_row.identifier,v_row.occurred_at)
    is distinct from row(v_employee.id,v_model.label,v_part.label,v_reason.label,v_identifier,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
  return (to_jsonb(v_row)-'request_id'-'reported_by_user_id')||greenloop_private.manual_damage_submitted_price(v_row.id);
 end if;
 if not(v_employee.is_active and v_model.is_active and v_part.is_active and v_reason.is_active) then
  raise exception 'A selected employee or choice was deleted. Refresh the choices before saving.' using errcode='22023';
 end if;
 select coalesce(nullif(btrim(u.full_name),''),nullif(btrim(u.login_username),''),'Staff')
 into v_reported_by from public.user_profiles u where u.id=v_actor;
 -- The old required damage field stores the selected part label for v2 rows.
 -- Actual part display always uses the separate, explicit part_name snapshot.
 insert into public.manual_damage_reports(request_id,reported_by_user_id,reported_by,
  damaged_by,employee_id,model,identifier,damage,part_name,reason,occurred_at)
 values(p_request_id,v_actor,coalesce(v_reported_by,'Staff'),v_employee.label,v_employee.id,
  v_model.label,v_identifier,v_part.label,v_part.label,v_reason.label,p_occurred_at)
 on conflict(reported_by_user_id,request_id) do nothing returning * into v_row;
 if not found then
  select * into strict v_row from public.manual_damage_reports where reported_by_user_id=v_actor and request_id=p_request_id;
  if row(v_row.employee_id,v_row.model,v_row.part_name,v_row.reason,v_row.identifier,v_row.occurred_at)
    is distinct from row(v_employee.id,v_model.label,v_part.label,v_reason.label,v_identifier,p_occurred_at) then
   raise exception 'This request ID was already used for different manual damage details.' using errcode='22023';
  end if;
 end if;
 return (to_jsonb(v_row)-'request_id'-'reported_by_user_id')||greenloop_private.manual_damage_submitted_price(v_row.id);
end;
$create$;

create or replace function public.correct_manual_damage_report_v1(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $correct$
declare
 v_actor uuid:=auth.uid();v_name text;v_operation uuid:=gen_random_uuid();v_result jsonb;v_payload jsonb;v_previous greenloop_private.manual_damage_operations%rowtype;
 v_before jsonb;v_after jsonb;v_row jsonb;
 v_employee public.manual_damage_options%rowtype;v_model public.manual_damage_options%rowtype;
 v_part public.manual_damage_options%rowtype;v_reason public.manual_damage_options%rowtype;
 v_identifier text:=nullif(btrim(coalesce(p_identifier,''),E' \t\n\r\f'),'');
 v_explanation text:=btrim(coalesce(p_correction_reason,''),E' \t\n\r\f');
begin
 if not greenloop_private.manual_damage_management_access(true) then
  raise exception 'Reports edit and TV Manual Entry edit permission are required to correct manual damage.' using errcode='42501';
 end if;
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation);
 -- This lock also conflicts with ordinary submission INSERTs. All management
 -- writers take it before reading state, so a confirmed snapshot stays exact.
 lock table public.manual_damage_reports in share row exclusive mode;
 select * into v_previous from greenloop_private.manual_damage_operations where actor_user_id=v_actor and request_id=p_request_id;
 if found then
  if v_previous.payload is distinct from v_payload then raise exception 'This request ID was already used for different management details.' using errcode='22023'; end if;
  return jsonb_set(v_previous.result,'{row}',jsonb_build_object('price_amount',null,'currency_id',null,'currency',null,'part_source_id',null,'part_source',null)||(v_previous.result->'row'));
 end if;
 select to_jsonb(r) into v_before from greenloop_private.manual_damage_effective r where id=p_id;
 if not found or greenloop_private.manual_damage_management_row(v_before)->>'version' is distinct from p_expected_version then
  raise exception 'This entry changed or was removed. Refresh it before saving.' using errcode='40001';
 end if;
 perform 1 from public.manual_damage_options where id in (p_employee_id,p_model_id,p_part_id,p_reason_id) order by id for share;
 select * into v_employee from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 select * into v_model from public.manual_damage_options where id=p_model_id and kind='model' and is_active;
 select * into v_part from public.manual_damage_options where id=p_part_id and kind='part' and is_active;
 select * into v_reason from public.manual_damage_options where id=p_reason_id and kind='reason' and is_active;
 if v_employee.id is null or v_model.id is null or v_part.id is null or v_reason.id is null then
  raise exception 'Select an active employee, model, part and reason. Refresh the choices if one was removed.' using errcode='22023';
 end if;
 v_after:=v_before||jsonb_build_object('employee_id',v_employee.id,'damaged_by',v_employee.label,'model',v_model.label,
  'part_name',v_part.label,'damage',v_part.label,'reason',v_reason.label,'identifier',v_identifier,'occurred_at',p_occurred_at);
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

create or replace function public.correct_manual_damage_report_v2(
 p_request_id uuid,p_id uuid,p_expected_version text,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_correction_reason text,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid
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
  raise exception 'Reports edit and TV Manual Entry edit permission are required to correct manual damage.' using errcode='42501';
 end if;
 perform greenloop_private.validate_manual_damage_price(p_price_amount,p_currency_id);
 if p_request_id is null or p_id is null or coalesce(p_expected_version,'')='' then raise exception 'The request, entry and expected version are required.' using errcode='22023'; end if;
 if char_length(v_explanation) not between 3 and 2000 then raise exception 'Enter a correction reason between 3 and 2000 characters.' using errcode='22023'; end if;
 if char_length(v_identifier)>120 then raise exception 'Identifier must be at most 120 characters.' using errcode='22023'; end if;
 if p_occurred_at is null or not isfinite(p_occurred_at) or p_occurred_at>now()+interval '5 minutes' then
  raise exception 'Enter a valid incident date and time, no more than five minutes in the future.' using errcode='22023';
 end if;
 v_payload:=jsonb_build_object('action','correct','id',p_id,'version',p_expected_version,'employee',p_employee_id,
  'model',p_model_id,'part',p_part_id,'reason',p_reason_id,'identifier',v_identifier,'occurred_at',p_occurred_at,'explanation',v_explanation,'price_amount',p_price_amount,'currency_id',p_currency_id,'part_source_id',p_part_source_id);
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
  'price_amount',p_price_amount,'currency_id',p_currency_id,
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

create or replace function public.get_manual_damage_employee_rows_v1(
 p_employee_id uuid,p_offset integer default 0,p_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $rows$
declare
 v_offset integer:=greatest(0,least(coalesce(p_offset,0),1000000));
 v_limit integer:=greatest(1,least(coalesce(p_limit,6),100));
 v_normalized text;
 v_count bigint;
 v_rows jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select normalized_label into v_normalized from public.manual_damage_options where id=p_employee_id and kind='employee' and is_active;
 if not found then raise exception 'This employee does not exist.' using errcode='22023'; end if;
 select count(*) into v_count from greenloop_private.manual_damage_effective
 where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized);
 select coalesce(jsonb_agg(to_jsonb(r) order by r.occurred_at desc,r.id desc),'[]'::jsonb) into v_rows
 from (select id,occurred_at,model,part_name,reason,identifier,reported_by,created_at,price_amount,currency_id,currency,part_source_id,part_source
  from greenloop_private.manual_damage_effective
  where employee_id=p_employee_id or (employee_id is null and greenloop_private.manual_damage_normalized(damaged_by)=v_normalized)
  order by occurred_at desc,id desc offset v_offset limit v_limit) r;
 return jsonb_build_object('employee_id',p_employee_id,'total_damage',v_count,'rows',v_rows,
  'has_more',v_offset::bigint+v_limit<v_count);
end;
$rows$;

create or replace function public.get_manual_damage_cards_v1(
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
 v_employee_count bigint; v_today_count bigint; v_month_count bigint; v_total_count bigint;
 v_employees jsonb; v_activity jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required to view manual damage.' using errcode='42501';
 end if;
 select count(*) into v_employee_count from public.manual_damage_options where kind='employee' and is_active;
 select count(*),
  count(*) filter(where occurred_at>=v_today::timestamp at time zone 'Asia/Dubai'
   and occurred_at<(v_today+1)::timestamp at time zone 'Asia/Dubai'),
  count(*) filter(where occurred_at>=v_month at time zone 'Asia/Dubai'
   and occurred_at<(v_month+interval '1 month') at time zone 'Asia/Dubai')
 into v_total_count,v_today_count,v_month_count from greenloop_private.manual_damage_effective;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.label,
  'total_damage',h.data->'total_damage','rows',h.data->'rows','has_more',h.data->'has_more') order by e.sort_order,e.id),'[]'::jsonb)
 into v_employees from (select id,label,sort_order from public.manual_damage_options where kind='employee' and is_active
  order by sort_order,id offset v_offset limit v_limit) e
 cross join lateral (select public.get_manual_damage_employee_rows_v1(e.id,0,v_row_limit) as data) h;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc),'[]'::jsonb)
 into v_activity from (
  select id,created_at,occurred_at,damaged_by,model,part_name,reason,price_amount,currency_id,currency,part_source_id,part_source
  from greenloop_private.manual_damage_effective order by created_at desc,id desc limit 5
 ) r;
 return jsonb_build_object('employee_count',v_employee_count,'today_count',v_today_count,'month_count',v_month_count,
  'total_count',v_total_count,'activity',v_activity,'employees',v_employees,'has_more',v_offset::bigint+v_limit<v_employee_count);
end;
$cards$;

create or replace function public.get_manual_damage_management_audit_v1(p_id uuid default null,p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $audit$
declare v_count bigint;v_rows jsonb;v_offset integer:=greatest(0,coalesce(p_offset,0));v_limit integer:=greatest(1,least(coalesce(p_limit,20),100));
begin
 if not greenloop_private.manual_damage_management_access() then
  raise exception 'Reports and Damage Report or TV Manual Entry view permission are required.' using errcode='42501';
 end if;
 select count(*) into v_count from greenloop_private.manual_damage_audit where p_id is null or report_id=p_id;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.operation_id desc,r.id desc),'[]'::jsonb) into v_rows from (
  select a.id,a.operation_id,a.report_id,o.action,o.actor_user_id,o.actor_name,o.created_at,o.reason,o.affected_count,
   (jsonb_build_object('price_amount',null,'currency_id',null,'currency',null,'part_source_id',null,'part_source',null)||a.before_data)-'request_id'-'reported_by_user_id' as before,
   case when a.after_data is not null then (jsonb_build_object('price_amount',null,'currency_id',null,'currency',null,'part_source_id',null,'part_source',null)||a.after_data)-'request_id'-'reported_by_user_id' end as after
  from greenloop_private.manual_damage_audit a join greenloop_private.manual_damage_operations o on o.id=a.operation_id
  where p_id is null or a.report_id=p_id order by o.created_at desc,o.id desc,a.id desc offset v_offset limit v_limit
 ) r;
 return jsonb_build_object('rows',v_rows,'total_count',v_count,'has_more',v_offset::bigint+v_limit<v_count);
end;
$audit$;

create or replace function public.get_manual_damage_options_v1()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $options$
declare v_result jsonb;
begin
 if not greenloop_private.manual_damage_access() then
  raise exception 'TV Manual Entry view permission is required to view manual damage.' using errcode='42501';
 end if;
 select jsonb_build_object(
  'currencies',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='currency'),'[]'::jsonb),
  'part_sources',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part_source'),'[]'::jsonb),
  'employees',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='employee'),'[]'::jsonb),
  'models',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='model'),'[]'::jsonb),
  'parts',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part'),'[]'::jsonb),
  'reasons',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='reason'),'[]'::jsonb)
 ) into v_result from public.manual_damage_options where is_active;
 return v_result;
end;
$options$;

create or replace function public.get_manual_damage_management_v1(p_search text default '',p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $read$
declare
 v_search text:=lower(btrim(coalesce(p_search,'')));
 v_offset integer:=greatest(0,coalesce(p_offset,0));
 v_limit integer:=greatest(1,least(coalesce(p_limit,20),100));
 v_count bigint;v_rows jsonb;v_options jsonb;
begin
 if not greenloop_private.manual_damage_management_access() then
  raise exception 'Reports and Damage Report or TV Manual Entry view permission are required.' using errcode='42501';
 end if;
 if char_length(v_search)>200 then raise exception 'Search must be at most 200 characters.' using errcode='22023'; end if;
 select count(*) into v_count from greenloop_private.manual_damage_effective r
 where v_search='' or strpos(lower(concat_ws(' ',r.id::text,r.damaged_by,r.model,r.part_name,r.damage,r.reason,r.identifier,r.reported_by)),v_search)>0;
 select coalesce(jsonb_agg(greenloop_private.manual_damage_management_row(to_jsonb(r)) order by r.occurred_at desc,r.id desc),'[]'::jsonb)
 into v_rows from (select * from greenloop_private.manual_damage_effective r
  where v_search='' or strpos(lower(concat_ws(' ',r.id::text,r.damaged_by,r.model,r.part_name,r.damage,r.reason,r.identifier,r.reported_by)),v_search)>0
  order by r.occurred_at desc,r.id desc offset v_offset limit v_limit) r;
 select jsonb_build_object(
  'currencies',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='currency'),'[]'::jsonb),
  'part_sources',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part_source'),'[]'::jsonb),
  'employees',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='employee'),'[]'::jsonb),
  'models',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='model'),'[]'::jsonb),
  'parts',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='part'),'[]'::jsonb),
  'reasons',coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) filter(where kind='reason'),'[]'::jsonb)
 ) into v_options from public.manual_damage_options where is_active;
 return jsonb_build_object('rows',v_rows,'total_count',v_count,'has_more',v_offset::bigint+v_limit<v_count,
  'can_edit',greenloop_private.manual_damage_management_access(true),'can_reset',greenloop_private.manual_damage_management_access(true,true),'options',v_options);
end;
$read$;

create or replace function public.add_manual_damage_option_v1(p_kind text,p_label text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $add$
declare
 v_label text:=btrim(regexp_replace(coalesce(p_label,''),'[[:space:]]+',' ','g'));
 v_max integer;
 v_option public.manual_damage_options%rowtype;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to manage manual damage choices.' using errcode='42501';
 end if;
 v_max:=case p_kind when 'employee' then 120 when 'model' then 160 when 'part' then 120 when 'reason' then 2000 when 'currency' then 20 when 'part_source' then 120 end;
 if v_max is null then raise exception 'Choose a valid manual damage option kind.' using errcode='22023'; end if;
 if char_length(v_label) not between 1 and v_max then
  raise exception 'A label is required and must be at most % characters.',v_max using errcode='22023';
 end if;
 insert into public.manual_damage_options(kind,label,created_by)
 values(p_kind,v_label,auth.uid())
 on conflict(kind,normalized_label) do update
 set is_active=true,
  restored_at=case when not manual_damage_options.is_active then now() else manual_damage_options.restored_at end,
  restored_by=case when not manual_damage_options.is_active then auth.uid() else manual_damage_options.restored_by end
 returning * into v_option;
 return jsonb_build_object('id',v_option.id,'label',v_option.label);
end;
$add$;

create or replace function public.archive_manual_damage_option_v1(p_kind text,p_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public as $archive$
declare v_id uuid;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to manage manual damage choices.' using errcode='42501';
 end if;
 if p_kind is null or p_kind not in ('employee','model','part','reason','currency','part_source') then
  raise exception 'Choose a valid manual damage option kind.' using errcode='22023';
 end if;
 update public.manual_damage_options set is_active=false,
  archived_at=case when is_active then now() else archived_at end,
  archived_by=case when is_active then auth.uid() else archived_by end
 where id=p_id and kind=p_kind returning id into v_id;
 if not found then raise exception 'This manual damage choice does not exist.' using errcode='22023'; end if;
 return jsonb_build_object('id',v_id);
end;
$archive$;

create or replace function public.create_manual_damage_report_v3(
 p_request_id uuid,p_employee_id uuid,p_model_id uuid,p_part_id uuid,p_reason_id uuid,
 p_identifier text,p_occurred_at timestamptz,p_price_amount numeric,p_currency_id uuid,p_part_source_id uuid
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $create$
declare v_actor uuid:=auth.uid();v_id uuid;v_result jsonb;v_saved jsonb;
 v_currency public.manual_damage_options%rowtype;v_source public.manual_damage_options%rowtype;
begin
 if not greenloop_private.manual_damage_access(true) then
  raise exception 'TV Manual Entry edit permission is required to record manual damage.' using errcode='42501';
 end if;
 if p_request_id is null then raise exception 'A request ID is required.' using errcode='22023'; end if;
 perform greenloop_private.validate_manual_damage_price(p_price_amount,p_currency_id);
 -- Same ordering as the existing create RPC: actor/request lock precedes any
 -- source-table lock. The table lock serializes source+price with management.
 perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_request_id::text,0));
 lock table public.manual_damage_reports in share row exclusive mode;
 select id into v_id from public.manual_damage_reports where reported_by_user_id=v_actor and request_id=p_request_id;
 if v_id is not null then
  v_saved:=greenloop_private.manual_damage_submitted_price(v_id);
  if row((v_saved->>'price_amount')::numeric,(v_saved->>'currency_id')::uuid,(v_saved->>'part_source_id')::uuid)
   is distinct from row(p_price_amount,p_currency_id,p_part_source_id) then
   raise exception 'This request ID was already used for different manual damage price, currency or part source.' using errcode='22023';
  end if;
 else
  perform 1 from public.manual_damage_options where id in (p_currency_id,p_part_source_id) order by id for share;
  select * into v_currency from public.manual_damage_options where id=p_currency_id and kind='currency' and is_active;
  select * into v_source from public.manual_damage_options where id=p_part_source_id and kind='part_source' and is_active;
  if p_currency_id is not null and v_currency.id is null then raise exception 'Select an active currency.' using errcode='22023'; end if;
  if p_part_source_id is not null and v_source.id is null then raise exception 'Select an active part source.' using errcode='22023'; end if;
 end if;
 v_result:=public.create_manual_damage_report_v2(p_request_id,p_employee_id,p_model_id,p_part_id,p_reason_id,p_identifier,p_occurred_at);
 if v_id is null then
  insert into greenloop_private.manual_damage_submission_prices(report_id,price_amount,currency_id,currency,part_source_id,part_source)
  values((v_result->>'id')::uuid,p_price_amount,p_currency_id,v_currency.label,p_part_source_id,v_source.label);
 end if;
 return v_result||greenloop_private.manual_damage_submitted_price((v_result->>'id')::uuid);
end;
$create$;

revoke all on function public.create_manual_damage_report_v3(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid) from public,anon;
grant execute on function public.create_manual_damage_report_v3(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid) to authenticated;
revoke all on function public.correct_manual_damage_report_v2(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid) from public,anon;
grant execute on function public.correct_manual_damage_report_v2(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid) to authenticated;

-- Rebaseline only the ten deliberately replaced definitions wherever tracked.
update greenloop_private.manual_damage_report_installation i set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity) in (
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure,
 'public.get_manual_damage_management_audit_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.get_manual_damage_management_v1(text,integer,integer)'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure);
update greenloop_private.damage_employee_cards_installation i set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.function_identity)))
where to_regprocedure(i.function_identity) in (
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure,
 'public.get_manual_damage_management_audit_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.get_manual_damage_management_v1(text,integer,integer)'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure);
update greenloop_private.tv_damage_access_installation i set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.object_identity)))
where i.object_kind='function' and to_regprocedure(i.object_identity) in (
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure,
 'public.get_manual_damage_management_audit_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.get_manual_damage_management_v1(text,integer,integer)'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure);
update greenloop_private.manual_damage_management_installation i set definition_hash=md5(pg_get_functiondef(to_regprocedure(i.object_identity)))
where i.object_kind='function' and to_regprocedure(i.object_identity) in (
 'public.create_manual_damage_report_v1(uuid,text,text,text,text,text,timestamptz)'::regprocedure,
 'public.create_manual_damage_report_v2(uuid,uuid,uuid,uuid,uuid,text,timestamptz)'::regprocedure,
 'public.correct_manual_damage_report_v1(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text)'::regprocedure,
 'public.get_manual_damage_employee_rows_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_cards_v1(integer,integer,integer)'::regprocedure,
 'public.get_manual_damage_management_audit_v1(uuid,integer,integer)'::regprocedure,
 'public.get_manual_damage_options_v1()'::regprocedure,
 'public.get_manual_damage_management_v1(text,integer,integer)'::regprocedure,
 'public.add_manual_damage_option_v1(text,text)'::regprocedure,
 'public.archive_manual_damage_option_v1(text,uuid)'::regprocedure);
-- The effective view intentionally adds five nullable metadata columns; all other
-- source/state/audit schema remains unchanged and is still verified by 153.
update greenloop_private.manual_damage_management_installation
set definition_hash=greenloop_private.manual_damage_management_schema()
where object_kind='schema' and object_identity='manual_damage_management_schema';

create table if not exists greenloop_private.manual_damage_price_installation(
 object_identity text primary key,object_kind text not null check(object_kind in ('function','schema')),definition_hash text not null
);
revoke all on greenloop_private.manual_damage_price_installation from public,anon,authenticated;
create or replace function greenloop_private.manual_damage_price_schema()
returns text language sql stable security definer set search_path=pg_catalog,public as $schema$
 select md5(jsonb_build_object(
  'relations',(select jsonb_agg(jsonb_build_array(c.oid::regclass::text,c.relkind,c.relrowsecurity,c.relforcerowsecurity,c.relacl::text,c.relowner) order by c.oid::regclass::text)
   from pg_class c where c.oid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass])),
  'columns',(select jsonb_agg(jsonb_build_array(a.attrelid::regclass::text,a.attnum,a.attname,a.atttypid::regtype::text,a.atttypmod,a.attnotnull,a.attisdropped,pg_get_expr(d.adbin,d.adrelid)) order by a.attrelid::regclass::text,a.attnum)
   from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
   where a.attrelid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass]) and a.attnum>0),
  'constraints',(select jsonb_agg(jsonb_build_array(c.conrelid::regclass::text,c.conname,pg_get_constraintdef(c.oid),c.convalidated) order by c.conrelid::regclass::text,c.conname)
   from pg_constraint c where c.conrelid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass])),
  'triggers',(select jsonb_agg(jsonb_build_array(t.tgrelid::regclass::text,t.tgname,pg_get_triggerdef(t.oid),t.tgenabled) order by t.tgrelid::regclass::text,t.tgname)
   from pg_trigger t where t.tgrelid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass]) and not t.tgisinternal),
  'indexes',(select jsonb_agg(pg_get_indexdef(i.indexrelid) order by pg_get_indexdef(i.indexrelid)) from pg_index i
   where i.indrelid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass])),
  'policies',(select jsonb_agg(to_jsonb(p)-'oid' order by p.polrelid::regclass::text,p.polname) from pg_policy p
   where p.polrelid=any(array['greenloop_private.manual_damage_submission_prices'::regclass,'greenloop_private.manual_damage_price_installation'::regclass,'public.manual_damage_options'::regclass])),
  'view',pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true)
 )::text);
$schema$;
revoke all on function greenloop_private.manual_damage_price_schema() from public,anon,authenticated;
insert into greenloop_private.manual_damage_price_installation
select p.oid::regprocedure::text,'function',md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in (
 'greenloop_private.prevent_manual_damage_price_changes()'::regprocedure,
 'greenloop_private.validate_manual_damage_price(numeric,uuid)'::regprocedure,
 'greenloop_private.manual_damage_submitted_price(uuid)'::regprocedure,
 'greenloop_private.manual_damage_price_schema()'::regprocedure,
 'public.create_manual_damage_report_v3(uuid,uuid,uuid,uuid,uuid,text,timestamptz,numeric,uuid,uuid)'::regprocedure,
 'public.correct_manual_damage_report_v2(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz,text,numeric,uuid,uuid)'::regprocedure)
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;
insert into greenloop_private.manual_damage_price_installation values('manual_damage_price_schema','schema',greenloop_private.manual_damage_price_schema())
on conflict(object_identity) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_manual_damage_price_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_management_version()='20261005-manual-damage-management-1'
 and (select count(*)=6 and bool_and(to_regprocedure(i.object_identity) is not null
  and md5(pg_get_functiondef(to_regprocedure(i.object_identity)))=i.definition_hash
  and not has_function_privilege('anon',to_regprocedure(i.object_identity),'EXECUTE')
  and has_function_privilege('authenticated',to_regprocedure(i.object_identity),'EXECUTE')=(i.object_identity not like 'greenloop_private.%'))
  from greenloop_private.manual_damage_price_installation i where object_kind='function')
 and (select count(*)=1 and bool_and(definition_hash=greenloop_private.manual_damage_price_schema())
  from greenloop_private.manual_damage_price_installation where object_kind='schema' and object_identity='manual_damage_price_schema')
 and not exists(select 1 from unnest(array[
  'greenloop_private.manual_damage_submission_prices','greenloop_private.manual_damage_price_installation']) r
  where has_table_privilege('anon',r,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',r,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 then '20261005-manual-damage-price-1' end;
$version$;
revoke all on function public.get_manual_damage_price_version() from public;
grant execute on function public.get_manual_damage_price_version() to anon,authenticated;
do $verify$
begin
 if public.get_manual_damage_price_version() is distinct from '20261005-manual-damage-price-1' then
  raise exception 'Manual damage price verification failed; no changes installed.' using errcode='55000';
 end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_manual_damage_price_version() as installed_manual_damage_price_version;
