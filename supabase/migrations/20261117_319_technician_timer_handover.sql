-- One atomic installer; no temporary tables or business-record backfill.
do $timer_install$
declare reviewed jsonb:='[]';f record;b record;t record;c record;sig text;old text;updated text;hits integer;
begin
 if to_regprocedure('public.get_technician_timer_handover_version()')is not null then
  if public.get_technician_timer_handover_version()is distinct from '20261117-technician-timer-handover-1'then raise exception 'Existing technician timer update integrity differs. Nothing installed.';end if;
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.technician_job_timers'::regclass and contype='u'and conkey=array[(select attnum from pg_attribute where attrelid='public.technician_job_timers'::regclass and attname='job_id')]::smallint[])then raise exception 'The single current timer per job boundary differs. Review before installing.';end if;

 create table if not exists greenloop_private.technician_timer_handovers(
  id uuid primary key default gen_random_uuid(),job_id uuid not null,device_id uuid not null,timer_id uuid not null,
  source text not null,previous_timer jsonb not null,closed_timer jsonb not null,current_timer jsonb not null,
  actor_id uuid,recorded_at timestamptz not null default now());
 alter table greenloop_private.technician_timer_handovers enable row level security;
 revoke all on greenloop_private.technician_timer_handovers from public,anon,authenticated;
 execute $definition$create or replace function greenloop_private.handover_technician_timer(p_job uuid,p_device uuid,p_technician uuid,p_source text)returns void language plpgsql security definer set search_path=pg_catalog,public as $body$
 declare previous public.technician_job_timers%rowtype;current_timer public.technician_job_timers%rowtype;tech public.technician_roster%rowtype;closed jsonb;at_time timestamptz:=now();history_id uuid;
 begin
  -- Callers already hold their original workflow/role/custody capability.
  -- The same job lock also serializes inserts when no timer exists yet.
  perform 1 from public.jobs j join public.devices d on d.id=j.device_id where j.id=p_job and d.id=p_device and j.deleted_at is null and d.deleted_at is null for update of j,d;
  if not found then raise exception 'The technician timer phone does not match this job.'using errcode='22023';end if;
  if p_source not in('Final QC failure','B-DEPT to Lab','Initial QC issuance')or p_source is null then raise exception 'Unknown technician timer handover.'using errcode='22023';end if;
  select *into tech from public.technician_roster where id=p_technician and is_active for share;
  if tech.id is null then raise exception 'Select an active technician.'using errcode='22023';end if;
  select *into previous from public.technician_job_timers where job_id=p_job for update;
  if previous.id is null then
   insert into public.technician_job_timers(job_id,device_id,technician_roster_id,technician_name,started_at)values(p_job,p_device,tech.id,tech.full_name,at_time);
   return;
  end if;
  if previous.device_id is distinct from p_device then raise exception 'The saved technician timer belongs to another phone.'using errcode='22023';end if;
  -- Returning to the same still-running timer must not reset elapsed work.
  if previous.stopped_at is null and previous.technician_roster_id=tech.id then return;end if;
  closed:=to_jsonb(previous);
  if previous.stopped_at is null then closed:=closed||jsonb_build_object('stopped_at',at_time,'elapsed_seconds',greatest(0,extract(epoch from at_time-previous.started_at)::integer),'stopped_by',auth.uid());end if;
  update public.technician_job_timers set technician_roster_id=tech.id,technician_name=tech.full_name,
   started_at=at_time,stopped_at=null,elapsed_seconds=null,stopped_by=null,updated_at=at_time where id=previous.id returning *into current_timer;
  -- No FK to operational records: later scoped deletion must retain this audit.
  insert into greenloop_private.technician_timer_handovers(job_id,device_id,timer_id,source,previous_timer,closed_timer,current_timer,actor_id)
   values(p_job,p_device,previous.id,p_source,to_jsonb(previous),closed,to_jsonb(current_timer),auth.uid())returning id into history_id;
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
   values(p_device,p_job,'technician_timer_handover','Technician timer - '||coalesce(previous.technician_name,'Unassigned')||' to '||tech.full_name,
    jsonb_build_object('history_id',history_id,'source',p_source,'previous_timer',to_jsonb(previous),'closed_timer',closed,'current_timer',to_jsonb(current_timer),
     'previous_technician',previous.technician_name,'technician_name',tech.full_name,'reason',p_source,
     'notes','Previous technician time: '||previous.started_at::text||' to '||(closed->>'stopped_at')||'; recorded duration '||coalesce(closed->>'elapsed_seconds','0')||' seconds.'),auth.uid());
 end;$body$;$definition$;
 revoke all on function greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)from public,anon,authenticated;

 for f in select *from(values
 ($api$public.return_final_qc_with_technician_v1(uuid,uuid,uuid,text,smallint,boolean)$api$,'final_qc_failure_installation',$pattern$update\s*public\s*\.\s*technician_job_timers\s*set\s*stopped_at\s*=\s*now\s*\(\s*\)\s*,\s*elapsed_seconds\s*=\s*greatest\s*\(\s*0\s*,\s*extract\s*\(\s*epoch\s*from\s*now\s*\(\s*\)\s*\-\s*started_at\s*\)\s*:\s*:\s*integer\s*\)\s*,\s*stopped_by\s*=\s*auth\s*\.\s*uid\s*\(\s*\)\s*where\s*job_id\s*=\s*j\s*and\s*stopped_at\s*is\s*null\s*and\s*technician_roster_id\s*is\s*distinct\s*from\s*t\s*\.\s*id\s*;\s*if\s*not\s*exists\s*\(\s*select\s*1\s*from\s*public\s*\.\s*technician_job_timers\s*where\s*job_id\s*=\s*j\s*and\s*stopped_at\s*is\s*null\s*and\s*technician_roster_id\s*=\s*t\s*\.\s*id\s*\)\s*then\s*insert\s*into\s*public\s*\.\s*technician_job_timers\s*\(\s*job_id\s*,\s*device_id\s*,\s*technician_roster_id\s*,\s*technician_name\s*,\s*started_at\s*\)\s*values\s*\(\s*j\s*,\s*\(\s*c\s*\-\s*>\s*>\s*'\s*device_id\s*'\s*\)\s*:\s*:\s*uuid\s*,\s*t\s*\.\s*id\s*,\s*t\s*\.\s*full_name\s*,\s*now\s*\(\s*\)\s*\)\s*;\s*end\s*if\s*;$pattern$,$patch$perform greenloop_private.handover_technician_timer(j,(c->>'device_id')::uuid,t.id,'Final QC failure');$patch$),
 ($api$public.record_b_dept_result_v2(uuid,text,text,integer,boolean,text,text,uuid,jsonb,jsonb)$api$,'b_dept_lab_installation',$pattern$update\s*public\s*\.\s*technician_job_timers\s*set\s*stopped_at\s*=\s*now\s*\(\s*\)\s*,\s*elapsed_seconds\s*=\s*greatest\s*\(\s*0\s*,\s*extract\s*\(\s*epoch\s*from\s*now\s*\(\s*\)\s*\-\s*started_at\s*\)\s*:\s*:\s*integer\s*\)\s*,\s*stopped_by\s*=\s*auth\s*\.\s*uid\s*\(\s*\)\s*where\s*job_id\s*=\s*v\s*\.\s*job_id\s*and\s*stopped_at\s*is\s*null\s*and\s*technician_roster_id\s*is\s*distinct\s*from\s*t\s*\.\s*id\s*;\s*if\s*not\s*exists\s*\(\s*select\s*1\s*from\s*public\s*\.\s*technician_job_timers\s*where\s*job_id\s*=\s*v\s*\.\s*job_id\s*and\s*stopped_at\s*is\s*null\s*and\s*technician_roster_id\s*=\s*t\s*\.\s*id\s*\)\s*then\s*insert\s*into\s*public\s*\.\s*technician_job_timers\s*\(\s*job_id\s*,\s*device_id\s*,\s*technician_roster_id\s*,\s*technician_name\s*,\s*started_at\s*\)\s*values\s*\(\s*v\s*\.\s*job_id\s*,\s*v\s*\.\s*device_id\s*,\s*t\s*\.\s*id\s*,\s*t\s*\.\s*full_name\s*,\s*now\s*\(\s*\)\s*\)\s*;\s*end\s*if\s*;$pattern$,$patch$perform greenloop_private.handover_technician_timer(v.job_id,v.device_id,t.id,'B-DEPT to Lab');$patch$),
 ($api$public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)$api$,'qc_issuance_installation',$pattern$if\s*not\s*exists\s*\(\s*select\s*1\s*from\s*public\s*\.\s*technician_job_timers\s*where\s*job_id\s*=\s*p_job_id\s*and\s*stopped_at\s*is\s*null\s*\)\s*then\s*insert\s*into\s*public\s*\.\s*technician_job_timers\s*\(\s*job_id\s*,\s*device_id\s*,\s*technician_roster_id\s*,\s*technician_name\s*,\s*started_at\s*\)\s*values\s*\(\s*p_job_id\s*,\s*s\s*\.\s*device_id\s*,\s*t\s*\.\s*id\s*,\s*t\s*\.\s*full_name\s*,\s*now\s*\(\s*\)\s*\)\s*;\s*end\s*if\s*;$pattern$,$patch$perform greenloop_private.handover_technician_timer(p_job_id,s.device_id,t.id,'Initial QC issuance');$patch$)
 )x(api,receipt,pattern,replacement)loop
  select implementation into sig from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure(f.api);
  if sig is null or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure(f.api)and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Workflow timer boundary is not verified: %',f.api;end if;
  execute format('select count(*)from greenloop_private.%I where replace(identity,'' '','''')=replace($1,'' '','''')and hash=md5(pg_get_functiondef(to_regprocedure($1)))',f.receipt)into hits using sig;
  if hits<>1 then raise exception 'Previous timer routine receipt is not intact: %',f.api;end if;
  old:=pg_get_functiondef(sig::regprocedure);reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old),'api',f.api));
  if position(f.replacement in old)=0 then
   select count(*)into hits from regexp_matches(old,f.pattern,'g');
   if hits<>1 then raise exception 'Expected one reviewed timer handover in %. Found %. Nothing installed.',f.api,hits;end if;
   updated:=regexp_replace(old,f.pattern,f.replacement,'g');
   if updated=old or position(f.replacement in updated)=0 then raise exception 'Timer handover patch could not be verified.';end if;
   execute updated;
  end if;
 end loop;
 -- Update only exact routine receipts whose previous hash was still intact.
 for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text,api text)loop
  for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
   for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
    execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
   end loop;
  end loop;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 end loop;
 create table if not exists greenloop_private.technician_timer_handover_installation(identity text primary key,hash text not null);
 alter table greenloop_private.technician_timer_handover_installation enable row level security;
 revoke all on greenloop_private.technician_timer_handover_installation from public,anon,authenticated;
 execute $definition$create or replace function public.get_technician_timer_handover_version()returns text language sql stable security definer set search_path=pg_catalog,public as $body$
 select case when(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.technician_timer_handover_installation)
 and not has_function_privilege('anon','greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)','EXECUTE')
 and not exists(select 1 from greenloop_private.technician_timer_handover_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='greenloop_private'::regnamespace and(has_function_privilege('anon',p.oid,'EXECUTE')or has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and not exists(select 1 from greenloop_private.technician_timer_handover_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='public'::regnamespace and p.proname<>'get_technician_timer_handover_version'and(has_function_privilege('anon',p.oid,'EXECUTE')or not has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and(select count(*)=2 and bool_and(relrowsecurity)from pg_class where oid=any(array['greenloop_private.technician_timer_handover_installation'::regclass,'greenloop_private.technician_timer_handovers'::regclass]))
 and not exists(select 1 from unnest(array['greenloop_private.technician_timer_handover_installation','greenloop_private.technician_timer_handovers'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and exists(select 1 from pg_constraint where conrelid='public.technician_job_timers'::regclass and contype='u'and conkey=array[(select attnum from pg_attribute where attrelid='public.technician_job_timers'::regclass and attname='job_id')]::smallint[])
 then '20261117-technician-timer-handover-1'end;$body$;$definition$;
 revoke all on function public.get_technician_timer_handover_version()from public;grant execute on function public.get_technician_timer_handover_version()to anon,authenticated;
 insert into greenloop_private.technician_timer_handover_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from jsonb_to_recordset(reviewed)as x(identity text)on conflict(identity)do update set hash=excluded.hash;
 insert into greenloop_private.technician_timer_handover_installation select to_regprocedure(api)::text,md5(pg_get_functiondef(to_regprocedure(api)))from jsonb_to_recordset(reviewed)as x(api text)on conflict(identity)do update set hash=excluded.hash;
 insert into greenloop_private.technician_timer_handover_installation select x.signature,md5(pg_get_functiondef(x.signature::regprocedure))from unnest(array['greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)','public.get_technician_timer_handover_version()'])x(signature)on conflict(identity)do update set hash=excluded.hash;
 if public.get_technician_timer_handover_version()is distinct from '20261117-technician-timer-handover-1'then raise exception 'Technician timer handover verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$timer_install$;
select public.get_technician_timer_handover_version()as installed_technician_timer_handover_version;
