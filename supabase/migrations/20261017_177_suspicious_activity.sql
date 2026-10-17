-- Explainable monitoring of NEW recorded activity. No historical backfill or business changes.
begin;
do $$ begin
 if public.get_workflow_live_notifications_version() is distinct from '20261017-workflow-live-notifications-1' or public.get_box_workflow_version() is distinct from '20261010-box-workflow-1' then
  raise exception 'Install verified Workflow Notifications first.';
 end if;
end; $$;
create table if not exists greenloop_private.suspicious_installation(identity text primary key,hash text not null);
create table if not exists greenloop_private.suspicious_rules(
 key text primary key,label text not null,enabled boolean not null,settings jsonb not null default '{}',revision integer not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid
);
create table if not exists greenloop_private.suspicious_alerts(
 id uuid primary key default gen_random_uuid(),event_key text not null unique,rule text not null,
 priority text not null check(priority in ('high','medium')),title text not null,reason text not null,
 actor_id uuid,actor_name text not null,entity text not null,department text not null,
 occurred_at timestamptz not null,detected_at timestamptz not null default clock_timestamp(),evidence jsonb not null,
 status text not null default 'new' check(status in ('new','investigating','valid','resolved')),
 revision integer not null default 1,reviewed_by uuid,reviewed_at timestamptz
);
create index if not exists suspicious_alerts_time on greenloop_private.suspicious_alerts(occurred_at desc,id);
create index if not exists suspicious_alerts_status on greenloop_private.suspicious_alerts(status,occurred_at desc);
create table if not exists greenloop_private.suspicious_reviews(
 id bigint generated always as identity primary key,alert_id uuid not null,actor_id uuid not null,actor_name text not null,
 occurred_at timestamptz not null default clock_timestamp(),old_status text not null,new_status text not null,note text not null
);
create index if not exists suspicious_reviews_alert on greenloop_private.suspicious_reviews(alert_id,id);
create table if not exists greenloop_private.suspicious_rule_audit(
 id bigint generated always as identity primary key,rule text not null,actor_id uuid not null,
 occurred_at timestamptz not null default clock_timestamp(),before_data jsonb not null,after_data jsonb not null
);
create table if not exists greenloop_private.suspicious_health(
 source text primary key,failed_at timestamptz not null,error_code text not null,failures bigint not null default 1
);
insert into greenloop_private.suspicious_rules(key,label,enabled,settings) values
 ('fast_ready','Fast completion with repair required',true,'{"minutes":10}'),
 ('missing_qc','Ready Stock with missing QC or unfinished work',true,'{}'),
 ('new_login','New browser or device type',true,'{}'),
 ('outside_hours','Login outside working hours (UAE)',false,'{"start_hour":8,"end_hour":20}'),
 ('damage_correction','Damage amount, allowance or removal changes',true,'{}'),
 ('imei_correction','IMEI identity correction',true,'{}'),
 ('verified_box','Correction to a verified export box',true,'{}')
 on conflict(key) do nothing;

-- Extend the catalog and the existing validated page allow-list only.
insert into greenloop_private.page_capability_catalog values('suspicious_activity','[{"key":"view","label":"View alerts & evidence","write":false},{"key":"search","label":"Search & date filters","write":false},{"key":"sort","label":"Sort alerts","write":false},{"key":"review","label":"Review / resolve alerts","write":true},{"key":"download","label":"Download alert report","write":false},{"key":"manage_rules","label":"Manage detection rules","write":true}]') on conflict(page_key) do update set capabilities=excluded.capabilities;
do $access$ declare d text;impl text;c record; begin
 select implementation into impl from greenloop_private.capability_routines where identity in ('save_user_page_access(uuid,text,text,boolean,text[])','public.save_user_page_access(uuid,text,text,boolean,text[])');
 if impl is null then raise exception 'Verified user access implementation not found.';end if;
 d:=pg_get_functiondef(to_regprocedure(impl));
 if position('''suspicious_activity''' in d)=0 then
  if position('''accounts'',''stock_exported''' in d)=0 then raise exception 'Unexpected user access allow-list.';end if;
  execute replace(d,'''accounts'',''stock_exported''','''accounts'',''stock_exported'',''suspicious_activity''');
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(impl))) where implementation=impl;
 end if;
 select * into c from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check';
 d:=pg_get_constraintdef(c.oid);
 if position('suspicious_activity' in d)=0 then
  execute 'alter table public.user_page_permissions drop constraint user_page_permissions_page_key_check';
  execute 'alter table public.user_page_permissions add constraint user_page_permissions_page_key_check '||replace(d,'''stock_exported''::text','''stock_exported''::text, ''suspicious_activity''::text');
 end if;
end; $access$;

-- Preserve the state BEFORE source correction returns a verified box to Accounts.
-- The old audit only stored table/id, which lost this evidence before the observer ran.
do $$ declare d text;needle text:='jsonb_build_object(''table'',tg_table_name,''record_id'',new.id)';begin
 d:=pg_get_functiondef('greenloop_private.box_source_changed()'::regprocedure);
 if position('''previous_state'',r.state' in d)=0 then
  if position(needle in d)=0 then raise exception 'Unexpected box source audit definition.';end if;
  execute replace(d,needle,'jsonb_build_object(''table'',tg_table_name,''record_id'',new.id,''previous_state'',r.state,''before'',to_jsonb(old)-array[''current_status'',''current_location_id'',''updated_at'',''notes''],''after'',to_jsonb(new)-array[''current_status'',''current_location_id'',''updated_at'',''notes''])');
  update greenloop_private.box_workflow_installation set hash=md5(pg_get_functiondef('greenloop_private.box_source_changed()'::regprocedure)) where identity='greenloop_private.box_source_changed()';
 end if;
end; $$;

-- One-time Super Admin access. Other accounts receive no new permissions.
do $$ begin
 if not exists(select 1 from greenloop_private.suspicious_installation where identity='installed_at') then
  insert into greenloop_private.user_page_capabilities(user_id,capabilities)
   select u.id,greenloop_private.user_capabilities(u.id)||'{"suspicious_activity":["view","search","sort","review","download","manage_rules"]}'::jsonb
   from public.user_profiles u where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text='super_admin')
   and not greenloop_private.damage_tv_only(u.id)
   on conflict(user_id) do update set capabilities=excluded.capabilities;
  insert into public.user_page_permissions(user_id,page_key,access_level)
   select u.id,'suspicious_activity','edit' from public.user_profiles u
   where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text='super_admin') and not greenloop_private.damage_tv_only(u.id)
   on conflict(user_id,page_key) do nothing;
  insert into greenloop_private.suspicious_installation values('installed_at',clock_timestamp()::text);
 end if;
end; $$;

create or replace function greenloop_private.suspicious_require(p_cap text)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$ begin
 if not public.has_page_capability_v1('suspicious_activity','view') or not public.has_page_capability_v1('suspicious_activity',p_cap) then
  raise exception 'Suspicious Activity % permission required.',p_cap using errcode='42501';
 end if;
end; $$;
create or replace function greenloop_private.suspicious_emit(p_key text,p_rule text,p_priority text,p_title text,p_reason text,p_actor uuid,p_entity text,p_department text,p_time timestamptz,p_evidence jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$ begin
 if not exists(select 1 from greenloop_private.suspicious_rules where key=p_rule and enabled) then return;end if;
 insert into greenloop_private.suspicious_alerts(event_key,rule,priority,title,reason,actor_id,actor_name,entity,department,occurred_at,evidence)
 values(p_key,p_rule,p_priority,p_title,p_reason,p_actor,coalesce((select nullif(full_name,'') from public.user_profiles where id=p_actor),'Not recorded'),coalesce(p_entity,'Not recorded'),p_department,p_time,p_evidence||jsonb_build_object('rule_settings',(select settings from greenloop_private.suspicious_rules where key=p_rule))) on conflict(event_key) do nothing;
end; $$;
create or replace function greenloop_private.suspicious_capture()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare ev jsonb;v_entity text;v_actor uuid;v_time timestamptz;v_required boolean;v_minutes numeric;v_limit integer;v_initial timestamptz;v_final timestamptz;v_rework timestamptz;v_pending text;v_reason text;v_rule jsonb;v_hour integer;v_op record;v_keys text[];v_before jsonb;v_after jsonb;
begin
 if tg_table_name='jobs' then
  if new.current_status::text not in ('production_pending','production_completed') or (tg_op='UPDATE' and old.current_status::text in ('production_pending','production_completed')) or new.deleted_at is not null then return new;end if;
  -- Check final transaction state: QC and transfers can be written in either order.
  if not exists(select 1 from public.jobs where id=new.id and deleted_at is null and current_status::text in ('production_pending','production_completed')) then return new;end if;
  -- Direct-export jobs do not require the repair workflow. Imported history needs its own explicit import path.
  if new.job_type::text in ('direct_export','customer_export') then return new;end if;
  select coalesce(imei_1,device_number) into v_entity from public.devices where id=new.device_id;
  select jsonb_build_object('Model',concat_ws(' ',brand,model),'Storage GB',storage_gb,'Color',color) into ev from public.devices where id=new.device_id;
  select inspected_at,work_required into v_initial,v_required from public.initial_qc_inspections where job_id=new.id;
  select case when result='pass' then inspected_at end into v_final from public.final_qc_inspections where job_id=new.id order by inspected_at desc,attempt_number desc limit 1;
  select max(created_at) into v_rework from public.device_events where job_id=new.id and event_type='ready_stock_rework_started';
  if v_final<v_rework then v_final:=null;end if;
  select string_agg(s.department::text,', ' order by s.step_order) into v_pending from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id where w.job_id=new.id and w.status<>'cancelled' and s.department::text in ('laboratory','glass','frame') and s.step_status::text not in ('completed','skipped');
  v_time:=clock_timestamp();v_actor:=auth.uid();v_minutes:=round(extract(epoch from(v_time-new.created_at))/60,2);
  ev:=coalesce(ev,'{}')||jsonb_build_object('IMEI',v_entity,'Job',new.job_number,'Received',new.received_at,'IMEI entered',new.created_at,'Initial QC',v_initial,'Final QC pass for current work',v_final,'Latest Ready Stock rework',v_rework,'Ready Stock observed',v_time,'Repair required',v_required,'Unfinished departments',v_pending,'Minutes since IMEI entry',v_minutes,'Previous stage',case when tg_op='UPDATE' then old.current_status::text else 'New record' end,'New stage',new.current_status::text,'Context','Review recorded times and work required. Fast work alone does not establish misconduct.');
  select (settings->>'minutes')::integer into v_limit from greenloop_private.suspicious_rules where key='fast_ready';
  if v_required and v_minutes>=0 and v_minutes<v_limit then
   perform greenloop_private.suspicious_emit('ready-fast:'||new.id||':'||txid_current(),'fast_ready','medium','Repair completed unusually quickly',format('This phone required repair and reached Ready Stock %s minutes after IMEI entry; the review threshold is %s minutes.',v_minutes,v_limit),v_actor,v_entity,'Ready Stock',v_time,ev);
  end if;
  if v_initial is null or v_final is null or v_pending is not null then
   v_reason:=concat_ws(' ',case when v_initial is null then 'No Initial QC inspection is recorded.' end,case when v_final is null then 'No current Final QC pass is recorded after the latest failure or Ready Stock rework.' end,case when v_pending is not null then 'Work remains unfinished in: '||v_pending||'.' end);
   perform greenloop_private.suspicious_emit('ready-missing:'||new.id||':'||txid_current(),'missing_qc','high','Ready Stock workflow needs review',v_reason,v_actor,v_entity,'Ready Stock',v_time,ev);
  end if;
 elsif tg_table_name='login_activity_sessions' then
  if not new.is_new_login or new.login_at<(select hash::timestamptz from greenloop_private.suspicious_installation where identity='installed_at') then return new;end if;
  ev:=jsonb_build_object('Username',new.username,'Browser',new.browser,'Device type',new.device_type,'Login time',new.login_at,'Opened',new.login_surface,'Context','Browser and device type come from the request user-agent. They do not identify a physical device or prove an unauthorized login.');
  if exists(select 1 from greenloop_private.login_activity_sessions where user_id=new.user_id and id<>new.id and login_at<new.login_at)
   and not exists(select 1 from greenloop_private.login_activity_sessions where user_id=new.user_id and id<>new.id and login_at<new.login_at and browser=new.browser and device_type=new.device_type) then
   perform greenloop_private.suspicious_emit('login-browser:'||new.id,'new_login','medium','New login browser or device type',format('%s signed in using %s on %s. This combination does not appear in their earlier recorded sessions.',new.full_name,new.browser,new.device_type),new.user_id,new.username,'Login',new.login_at,ev);
  end if;
  select settings into v_rule from greenloop_private.suspicious_rules where key='outside_hours';v_hour:=extract(hour from new.login_at at time zone 'Asia/Dubai');
  if not(case when (v_rule->>'start_hour')::integer<(v_rule->>'end_hour')::integer then v_hour>=(v_rule->>'start_hour')::integer and v_hour<(v_rule->>'end_hour')::integer else v_hour>=(v_rule->>'start_hour')::integer or v_hour<(v_rule->>'end_hour')::integer end) then
   perform greenloop_private.suspicious_emit('login-hours:'||new.id,'outside_hours','medium','Login outside configured hours','This successful login was recorded outside the configured UAE working hours. Confirm whether overtime or an approved shift explains it.',new.user_id,new.username,'Login',new.login_at,ev);
  end if;
 elsif tg_table_name='box_workflow_audit' then
  if new.action in ('correction','source_corrected') and new.details->>'previous_state' in ('exported','legacy') then
   ev:=jsonb_build_object('Box',new.box_number,'Previous state',new.details->>'previous_state','Before',new.details->'before','After',new.details->'after','Context','The box correction workflow returns the box to Accounts for verification. Review the changed packing details.');
   perform greenloop_private.suspicious_emit('box:'||new.id,'verified_box','high','Exported box details changed','Packing or linked source details changed after this box was verified or closed as a historical export.',new.actor,new.box_number,'Accounts',new.occurred_at,ev);
  end if;
 elsif tg_table_name='manual_damage_audit' then
  select * into v_op from greenloop_private.manual_damage_operations where id=new.operation_id;
  v_keys:=array['damaged_by','employee_id','department','quantity','price_amount','copy_price_amount','currency_id','part_name','occurred_at'];
  select coalesce(jsonb_object_agg(k,new.before_data->k),'{}'),coalesce(jsonb_object_agg(k,new.after_data->k),'{}') into v_before,v_after from unnest(v_keys) k where new.before_data->k is distinct from new.after_data->k;
  if new.after_data is null or v_before<>'{}'::jsonb then
   ev:=jsonb_build_object('Employee',new.before_data->>'damaged_by','Report ID',new.report_id,'Model',new.before_data->>'model','Part',new.before_data->>'part_name','Quantity before',new.before_data->'quantity','IMEI / identifier',new.before_data->>'identifier','Incident time',new.before_data->>'occurred_at','Operation',v_op.action,'Currency',coalesce(new.before_data->>'currency','Not recorded'),'Correction reason',v_op.reason,'Before',v_before,'After',case when new.after_data is null then 'null'::jsonb else v_after end,'Context','These fields can affect recorded damage or the monthly payable calculation. Review the correction reason; authorized corrections can be valid.');
   perform greenloop_private.suspicious_emit('damage:'||new.id,'damage_correction','medium','Damage calculation data changed',case when new.after_data is null then 'A damage entry was removed. The recorded amount and payable calculation may change.' else 'An employee, part, quantity, price, department or incident date was corrected. The damage totals or monthly allowance may change.' end,v_op.actor_user_id,coalesce(new.before_data->>'damaged_by',new.report_id::text),'Damage Report',v_op.created_at,ev);
  end if;
 elsif tg_table_name='data_change_history' then
  if new.imei_before is distinct from new.imei_after then
   ev:=jsonb_build_object('Device',new.device_number,'Job',new.job_number,'IMEI before',new.imei_before,'IMEI after',new.imei_after,'Correction reason',new.change_reason,'Context','A correction changes the identifier used to trace the phone. Confirm it against the physical phone and supplier record.');
   perform greenloop_private.suspicious_emit('imei:'||new.id,'imei_correction','high','Phone IMEI was corrected','The phone identifier changed after it was entered. Review the old IMEI, new IMEI and recorded correction reason.',new.changed_by,coalesce(new.imei_after,new.device_number),'IMEI Correction',new.changed_at,ev);
  end if;
 end if;
 return new;
exception when others then
 -- Monitoring must not roll back a legitimate department transfer. Surface failures to reviewers.
 insert into greenloop_private.suspicious_health(source,failed_at,error_code) values(tg_table_name,clock_timestamp(),sqlstate)
 on conflict(source) do update set failed_at=excluded.failed_at,error_code=excluded.error_code,failures=greenloop_private.suspicious_health.failures+1;
 return new;
end; $$;
drop trigger if exists suspicious_activity_capture on public.jobs;
create constraint trigger suspicious_activity_capture after insert or update on public.jobs deferrable initially deferred for each row execute function greenloop_private.suspicious_capture();
do $$ declare t text;begin foreach t in array array['greenloop_private.login_activity_sessions','greenloop_private.box_workflow_audit','greenloop_private.manual_damage_audit','public.data_change_history'] loop
 execute 'drop trigger if exists suspicious_activity_capture on '||t;
 execute 'create trigger suspicious_activity_capture after insert on '||t||' for each row execute function greenloop_private.suspicious_capture()';
end loop;end; $$;

create or replace function public.get_suspicious_summary_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$ declare result jsonb;begin
 perform greenloop_private.suspicious_require('view');
 select jsonb_build_object('new',count(*) filter(where status='new'),'high',count(*) filter(where priority='high' and status in ('new','investigating')),'investigating',count(*) filter(where status='investigating'),'closed',count(*) filter(where status in ('valid','resolved'))) into result from greenloop_private.suspicious_alerts;
 return result||jsonb_build_object('started_at',(select hash from greenloop_private.suspicious_installation where identity='installed_at'),'checked_at',clock_timestamp(),'health',coalesce((select jsonb_agg(to_jsonb(h)) from greenloop_private.suspicious_health h),'[]'),'rules',(select jsonb_agg(jsonb_build_object('key',key,'label',label,'enabled',enabled,'settings',settings,'revision',revision) order by key) from greenloop_private.suspicious_rules));
end; $$;
create or replace function public.get_suspicious_alerts_v1(p_filters jsonb default '{}',p_sort text default 'newest',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_total bigint;v_rows jsonb;v_limit integer:=case when p_download then 5000 else 25 end;v_from timestamptz;v_to timestamptz;v_query text;begin
 perform greenloop_private.suspicious_require('view');
 if p_download then perform greenloop_private.suspicious_require('download');end if;
 if jsonb_typeof(p_filters) is distinct from 'object' or p_offset<0 or p_offset>1000000 or p_sort not in ('newest','oldest','priority','name_asc','name_desc') then raise exception 'Invalid alert request.' using errcode='22023';end if;
 if p_filters<>'{}'::jsonb then perform greenloop_private.suspicious_require('search');end if;
 if p_sort<>'newest' then perform greenloop_private.suspicious_require('sort');end if;
 v_from:=nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dubai';
 v_to:=(nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dubai';v_query:=left(coalesce(p_filters->>'query',''),160);
 if v_from>=v_to then raise exception 'From date must be before or equal to To date.' using errcode='22023';end if;
 with matched as (select * from greenloop_private.suspicious_alerts a where
  (v_from is null or occurred_at>=v_from) and(v_to is null or occurred_at<v_to)
  and (coalesce(p_filters->>'status','')='' or status=p_filters->>'status' or (p_filters->>'status'='open' and status in ('new','investigating')))
  and (coalesce(p_filters->>'priority','')='' or priority=p_filters->>'priority')
  and (coalesce(p_filters->>'rule','')='' or rule=p_filters->>'rule')
  and (coalesce(p_filters->>'department','')='' or department=p_filters->>'department')
  and (v_query='' or strpos(lower(concat_ws(' ',actor_name,entity,title,reason,department)),lower(v_query))>0)),
 page as (select * from matched order by
  case when p_sort='oldest' then occurred_at end asc,
  case when p_sort='priority' then case priority when 'high' then 0 else 1 end end asc,
  case when p_sort='name_asc' then lower(actor_name) end asc,
  case when p_sort='name_desc' then lower(actor_name) end desc,
  occurred_at desc,id desc limit v_limit offset p_offset)
 select (select count(*) from matched),coalesce((select jsonb_agg(to_jsonb(p)-'event_key'-'evidence') from page p),'[]') into v_total,v_rows;
 if p_download and (v_total>v_limit or p_offset<>0) then raise exception 'Narrow the filters to 5,000 alerts or fewer before downloading.' using errcode='22023';end if;
 return jsonb_build_object('total',v_total,'rows',v_rows);
end; $$;
create or replace function public.get_suspicious_detail_v1(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$ declare a jsonb;begin
 perform greenloop_private.suspicious_require('view');select to_jsonb(t)-'event_key' into a from greenloop_private.suspicious_alerts t where id=p_id;
 if a is null then raise exception 'Alert not found.' using errcode='22023';end if;
 return a||jsonb_build_object('reviews',coalesce((select jsonb_agg(to_jsonb(r) order by id) from greenloop_private.suspicious_reviews r where alert_id=p_id),'[]'));
end; $$;
create or replace function public.review_suspicious_alert_v1(p_id uuid,p_status text,p_note text,p_revision integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$ declare a record;begin
 perform greenloop_private.suspicious_require('review');
 if p_status is null or p_status not in ('investigating','valid','resolved','new') or length(btrim(coalesce(p_note,''))) not between 3 and 2000 then raise exception 'Select a status and enter a review note (3–2,000 characters).' using errcode='22023';end if;
 select * into a from greenloop_private.suspicious_alerts where id=p_id for update;
 if not found or a.revision is distinct from p_revision then raise exception 'This alert changed. Refresh its details before saving.' using errcode='40001';end if;
 insert into greenloop_private.suspicious_reviews(alert_id,actor_id,actor_name,old_status,new_status,note) values(p_id,auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),a.status,p_status,btrim(p_note));
 update greenloop_private.suspicious_alerts set status=p_status,revision=revision+1,reviewed_by=auth.uid(),reviewed_at=clock_timestamp() where id=p_id;return true;
end; $$;
create or replace function public.save_suspicious_rule_v1(p_key text,p_enabled boolean,p_settings jsonb,p_revision integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$ declare r record;begin
 perform greenloop_private.suspicious_require('manage_rules');
 select * into r from greenloop_private.suspicious_rules where key=p_key for update;
 if not found or r.revision is distinct from p_revision then raise exception 'This rule changed. Refresh before saving.' using errcode='40001';end if;
 if p_enabled is null or jsonb_typeof(p_settings) is distinct from 'object' then raise exception 'Invalid rule settings.' using errcode='22023';end if;
 if p_key='fast_ready' then
  if p_settings - 'minutes'<>'{}'::jsonb or not p_settings?'minutes' or (p_settings->>'minutes')!~'^[0-9]+$' or (p_settings->>'minutes')::integer not between 1 and 120 then raise exception 'Review time must be 1–120 minutes.' using errcode='22023';end if;
 elsif p_key='outside_hours' then
  if p_settings-'start_hour'-'end_hour'<>'{}'::jsonb or not(p_settings?'start_hour' and p_settings?'end_hour') or (p_settings->>'start_hour')!~'^[0-9]+$' or (p_settings->>'end_hour')!~'^[0-9]+$' or (p_settings->>'start_hour')::integer not between 0 and 23 or (p_settings->>'end_hour')::integer not between 0 and 23 or p_settings->>'start_hour'=p_settings->>'end_hour' then raise exception 'Choose different start and end hours, 0–23 UAE time.' using errcode='22023';end if;
 elsif p_settings<>'{}'::jsonb then raise exception 'This rule has no additional settings.' using errcode='22023';end if;
 insert into greenloop_private.suspicious_rule_audit(rule,actor_id,before_data,after_data) values(p_key,auth.uid(),to_jsonb(r),jsonb_build_object('enabled',p_enabled,'settings',p_settings));
 update greenloop_private.suspicious_rules set enabled=p_enabled,settings=p_settings,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() where key=p_key;return true;
end; $$;

-- No browser can write the evidence, source records, review log or rules directly.
do $acl$ declare t text;f record;begin
 foreach t in array array['suspicious_installation','suspicious_rules','suspicious_alerts','suspicious_reviews','suspicious_rule_audit','suspicious_health'] loop
  execute format('alter table greenloop_private.%I enable row level security',t);
  execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);
 end loop;
 revoke all on sequence greenloop_private.suspicious_reviews_id_seq,greenloop_private.suspicious_rule_audit_id_seq from public,anon,authenticated;
 for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('suspicious_require','suspicious_emit','suspicious_capture','get_suspicious_summary_v1','get_suspicious_alerts_v1','get_suspicious_detail_v1','review_suspicious_alert_v1','save_suspicious_rule_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end; $acl$;
-- Reseal only the catalog and the reviewed page-key constraint; other receipts stay unchanged.
-- The new AFTER INSERT audit observer is the only change to this protected schema.
update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema() where object_kind='schema' and object_identity='manual_damage_management_schema';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
do $$ declare t text;begin foreach t in array array['greenloop_private.tv_damage_access_installation','greenloop_private.supplier_return_installation'] loop
 execute format('update %s i set definition_hash=md5(pg_get_constraintdef(c.oid)||c.convalidated::text) from pg_constraint c where i.object_kind=''constraint'' and c.conrelid=''public.user_page_permissions''::regclass and c.conname=i.object_identity and c.conname=''user_page_permissions_page_key_check''',t);
end loop;end; $$;
insert into greenloop_private.suspicious_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('suspicious_require','suspicious_emit','suspicious_capture','get_suspicious_summary_v1','get_suspicious_alerts_v1','get_suspicious_detail_v1','review_suspicious_alert_v1','save_suspicious_rule_v1') on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_suspicious_activity_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_workflow_live_notifications_version()='20261017-workflow-live-notifications-1' and public.get_box_workflow_version()='20261010-box-workflow-1'
 and (select count(*)=8 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.suspicious_installation where identity<>'installed_at')
 and (select count(*)=5 from pg_trigger where tgname='suspicious_activity_capture' and tgenabled='O' and tgfoid='greenloop_private.suspicious_capture()'::regprocedure)
 and exists(select 1 from pg_trigger where tgrelid='public.jobs'::regclass and tgname='suspicious_activity_capture' and tgdeferrable and tginitdeferred)
 and (select count(*)=6 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in ('suspicious_installation','suspicious_rules','suspicious_alerts','suspicious_reviews','suspicious_rule_audit','suspicious_health'))
 and not exists(select 1 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in ('suspicious_installation','suspicious_rules','suspicious_alerts','suspicious_reviews','suspicious_rule_audit','suspicious_health') and (not relrowsecurity or has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 then '20261017-suspicious-activity-1' end;
$$;
revoke all on function public.get_suspicious_activity_version() from public;
grant execute on function public.get_suspicious_activity_version() to anon,authenticated;
do $$ begin if public.get_suspicious_activity_version() is distinct from '20261017-suspicious-activity-1' then raise exception 'Suspicious Activity verification failed. Installation rolled back.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_suspicious_activity_version() as installed_suspicious_activity_version;
