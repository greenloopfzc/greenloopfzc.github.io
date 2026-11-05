-- Amend saved inspection requirements before handover. Preserve original QC
-- dates, grades and identities; retain removed findings/parts and append audit.
begin;
do $$begin
 if public.get_qc_notification_counts_version() is distinct from '20261105-qc-notification-counts-1' then
  raise exception 'Install verified QC Notification Counts first.';
 end if;
end;$$;
create table if not exists greenloop_private.qc_issuance_amendments(
 request_id uuid primary key,job_id uuid not null,device_id uuid not null,inspection_id uuid not null,
 actor_id uuid not null,changed_at timestamptz not null default now(),payload_hash text not null,
 before_revision text not null,after_revision text not null,before_work jsonb not null,after_work jsonb not null
);
alter table greenloop_private.qc_issuance_amendments enable row level security;
revoke all on greenloop_private.qc_issuance_amendments from public,anon,authenticated;
create index if not exists qc_issuance_amendments_job on greenloop_private.qc_issuance_amendments(job_id,changed_at);

-- The legacy Lab seed read all service findings, including ones marked false.
-- Keep inactive findings for history while seeding only the current selection.
do $services$declare impl regprocedure:='greenloop_private.ps_service_state(uuid)'::regprocedure;ddl text:=pg_get_functiondef(impl);t record;
 needle text:='where wo.id=w and c<=1 and public.is_initial_qc_service(f.check_item)';
 replacement text:='where wo.id=w and c<=1 and f.issue_found and public.is_initial_qc_service(f.check_item)';
begin
 if strpos(ddl,replacement)=0 then
  if strpos(ddl,needle)=0 then raise exception 'Reviewed Lab service seed boundary differs. Nothing changed.';end if;
  execute replace(ddl,needle,replacement);
 end if;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
 where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using impl;
 end loop;
end;$services$;

-- Legacy workbench summaries include inactive QC findings for history. For
-- amended inspections, show the selected requirements while keeping history
-- in the original rows, the amendment audit and the device event.
create or replace function greenloop_private.qcie_workbench(data jsonb)returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
 select case when jsonb_typeof(data->'rows')='array'then jsonb_set(data,'{rows}',coalesce((
  select jsonb_agg(case when exists(select 1 from greenloop_private.qc_issuance_amendments a where a.job_id=(r->>'job_id')::uuid)then
   r||jsonb_build_object(
    'initial_parts',coalesce((select jsonb_agg(x order by n)from jsonb_array_elements(coalesce(r->'initial_parts','[]'))with ordinality p(x,n)
      where coalesce(x->>'status','')not in('not_required','cancelled')),'[]'),
    'initial_services',coalesce((select jsonb_agg(x order by n)from jsonb_array_elements(coalesce(r->'initial_services','[]'))with ordinality p(x,n)
      where exists(select 1 from public.initial_qc_findings f where f.id=(x->>'id')::uuid and f.issue_found)),'[]'))
   else r end order by pos)from jsonb_array_elements(data->'rows')with ordinality q(r,pos)
 ),'[]'))else data end;
$$;
revoke all on function greenloop_private.qcie_workbench(jsonb)from public,anon,authenticated;
do $bench$declare impl text;ddl text;needle text;id regprocedure:='public.get_ranked_lab_workbench_v1(uuid,text)'::regprocedure;t record;begin
 ddl:=pg_get_functiondef(id);
 if strpos(ddl,'greenloop_private.qcie_workbench(')=0 then
  select split_part(implementation,'(',1)into impl from greenloop_private.office_routines where to_regprocedure(identity)=id;
  needle:='return '||impl||'($1,$2);';
  if impl is null or strpos(ddl,needle)=0 then raise exception 'Reviewed Lab workbench boundary differs. Nothing changed.';end if;
  execute replace(ddl,needle,'return greenloop_private.qcie_workbench('||impl||'($1,$2));');
 end if;
 update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(id))where to_regprocedure(identity)=id;
 update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(id))where to_regprocedure(identity)=id;
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
 where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
 end loop;
end;$bench$;

create or replace function greenloop_private.qcie_save(p_job_id uuid,p_revision text,p_parts jsonb,p_services jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid();s greenloop_private.qc_saved_issuance%rowtype;r record;old_revision text;
 prior greenloop_private.qc_issuance_amendments%rowtype;catalog jsonb;item jsonb;name text;canonical text;rid uuid;
 parts jsonb:='[]';services jsonb:='[]';fingerprint text;before_work jsonb;after_work jsonb;changed boolean:=false;
begin
 perform greenloop_private.qcis_require(true);
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 if p_job_id is null or p_request_id is null or p_revision is null or length(p_revision)<>32 then
  raise exception 'Reload the saved inspection before saving changes.' using errcode='22023';
 end if;
 perform greenloop_private.qdp_validate(p_parts);
 if p_parts is null or p_services is null or jsonb_typeof(p_services) is distinct from 'array' or jsonb_array_length(p_services)>100 then
  raise exception 'Choose valid parts and services lists.' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_array_elements(p_services)x where jsonb_typeof(x)<>'string'
  or length(regexp_replace(btrim(x#>>'{}'),'\s+',' ','g'))not between 1 and 120 or x#>>'{}'~'[[:cntrl:]]')then
  raise exception 'Choose valid service names.' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_array_elements_text(p_services)x group by greenloop_private.pp_key(x)having count(*)>1)then
  raise exception 'The same service is selected twice.' using errcode='22023';
 end if;
 select *into s from greenloop_private.qc_saved_issuance where job_id=p_job_id for update;
 if s.job_id is null or s.state<>'awaiting_issuance'then
  raise exception 'This phone is no longer awaiting Issuance. Reload its current stage.' using errcode='22023';
 end if;
 perform 1 from public.jobs j join public.devices d on d.id=j.device_id where j.id=p_job_id for update of j,d;
 perform 1 from public.initial_qc_inspections where id=s.inspection_id for update;
 perform 1 from public.initial_qc_part_requirements where inspection_id=s.inspection_id for update;
 perform 1 from public.initial_qc_findings where inspection_id=s.inspection_id for update;
 select *into r from greenloop_private.qcis_rows(array[(select imei_1 from public.devices where id=s.device_id)])where job_id=p_job_id;
 if r.job_id is null or exists(select 1 from public.job_work_orders where job_id=p_job_id)
  or exists(select 1 from public.job_part_requests where job_id=p_job_id)then
  raise exception 'The workflow has already started. Reload this phone before making changes.' using errcode='22023';
 end if;
 catalog:=public.get_ranked_qc_dropdowns_v1();
 for item in select value from jsonb_array_elements(p_parts)loop
  name:=regexp_replace(btrim(item->>'part_name'),'\s+',' ','g');canonical:=null;
  select x->>'name'into canonical from jsonb_array_elements(catalog->'parts')x where greenloop_private.pp_key(x->>'name')=greenloop_private.pp_key(name)limit 1;
  if canonical is null then select x->>'name'into canonical from jsonb_array_elements(r.parts)x where greenloop_private.pp_key(x->>'name')=greenloop_private.pp_key(name)limit 1;end if;
  if canonical is null then raise exception 'Choose the part from the saved dropdown: %',name using errcode='22023';end if;
  parts:=parts||jsonb_build_array(jsonb_build_object('part_name',canonical,'quantity',(item->>'quantity')::integer));
 end loop;
 for name in select value from jsonb_array_elements_text(p_services)loop
  name:=regexp_replace(btrim(name),'\s+',' ','g');canonical:=null;
  select x->>'name'into canonical from jsonb_array_elements(catalog->'services')x where greenloop_private.pp_key(x->>'name')=greenloop_private.pp_key(name)limit 1;
  if canonical is null then select x into canonical from jsonb_array_elements_text(r.services)x where greenloop_private.pp_key(x)=greenloop_private.pp_key(name)limit 1;end if;
  if canonical is null then raise exception 'Choose the service from the saved dropdown: %',name using errcode='22023';end if;
  services:=services||jsonb_build_array(canonical);
 end loop;
 select coalesce(jsonb_agg(x order by greenloop_private.pp_key(x->>'part_name')),'[]')into parts from jsonb_array_elements(parts)x;
 select coalesce(jsonb_agg(x order by greenloop_private.pp_key(x#>>'{}')),'[]')into services from jsonb_array_elements(services)x;
 fingerprint:=md5(jsonb_build_object('job',p_job_id,'revision',p_revision,'parts',parts,'services',services)::text);
 select *into prior from greenloop_private.qc_issuance_amendments where request_id=p_request_id;
 if prior.request_id is not null then
  if prior.actor_id<>actor or prior.job_id<>p_job_id or prior.payload_hash<>fingerprint then
   raise exception 'This save request belongs to different changes.' using errcode='22023';
  end if;
  if r.revision is distinct from prior.after_revision then raise exception 'These changes were saved, then the inspection changed again. Reload the phone.' using errcode='40001';end if;
  return jsonb_build_object('saved',true,'replayed',true,'row',to_jsonb(r));
 end if;
 if p_revision is distinct from r.revision then
  raise exception 'The saved inspection changed. Reload it before saving your changes.' using errcode='40001';
 end if;
 old_revision:=r.revision;before_work:=jsonb_build_object('parts',r.parts,'services',r.services);
 perform greenloop_private.begin_capability('update_qc_issuance_requirements_v1',jsonb_build_object('p_job_id',p_job_id));
 begin
  perform public.greenloop_require_entry(array['initial_qc']::text[]);
  update public.initial_qc_part_requirements p set status='not_required'
   where p.inspection_id=s.inspection_id and p.status not in('not_required','cancelled')
   and not exists(select 1 from jsonb_array_elements(parts)x where greenloop_private.pp_key(x->>'part_name')=greenloop_private.pp_key(p.part_name));
  for item in select value from jsonb_array_elements(parts)loop
   rid:=null;select p.id into rid from public.initial_qc_part_requirements p where p.inspection_id=s.inspection_id
    and greenloop_private.pp_key(p.part_name)=greenloop_private.pp_key(item->>'part_name')order by(p.status not in('not_required','cancelled'))desc,p.identified_at,p.id limit 1;
   if rid is null then
    insert into public.initial_qc_part_requirements(job_id,device_id,inspection_id,part_name,quantity_required,identified_by)
    values(p_job_id,s.device_id,s.inspection_id,item->>'part_name',(item->>'quantity')::integer,actor);
   else
    update public.initial_qc_part_requirements set quantity_required=(item->>'quantity')::integer,status='identified'
    where id=rid and(quantity_required is distinct from(item->>'quantity')::integer or status<>'identified');
   end if;
  end loop;
  update public.initial_qc_findings f set issue_found=false where f.inspection_id=s.inspection_id and f.issue_found
   and(public.is_initial_qc_service(f.check_item)or exists(select 1 from jsonb_array_elements(r.parts)x where greenloop_private.pp_key(x->>'name')=greenloop_private.pp_key(f.check_item)))
   and not exists(select 1 from jsonb_array_elements_text(services)x where greenloop_private.pp_key(x)=greenloop_private.pp_key(f.check_item))
   and not exists(select 1 from jsonb_array_elements(parts)x where greenloop_private.pp_key(x->>'part_name')=greenloop_private.pp_key(f.check_item));
  for item in select value from jsonb_array_elements(parts)loop
   name:=item->>'part_name';rid:=null;select f.id into rid from public.initial_qc_findings f where f.inspection_id=s.inspection_id
    and greenloop_private.pp_key(f.check_item)=greenloop_private.pp_key(name)order by f.issue_found desc,f.id limit 1;
   if rid is null then
    insert into public.initial_qc_findings(inspection_id,check_item,issue_found,action_required,department,priority)
    values(s.inspection_id,name,true,'Replace or use '||name,'laboratory','normal');
   else update public.initial_qc_findings set issue_found=true where id=rid and not issue_found;end if;
  end loop;
  for name in select value from jsonb_array_elements_text(services)loop
   rid:=null;select f.id into rid from public.initial_qc_findings f where f.inspection_id=s.inspection_id
    and greenloop_private.pp_key(f.check_item)=greenloop_private.pp_key(name)order by f.issue_found desc,f.id limit 1;
   if rid is null then
    insert into public.initial_qc_findings(inspection_id,check_item,issue_found,action_required,department,priority)
    values(s.inspection_id,name,true,'Complete '||name||' service','laboratory','normal');
   else update public.initial_qc_findings set issue_found=true where id=rid and not issue_found;end if;
  end loop;
  update public.initial_qc_inspections set work_required=jsonb_array_length(parts)>0
   or exists(select 1 from public.initial_qc_findings where inspection_id=s.inspection_id and issue_found)
   where id=s.inspection_id and work_required is distinct from(jsonb_array_length(parts)>0
   or exists(select 1 from public.initial_qc_findings where inspection_id=s.inspection_id and issue_found));
  select *into r from greenloop_private.qcis_rows(array[(select imei_1 from public.devices where id=s.device_id)])where job_id=p_job_id;
  after_work:=jsonb_build_object('parts',r.parts,'services',r.services);changed:=before_work is distinct from after_work;
  insert into greenloop_private.qc_issuance_amendments(request_id,job_id,device_id,inspection_id,actor_id,payload_hash,before_revision,after_revision,before_work,after_work)
  values(p_request_id,p_job_id,s.device_id,s.inspection_id,actor,fingerprint,old_revision,r.revision,before_work,after_work);
  if changed then insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
   values(s.device_id,p_job_id,'initial_qc_requirements_updated','Issuance parts and services updated',
    jsonb_build_object('source','Lab & Glass Issuance','inspection_id',s.inspection_id,'before',before_work,'after',after_work,'transferred',false),actor);end if;
 exception when others then perform greenloop_private.end_capability();raise;end;
 perform greenloop_private.end_capability();
 return jsonb_build_object('saved',true,'changed',changed,'row',to_jsonb(r));
end;$$;
revoke all on function greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)from public,anon,authenticated;
create or replace function public.update_qc_issuance_requirements_v1(p_job_id uuid,p_revision text,p_parts jsonb,p_services jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.qcie_save(p_job_id,p_revision,p_parts,p_services,p_request_id);
end;$$;
revoke all on function public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)from public,anon,authenticated;
grant execute on function public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)to authenticated;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
values('public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)','greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)',
 md5(pg_get_functiondef('greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)'::regprocedure)),md5(pg_get_functiondef('public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)'::regprocedure)))
on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values
 ('update_qc_issuance_requirements_v1','{"page":"initial_qc","capability":"entry"}'),('get_qc_issuance_edit_version','{"read":true}')
on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.qc_issuance_edit_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_issuance_edit_installation enable row level security;
revoke all on greenloop_private.qc_issuance_edit_installation from public,anon,authenticated;
insert into greenloop_private.qc_issuance_edit_installation select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array['greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)','public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)','greenloop_private.ps_service_state(uuid)','greenloop_private.qcie_workbench(jsonb)','public.get_ranked_lab_workbench_v1(uuid,text)'])signature
on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_qc_issuance_edit_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_notification_counts_version()='20261105-qc-notification-counts-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.qc_issuance_edit_installation)
 and has_function_privilege('authenticated','public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)','EXECUTE')
 and not has_function_privilege('anon','public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)','EXECUTE')
 and not exists(select 1 from pg_class c where c.oid=any(array['greenloop_private.qc_issuance_edit_installation'::regclass,'greenloop_private.qc_issuance_amendments'::regclass])
  and(not c.relrowsecurity or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='update_qc_issuance_requirements_v1'and rule='{"page":"initial_qc","capability":"entry"}'::jsonb)
 then '20261105-qc-issuance-edit-1'end;
$$;
revoke all on function public.get_qc_issuance_edit_version()from public;grant execute on function public.get_qc_issuance_edit_version()to anon,authenticated;
do $$begin if public.get_qc_issuance_edit_version()is distinct from '20261105-qc-issuance-edit-1'then raise exception 'QC Issuance edit verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_qc_issuance_edit_version()as installed_qc_issuance_edit_version;
