-- Managed Final QC reasons and an atomic, audited return technician selection.
begin;
do $$begin
 if public.get_damage_pdf_selection_version()is distinct from '20261102-damage-pdf-selection-1'then raise exception 'Install the verified previous updates first.';end if;
 if to_regprocedure('public.get_final_qc_failure_version()')is not null then
  if public.get_final_qc_failure_version()is distinct from '20261103-final-qc-failure-1'then raise exception 'Existing Final QC Failure installation needs review.';end if;
 end if;
end;$$;
create table if not exists greenloop_private.final_qc_failure_reasons(id uuid primary key default gen_random_uuid(),label text not null check(length(label)between 1 and 120),is_active boolean not null default true,created_at timestamptz not null default now());
create unique index if not exists final_qc_failure_reason_key on greenloop_private.final_qc_failure_reasons(lower(regexp_replace(btrim(label),'\s+',' ','g')));
-- Audit snapshots deliberately have no business-record FK: scoped stock deletion
-- must not cascade into audit history or acquire a new unreviewed dependency.
create table if not exists greenloop_private.final_qc_failure_reason_audit(id uuid primary key default gen_random_uuid(),reason_id uuid not null,label text not null,action text not null,actor_id uuid,recorded_at timestamptz not null default now());
create table if not exists greenloop_private.final_qc_failure_returns(inspection_id uuid primary key,job_id uuid not null,device_id uuid not null,final_step_id uuid not null,return_step_id uuid not null,reason_id uuid not null,reason text not null,previous_technician_id uuid,previous_technician_name text,technician_id uuid not null,technician_name text not null,actor_id uuid,recorded_at timestamptz not null default now());
alter table greenloop_private.final_qc_failure_reasons enable row level security;
alter table greenloop_private.final_qc_failure_reason_audit enable row level security;
alter table greenloop_private.final_qc_failure_returns enable row level security;
revoke all on greenloop_private.final_qc_failure_reasons,greenloop_private.final_qc_failure_reason_audit,greenloop_private.final_qc_failure_returns from public,anon,authenticated;
insert into greenloop_private.final_qc_failure_reasons(label)values('Housing Issue'),('Glass Issue'),('Battery Issue'),('Face ID Issue'),('Camera Issue'),('Other')on conflict do nothing;

create or replace function greenloop_private.fqf_context(p_step uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('step_id',f.id,'job_id',j.id,'device_id',d.id,'return_step_id',l.id,'department',l.department,'technician_id',t.id,'technician_name',coalesce(t.full_name,l.assigned_technician_name),'context_token',md5(jsonb_build_array(f.id,j.current_status,l.id,l.updated_at,l.assigned_technician_roster_id,l.assigned_technician_name,l.rework_count)::text))
 from public.job_work_order_steps f join public.job_work_orders w on w.id=f.work_order_id
 join public.jobs j on j.id=w.job_id and j.deleted_at is null and j.current_status='final_qc_pending'
 join public.devices d on d.id=j.device_id and d.deleted_at is null
 join lateral(select s.*from public.job_work_order_steps s where s.work_order_id=w.id and s.department in('laboratory','glass')and s.step_status='completed'order by s.step_order desc,s.created_at desc,s.id limit 1)l on true
 left join lateral(select r.id,r.full_name from public.technician_roster r where r.is_active and greenloop_private.ed_matches(l.assigned_technician_roster_id,l.assigned_technician_name,r.id,r.full_name)order by(r.id=l.assigned_technician_roster_id)desc,r.id limit 1)t on true
 where f.id=p_step and f.department='final_qc'and f.step_status='in_progress';
$$;
revoke all on function greenloop_private.fqf_context(uuid)from public,anon,authenticated;

create or replace function public.get_final_qc_failure_options_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('final_qc','view');
 return jsonb_build_object('reasons',coalesce((select jsonb_agg(jsonb_build_object('id',id,'label',label)order by label)from greenloop_private.final_qc_failure_reasons where is_active),'[]'::jsonb),'technicians',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'full_name',r.full_name)order by r.full_name,r.id)from public.technician_roster r where r.is_active),'[]'::jsonb));
end;$$;
create or replace function public.get_final_qc_return_context_v1(p_step_ids uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('final_qc','view');
 if p_step_ids is null or cardinality(p_step_ids)>500 or array_position(p_step_ids,null)is not null then raise exception 'Select at most 500 Final QC phones.'using errcode='22023';end if;
 return coalesce((select jsonb_agg(c order by c->>'step_id')from(select greenloop_private.fqf_context(s)c from(select distinct unnest(p_step_ids)s)x)y where c is not null),'[]'::jsonb);
end;$$;
create or replace function public.save_final_qc_failure_reason_v1(p_label text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare v text:=nullif(regexp_replace(btrim(p_label),'\s+',' ','g'),'');r greenloop_private.final_qc_failure_reasons%rowtype;begin
 perform greenloop_private.pf_cap('final_qc','manage_options');
 if v is null or length(v)>120 then raise exception 'Enter a failure reason from 1 to 120 characters.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(23720261103);
 select *into r from greenloop_private.final_qc_failure_reasons where lower(regexp_replace(btrim(label),'\s+',' ','g'))=lower(v)for update;
 if r.id is null then insert into greenloop_private.final_qc_failure_reasons(label)values(v)returning *into r;
 elsif not r.is_active then update greenloop_private.final_qc_failure_reasons set is_active=true where id=r.id returning *into r;
 else return jsonb_build_object('id',r.id,'label',r.label);end if;
 insert into greenloop_private.final_qc_failure_reason_audit(reason_id,label,action,actor_id)values(r.id,r.label,'enabled',auth.uid());
 return jsonb_build_object('id',r.id,'label',r.label);
end;$$;
create or replace function public.archive_final_qc_failure_reason_v1(p_reason_id uuid,p_deletion_code text)returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare r greenloop_private.final_qc_failure_reasons%rowtype;begin
 perform greenloop_private.pf_cap('final_qc','manage_options');
 if p_deletion_code is distinct from '1213'then raise exception 'Incorrect deletion code.'using errcode='22023';end if;
 select *into r from greenloop_private.final_qc_failure_reasons where id=p_reason_id and is_active for update;
 if r.id is null then raise exception 'Select an active failure reason.'using errcode='22023';end if;
 update greenloop_private.final_qc_failure_reasons set is_active=false where id=r.id;
 insert into greenloop_private.final_qc_failure_reason_audit(reason_id,label,action,actor_id)values(r.id,r.label,'removed',auth.uid());return true;
end;$$;
create or replace function public.return_final_qc_with_technician_v1(p_final_step_id uuid,p_reason_id uuid,p_technician_id uuid,p_context_token text,p_final_battery_health smallint default null,p_battery_health_unavailable boolean default false)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare c jsonb;r greenloop_private.final_qc_failure_reasons%rowtype;t public.technician_roster%rowtype;old_step public.job_work_order_steps%rowtype;v record;j uuid;changed boolean;begin
 perform greenloop_private.pf_cap('final_qc','entry');
 perform pg_advisory_xact_lock(20420261026);
 select w.job_id into j from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs job on job.id=w.job_id and job.deleted_at is null join public.devices d on d.id=job.device_id and d.deleted_at is null where s.id=p_final_step_id and s.department='final_qc'for update of job,d,s;
 c:=greenloop_private.fqf_context(p_final_step_id);
 if c is null then raise exception 'This phone has no completed Lab / Glass step to return to. Refresh the queue.'using errcode='22023';end if;
 if p_context_token is distinct from c->>'context_token'then raise exception 'The technician assignment changed. Refresh this phone before returning it.'using errcode='40001';end if;
 select *into old_step from public.job_work_order_steps where id=(c->>'return_step_id')::uuid for update;
 select *into r from greenloop_private.final_qc_failure_reasons where id=p_reason_id and is_active for share;
 if r.id is null then raise exception 'Select an active failure reason.'using errcode='22023';end if;
 select *into t from public.technician_roster where id=p_technician_id and is_active for share;
 if t.id is null then raise exception 'Select an active technician.'using errcode='22023';end if;
 -- Preserve the native role, stage, supplier-return, battery, Parts and movement checks.
 select *into v from public.complete_final_qc_with_final_grade_v2(j,'fail',null,p_final_battery_health,'Final QC failed',old_step.department,r.label,'[]'::jsonb,p_battery_health_unavailable);
 changed:=old_step.assigned_technician_roster_id is distinct from t.id or old_step.assigned_technician_name is distinct from t.full_name;
 update public.job_work_order_steps set assigned_technician_roster_id=t.id,assigned_technician_name=t.full_name,assigned_technician_id=case when changed then null else assigned_technician_id end,assigned_at=case when changed then now()else assigned_at end where id=old_step.id and step_status='in_progress';
 if not found then raise exception 'The return assignment could not be saved. Nothing was changed.';end if;
 update public.technician_job_timers set stopped_at=now(),elapsed_seconds=greatest(0,extract(epoch from now()-started_at)::integer),stopped_by=auth.uid()where job_id=j and stopped_at is null and technician_roster_id is distinct from t.id;
 if not exists(select 1 from public.technician_job_timers where job_id=j and stopped_at is null and technician_roster_id=t.id)then
  insert into public.technician_job_timers(job_id,device_id,technician_roster_id,technician_name,started_at)values(j,(c->>'device_id')::uuid,t.id,t.full_name,now());
 end if;
 insert into greenloop_private.final_qc_failure_returns(inspection_id,job_id,device_id,final_step_id,return_step_id,reason_id,reason,previous_technician_id,previous_technician_name,technician_id,technician_name,actor_id)values(v.inspection_id,j,(c->>'device_id')::uuid,p_final_step_id,old_step.id,r.id,r.label,old_step.assigned_technician_roster_id,old_step.assigned_technician_name,t.id,t.full_name,auth.uid());
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values((c->>'device_id')::uuid,j,'final_qc_rework_assigned','Final QC rework - '||r.label||' - '||coalesce(old_step.assigned_technician_name,'Unassigned')||' to '||t.full_name,jsonb_build_object('inspection_id',v.inspection_id,'failure_reason',r.label,'previous_technician',old_step.assigned_technician_name,'technician',t.full_name,'return_department',old_step.department),auth.uid());
 return to_jsonb(v)||jsonb_build_object('technician_name',t.full_name,'failure_reason',r.label);
end;$$;
revoke all on function public.get_final_qc_failure_options_v1(),public.get_final_qc_return_context_v1(uuid[]),public.save_final_qc_failure_reason_v1(text),public.archive_final_qc_failure_reason_v1(uuid,text),public.return_final_qc_with_technician_v1(uuid,uuid,uuid,text,smallint,boolean)from public,anon,authenticated;
grant execute on function public.get_final_qc_failure_options_v1(),public.get_final_qc_return_context_v1(uuid[]),public.save_final_qc_failure_reason_v1(text),public.archive_final_qc_failure_reason_v1(uuid,text),public.return_final_qc_with_technician_v1(uuid,uuid,uuid,text,smallint,boolean)to authenticated;

-- Register the existing Office Only boundary for each new authenticated API.
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_final_qc_failure_options_v1','get_final_qc_return_context_v1','save_final_qc_failure_reason_v1','archive_final_qc_failure_reason_v1','return_final_qc_with_technician_v1')loop
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
 select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
 execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
 insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.final_qc_failure_installation(identity text primary key,hash text not null);
alter table greenloop_private.final_qc_failure_installation enable row level security;
revoke all on greenloop_private.final_qc_failure_installation from public,anon,authenticated;
create or replace function public.get_final_qc_failure_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_pdf_selection_version()='20261102-damage-pdf-selection-1'
 and(select count(*)=12 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.final_qc_failure_installation)
 and(select count(*)=4 and bool_and(relrowsecurity)from pg_class where oid=any(array['greenloop_private.final_qc_failure_reasons'::regclass,'greenloop_private.final_qc_failure_reason_audit'::regclass,'greenloop_private.final_qc_failure_returns'::regclass,'greenloop_private.final_qc_failure_installation'::regclass]))
 and not exists(select 1 from unnest(array['greenloop_private.final_qc_failure_reasons','greenloop_private.final_qc_failure_reason_audit','greenloop_private.final_qc_failure_returns','greenloop_private.final_qc_failure_installation'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not exists(select 1 from greenloop_private.final_qc_failure_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from greenloop_private.final_qc_failure_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='public'::regnamespace and p.proname<>'get_final_qc_failure_version'and(has_function_privilege('anon',p.oid,'EXECUTE')or not has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and exists(select 1 from pg_index where indexrelid=to_regclass('greenloop_private.final_qc_failure_reason_key')and indisunique)
and has_function_privilege('anon','public.get_final_qc_failure_version()','EXECUTE')and has_function_privilege('authenticated','public.get_final_qc_failure_version()','EXECUTE')
 then '20261103-final-qc-failure-1'end;
$$;
revoke all on function public.get_final_qc_failure_version()from public;grant execute on function public.get_final_qc_failure_version()to anon,authenticated;
insert into greenloop_private.final_qc_failure_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_final_qc_failure_options_v1','get_final_qc_return_context_v1','save_final_qc_failure_reason_v1','archive_final_qc_failure_reason_v1','return_final_qc_with_technician_v1','get_final_qc_failure_version')or p.oid='greenloop_private.fqf_context(uuid)'::regprocedure or p.oid in(select to_regprocedure(o.implementation)from greenloop_private.office_routines o join pg_proc q on q.oid=to_regprocedure(o.identity)where q.proname in('get_final_qc_failure_options_v1','get_final_qc_return_context_v1','save_final_qc_failure_reason_v1','archive_final_qc_failure_reason_v1','return_final_qc_with_technician_v1'))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_final_qc_failure_version()is distinct from '20261103-final-qc-failure-1'then raise exception 'Final QC Failure verification failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_final_qc_failure_version()as installed_final_qc_failure_version;
