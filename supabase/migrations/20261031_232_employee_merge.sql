-- Approved identity merge: EHTASHAM + Ehtesham -> EHTESHAM. No business rows are copied or deleted.
begin;
set local lock_timeout='10s';
do $$begin if public.get_b_dept_version()is distinct from '20261031-b-dept-1'then raise exception 'Install the verified B-DEPT update first.';end if;if to_regprocedure('public.get_employee_merge_version()')is not null then if public.get_employee_merge_version()is distinct from '20261031-employee-merge-1'then raise exception 'Existing employee merge needs review.';end if;end if;end;$$;
create table if not exists greenloop_private.employee_merge_aliases(option_id uuid primary key,canonical_option_id uuid not null,roster_id uuid not null,canonical_roster_id uuid not null,original_name text not null);
create table if not exists greenloop_private.employee_merge_context(pid integer not null,tx bigint not null,primary key(pid,tx));
create table if not exists greenloop_private.employee_merge_audit(merge_key text primary key,merged_at timestamptz not null default now(),canonical_roster_id uuid not null,canonical_option_id uuid not null,before_data jsonb not null,summary jsonb not null);
do $$declare t text;begin foreach t in array array['employee_merge_aliases','employee_merge_context','employee_merge_audit']loop execute format('alter table greenloop_private.%I enable row level security',t);execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);end loop;end;$$;
create or replace function greenloop_private.em_name(n text)returns text language sql immutable strict set search_path=pg_catalog as $$select case when lower(btrim(regexp_replace(n,'[[:space:]]+',' ','g')))in('ehtasham','ehtesham')then 'EHTESHAM'else upper(btrim(regexp_replace(n,'[[:space:]]+',' ','g')))end;$$;
create or replace function greenloop_private.em_audit_immutable()returns trigger language plpgsql set search_path=pg_catalog as $$begin raise exception 'Employee merge audit is permanent.'using errcode='42501';end;$$;
drop trigger if exists employee_merge_audit_immutable on greenloop_private.employee_merge_audit;
create trigger employee_merge_audit_immutable before update or delete on greenloop_private.employee_merge_audit for each row execute function greenloop_private.em_audit_immutable();
-- Narrow metadata-only maintenance boundary; no issued quantities, prices or stock may change.
do $patch$declare f regprocedure;ddl text;needle text;impl text;replacement text;begin
 f:='greenloop_private.supplier_return_work_guard()'::regprocedure;ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-employee-merge-232')=0 then
 needle:=' raise exception ''This phone is held for Supplier Return or has been returned to the supplier. New work, stock-out, and editing are blocked.'' using errcode=''55000'';';
 if strpos(ddl,needle)=0 then raise exception 'Reviewed Supplier Return guard differs.';end if;
 replacement:=$metadata$
 -- greenloop-employee-merge-232: approved identity metadata only, never operational edits.
 if tg_op='UPDATE'and exists(select 1 from greenloop_private.employee_merge_context where pid=pg_backend_pid()and tx=txid_current())then
  if tg_table_name='job_work_order_steps'
   and(v_row-array['assigned_technician_roster_id','assigned_technician_name','updated_at'])=(v_old-array['assigned_technician_roster_id','assigned_technician_name','updated_at'])
   and v_row->>'assigned_technician_name'='EHTESHAM'
   and exists(select 1 from greenloop_private.employee_merge_aliases a where a.canonical_roster_id=(v_row->>'assigned_technician_roster_id')::uuid
    and(a.roster_id=nullif(v_old->>'assigned_technician_roster_id','')::uuid or v_old->>'assigned_technician_roster_id'is null and greenloop_private.ed_key(v_old->>'assigned_technician_name')in('ehtasham','ehtesham')))
  then return new;end if;
  if tg_table_name='technician_job_timers'
   and(v_row-array['technician_roster_id','technician_name','updated_at'])=(v_old-array['technician_roster_id','technician_name','updated_at'])
   and v_row->>'technician_name'='EHTESHAM'
   and exists(select 1 from greenloop_private.employee_merge_aliases a where a.canonical_roster_id=(v_row->>'technician_roster_id')::uuid
    and(a.roster_id=nullif(v_old->>'technician_roster_id','')::uuid or v_old->>'technician_roster_id'is null and greenloop_private.ed_key(v_old->>'technician_name')in('ehtasham','ehtesham')))
  then return new;end if;
  if tg_table_name='job_part_requests'
   and(v_row-array['requested_for_technician','updated_at'])=(v_old-array['requested_for_technician','updated_at'])
   and v_row->>'requested_for_technician'='EHTESHAM'and greenloop_private.ed_key(v_old->>'requested_for_technician')in('ehtasham','ehtesham')
   and exists(select 1 from greenloop_private.employee_merge_aliases)
  then return new;end if;
 end if;
$metadata$;
 execute replace(ddl,needle,replacement||needle);end if;
 f:='greenloop_private.pf_guard()'::regprocedure;ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-employee-merge-parts-232b')=0 then
 replacement:=$parts$
 -- greenloop-employee-merge-232 / greenloop-employee-merge-parts-232b
 if tg_table_name='job_part_requests'and tg_op='UPDATE'and exists(select 1 from greenloop_private.employee_merge_context where pid=pg_backend_pid()and tx=txid_current())then
  if (to_jsonb(new)-array['requested_for_technician','updated_at'])is distinct from(to_jsonb(old)-array['requested_for_technician','updated_at'])then
   raise exception 'Employee merge cannot change Parts data. Changed fields: %',(select string_agg(k,', 'order by k)from jsonb_object_keys(to_jsonb(new))k where k not in('requested_for_technician','updated_at')and(to_jsonb(new)->k)is distinct from(to_jsonb(old)->k));
  end if;
  if new.requested_for_technician is distinct from 'EHTESHAM'or greenloop_private.ed_key(old.requested_for_technician)not in('ehtasham','ehtesham')or old.requested_for_technician is null or not exists(select 1 from greenloop_private.employee_merge_aliases)then raise exception 'Employee merge Parts identity needs review.';end if;
  -- An automatic touch trigger may run first. Keep the original business timestamp.
  new.updated_at:=old.updated_at;
  return new;
 end if;
$parts$;
 if strpos(ddl,'greenloop-employee-merge-232')>0 then
  needle:=E' -- greenloop-employee-merge-232\n if tg_table_name=''job_part_requests''and tg_op=''UPDATE''and exists(select 1 from greenloop_private.employee_merge_context where pid=pg_backend_pid()and tx=txid_current())then\n  if to_jsonb(new)-''requested_for_technician''is distinct from to_jsonb(old)-''requested_for_technician''then raise exception ''Employee merge cannot change Parts data.'';end if;return new;\n end if;\n';
  if strpos(ddl,needle)=0 then raise exception 'Reviewed employee Parts boundary differs.';end if;execute replace(ddl,needle,replacement);
 else
  needle:=' if exists(select 1 from greenloop_private.parts_flow_context';if strpos(ddl,needle)=0 then raise exception 'Reviewed Parts guard differs.';end if;execute replace(ddl,needle,replacement||needle);
 end if;end if;
 f:='greenloop_private.ed_guard()'::regprocedure;ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-employee-merge-232')=0 then
 needle:=' if current_setting(''role'',true)';if strpos(ddl,needle)=0 then raise exception 'Reviewed employee guard differs.';end if;
 execute replace(ddl,needle,E' -- greenloop-employee-merge-232\n if tg_op<>''DELETE''then\n  if tg_table_name=''technician_roster''then\n   if new.is_active and exists(select 1 from greenloop_private.employee_merge_aliases where roster_id=new.id and roster_id<>canonical_roster_id)then raise exception ''This employee was merged into EHTESHAM. Select EHTESHAM.''using errcode=''22023'';end if;\n   new.full_name:=greenloop_private.em_name(new.full_name);\n  elsif new.kind=''employee''then\n   if new.is_active and exists(select 1 from greenloop_private.employee_merge_aliases where option_id=new.id and option_id<>canonical_option_id)then raise exception ''This employee was merged into EHTESHAM. Select EHTESHAM.''using errcode=''22023'';end if;\n   new.label:=greenloop_private.em_name(new.label);\n  end if;\n end if;\n'||needle);end if;
 for impl in select implementation from greenloop_private.capability_routines where to_regprocedure(identity)in('public.add_technician_roster(text)'::regprocedure,'public.add_lab_technician(text)'::regprocedure)loop
 ddl:=replace(pg_get_functiondef(to_regprocedure(impl)),chr(13)||chr(10),chr(10));if strpos(ddl,'greenloop-employee-merge-232')=0 then needle:='begin';execute replace(ddl,needle,E'begin\n -- greenloop-employee-merge-232\n v_name:=greenloop_private.em_name(v_name);');end if;end loop;
 select implementation into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.add_manual_damage_option_v1(text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed Damage choice editor is missing.';end if;ddl:=replace(pg_get_functiondef(to_regprocedure(impl)),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-employee-merge-232')=0 then needle:='begin';execute replace(ddl,needle,E'begin\n -- greenloop-employee-merge-232\n if p_kind=''employee''then v_label:=greenloop_private.em_name(v_label);end if;');end if;
 f:='greenloop_private.tv_employee_choices()'::regprocedure;ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-employee-merge-232')=0 then needle:='where kind=''employee''';if strpos(ddl,needle)=0 then raise exception 'Reviewed TV choices differ.';end if;execute replace(ddl,needle,'where kind=''employee''and not exists(select 1 from greenloop_private.employee_merge_aliases m where m.option_id=manual_damage_options.id and m.option_id<>m.canonical_option_id) /*greenloop-employee-merge-232*/');end if;
end;$patch$;
-- Freeze writes while validating the approved identities and relinking existing rows.
do $merge$declare cr uuid;co uuid;rids uuid[];oids uuid[];before_state jsonb;raw_hash text;new_hash text;old_totals jsonb;new_totals jsonb;step_count integer;timer_count integer;part_count integer;tv_count integer;begin
 perform set_config('greenloop.em_applied','no',true);
 if exists(select 1 from greenloop_private.employee_merge_audit where merge_key='EHTASHAM+EHTESHAM')then return;end if;
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 lock table public.technician_roster,public.manual_damage_options,public.job_work_order_steps,public.technician_job_timers,public.job_part_requests,public.manual_damage_reports,greenloop_private.manual_damage_state,greenloop_private.damage_tv_employees in share row exclusive mode;
 select array_agg(id order by id)into rids from public.technician_roster where greenloop_private.ed_key(full_name)in('ehtasham','ehtesham');
 if coalesce(cardinality(rids),0)=0 then raise exception 'Neither approved employee name exists. Nothing was merged.';end if;
 select id into cr from public.technician_roster where id=any(rids)order by(greenloop_private.ed_key(full_name)='ehtesham')desc,is_active desc,created_at,id limit 1;
 select array_agg(id order by id)into oids from public.manual_damage_options where kind='employee'and normalized_label in('ehtasham','ehtesham');
 if coalesce(cardinality(oids),0)=0 or exists(select 1 from public.technician_roster r where r.id=any(rids)and not exists(select 1 from greenloop_private.employee_links l where l.roster_id=r.id and l.option_id=any(oids)))or exists(select 1 from public.manual_damage_options o where o.id=any(oids)and not exists(select 1 from greenloop_private.employee_links l where l.option_id=o.id and l.roster_id=any(rids)))then raise exception 'Employee catalog links need review. Nothing was merged.';end if;
 select option_id into co from greenloop_private.employee_links where roster_id=cr;
 select jsonb_build_object('roster',(select jsonb_agg(to_jsonb(x)order by id)from public.technician_roster x where id=any(rids)),'options',(select jsonb_agg(to_jsonb(x)order by id)from public.manual_damage_options x where id=any(oids)),'steps',(select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')from public.job_work_order_steps x where assigned_technician_roster_id=any(rids)or assigned_technician_roster_id is null and greenloop_private.ed_key(assigned_technician_name)in('ehtasham','ehtesham')),'timers',(select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')from public.technician_job_timers x where technician_roster_id=any(rids)or technician_roster_id is null and greenloop_private.ed_key(technician_name)in('ehtasham','ehtesham')),'parts',(select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')from public.job_part_requests x where greenloop_private.ed_key(requested_for_technician)in('ehtasham','ehtesham')),'tv',(select coalesce(jsonb_agg(to_jsonb(x)order by user_id),'[]')from greenloop_private.damage_tv_employees x),'report_ids',(select coalesce(jsonb_agg(id order by id),'[]')from greenloop_private.manual_damage_effective where employee_id=any(oids)or employee_id is null and greenloop_private.ed_key(damaged_by)in('ehtasham','ehtesham')))into before_state;
 select md5(coalesce(jsonb_agg(to_jsonb(b)order by id)::text,'[]'))into raw_hash from public.manual_damage_reports b;
 select jsonb_build_object('records',count(*),'ids',count(distinct id),'quantity',coalesce(sum(quantity),0),'original',coalesce(sum(price_amount*quantity),0),'copy',coalesce(sum(copy_price_amount*quantity),0))into old_totals from greenloop_private.manual_damage_effective;
 insert into greenloop_private.employee_merge_aliases select l.option_id,co,l.roster_id,cr,r.full_name from greenloop_private.employee_links l join public.technician_roster r on r.id=l.roster_id where r.id=any(rids);
 insert into greenloop_private.employee_sync_context values(pg_backend_pid(),txid_current())on conflict do nothing;
 insert into greenloop_private.employee_merge_context values(pg_backend_pid(),txid_current());
 update public.job_work_order_steps set assigned_technician_roster_id=cr,assigned_technician_name='EHTESHAM'where assigned_technician_roster_id=any(rids)or assigned_technician_roster_id is null and greenloop_private.ed_key(assigned_technician_name)in('ehtasham','ehtesham');get diagnostics step_count=row_count;
 update public.technician_job_timers set technician_roster_id=cr,technician_name='EHTESHAM'where technician_roster_id=any(rids)or technician_roster_id is null and greenloop_private.ed_key(technician_name)in('ehtasham','ehtesham');get diagnostics timer_count=row_count;
 update public.job_part_requests set requested_for_technician='EHTESHAM'where greenloop_private.ed_key(requested_for_technician)in('ehtasham','ehtesham');get diagnostics part_count=row_count;
 update public.technician_roster set is_active=false where id=any(rids)and id<>cr;
 update public.manual_damage_options set is_active=false,archived_at=coalesce(archived_at,now())where id=any(oids)and id<>co;
 update public.technician_roster set full_name='EHTESHAM',is_active=true where id=cr;
 update public.manual_damage_options set label='EHTESHAM',is_active=true,archived_at=null,archived_by=null where id=co;
 update greenloop_private.damage_tv_employees t set employee_keys=(select array_agg(distinct case when k=any(select x::text from unnest(oids)x)or k in('legacy:ehtasham','legacy:ehtesham')then co::text else k end order by case when k=any(select x::text from unnest(oids)x)or k in('legacy:ehtasham','legacy:ehtesham')then co::text else k end)from unnest(t.employee_keys)k)where employee_keys is not null and(exists(select 1 from unnest(t.employee_keys)k where k=any(select x::text from unnest(oids)x)or k in('legacy:ehtasham','legacy:ehtesham')));get diagnostics tv_count=row_count;
 delete from greenloop_private.employee_sync_context where pid=pg_backend_pid()and tx=txid_current();delete from greenloop_private.employee_merge_context where pid=pg_backend_pid()and tx=txid_current();
 select md5(coalesce(jsonb_agg(to_jsonb(b)order by id)::text,'[]'))into new_hash from public.manual_damage_reports b;
 select jsonb_build_object('records',count(*),'ids',count(distinct id),'quantity',coalesce(sum(quantity),0),'original',coalesce(sum(price_amount*quantity),0),'copy',coalesce(sum(copy_price_amount*quantity),0))into new_totals from greenloop_private.manual_damage_effective;
 if raw_hash is distinct from new_hash or old_totals is distinct from new_totals then raise exception 'Employee merge conservation check failed. Everything was rolled back.';end if;
 insert into greenloop_private.employee_merge_audit(merge_key,canonical_roster_id,canonical_option_id,before_data,summary)values('EHTASHAM+EHTESHAM',cr,co,before_state,jsonb_build_object('employee','EHTESHAM','steps_relinked',step_count,'timer_records_relinked',timer_count,'part_requests_relabelled',part_count,'tv_accounts_updated',tv_count,'raw_damage_hash',raw_hash,'damage_totals',old_totals,'merged_report_ids',before_state->'report_ids'));
 perform set_config('greenloop.em_applied','yes',true);
end;$merge$;
-- Project immutable damage rows onto one identity. Every source report ID stays exactly once.
do $view$declare cols text;begin
 if to_regclass('greenloop_private.employee_merge_damage_source')is null then execute 'create view greenloop_private.employee_merge_damage_source as '||pg_get_viewdef('greenloop_private.manual_damage_effective'::regclass,true);end if;
 select string_agg(case attname when 'employee_id'then 'case when r.employee_id in(select option_id from greenloop_private.employee_merge_aliases)or r.employee_id is null and greenloop_private.ed_key(r.damaged_by)in(''ehtasham'',''ehtesham'')then(select canonical_option_id from greenloop_private.employee_merge_aliases limit 1)else r.employee_id end as employee_id'when 'damaged_by'then 'case when r.employee_id in(select option_id from greenloop_private.employee_merge_aliases)or r.employee_id is null and greenloop_private.ed_key(r.damaged_by)in(''ehtasham'',''ehtesham'')then ''EHTESHAM''else r.damaged_by end as damaged_by'else 'r.'||quote_ident(attname)end,','order by attnum)into cols from pg_attribute where attrelid='greenloop_private.manual_damage_effective'::regclass and attnum>0 and not attisdropped;
 execute 'create or replace view greenloop_private.manual_damage_effective as select '||cols||' from greenloop_private.employee_merge_damage_source r';
 revoke all on greenloop_private.employee_merge_damage_source from public,anon,authenticated;
end;$view$;
do $conserve$declare totals jsonb;begin
 if current_setting('greenloop.em_applied',true)='yes'then
  select jsonb_build_object('records',count(*),'ids',count(distinct id),'quantity',coalesce(sum(quantity),0),'original',coalesce(sum(price_amount*quantity),0),'copy',coalesce(sum(copy_price_amount*quantity),0))into totals from greenloop_private.manual_damage_effective;
  if totals is distinct from(select summary->'damage_totals'from greenloop_private.employee_merge_audit where merge_key='EHTASHAM+EHTESHAM')then raise exception 'Combined damage totals changed. The merge was rolled back.';end if;
 end if;
end;$conserve$;

-- Refresh only reviewed changed-function receipts and the existing damage-view schema receipts.
do $seal$declare f regprocedure;t record;begin
 for f in select p.oid from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and strpos(p.prosrc,'greenloop-employee-merge-232')>0 loop
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
 for t in select c.table_name,c.column_name,h.column_name hash_col from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name in('hash','definition_hash')where c.table_schema='greenloop_private'and c.column_name in('identity','object_identity')and right(c.table_name,13)='_installation'loop
 execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where %I=$1::text',t.table_name,t.hash_col,t.column_name)using f;
 end loop;end loop;
 update greenloop_private.manual_damage_management_installation set definition_hash=greenloop_private.manual_damage_management_schema()where object_identity='manual_damage_management_schema';
 update greenloop_private.manual_damage_price_installation set definition_hash=greenloop_private.manual_damage_price_schema()where object_identity='manual_damage_price_schema';
 update greenloop_private.manual_damage_quantity_installation set definition_hash=greenloop_private.manual_damage_quantity_schema()where object_identity='manual_damage_quantity_schema';
 update greenloop_private.damage_payable_installation set definition_hash=greenloop_private.damage_payable_schema()where object_identity='schema';
 update greenloop_private.damage_dual_price_installation set definition_hash=greenloop_private.damage_dual_price_schema()where object_identity='schema';
end;$seal$;
revoke all on function greenloop_private.em_name(text),greenloop_private.em_audit_immutable()from public,anon,authenticated;
create table if not exists greenloop_private.employee_merge_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.employee_merge_installation enable row level security;revoke all on greenloop_private.employee_merge_installation from public,anon,authenticated;
create or replace function public.get_employee_merge_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_b_dept_version()='20261031-b-dept-1'
 and(select count(*)=12 and bool_and(coalesce(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else md5(pg_get_viewdef(to_regclass(identity),true))end,false))from greenloop_private.employee_merge_installation)
 and exists(select 1 from greenloop_private.employee_merge_audit where merge_key='EHTASHAM+EHTESHAM')
 and not exists(select 1 from greenloop_private.employee_merge_installation where kind='function'and identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from unnest(array['employee_merge_aliases','employee_merge_context','employee_merge_audit','employee_merge_installation'])t where has_table_privilege('anon','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated','greenloop_private.'||t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 then '20261031-employee-merge-1'end;
$$;
revoke all on function public.get_employee_merge_version()from public;grant execute on function public.get_employee_merge_version()to anon,authenticated;
insert into greenloop_private.employee_merge_installation select 'function',p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and(strpos(p.prosrc,'greenloop-employee-merge-232')>0 or p.proname in('em_name','em_audit_immutable'))or p.oid='public.get_employee_merge_version()'::regprocedure on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.employee_merge_installation select 'view',c.oid::regclass::text,md5(pg_get_viewdef(c.oid,true))from pg_class c where c.oid in('greenloop_private.manual_damage_effective'::regclass,'greenloop_private.employee_merge_damage_source'::regclass)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_employee_merge_version()is distinct from '20261031-employee-merge-1'then raise exception 'Employee merge integrity verification failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_employee_merge_version()as installed_employee_merge_version,(select summary from greenloop_private.employee_merge_audit where merge_key='EHTASHAM+EHTESHAM')as merged_employee_summary;
