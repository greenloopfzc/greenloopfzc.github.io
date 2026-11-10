-- Additive Reports-only Final Grade correction. Installation changes no phone data.
do $bcg_install$
begin
 perform set_config('lock_timeout','5s',true);
 perform set_config('statement_timeout','120s',true);
 if public.get_bulk_imei_correction_version()is distinct from '20261106-bulk-imei-correction-1'
 or public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Bulk IMEI, Ready Stock, page and office installations are required.';end if;
 if to_regprocedure('public.get_bulk_final_grade_version()')is not null then
  if public.get_bulk_final_grade_version()is distinct from '20261110-bulk-final-grade-1'then raise exception 'Existing Bulk Final Grade integrity differs. Nothing installed.';end if;
 elsif to_regclass('greenloop_private.bulk_final_grade_installation')is not null or to_regprocedure('greenloop_private.bcg_target(uuid,uuid)')is not null then
  raise exception 'Unreviewed Bulk Final Grade objects already exist. Nothing installed.';
 end if;

 create or replace function greenloop_private.bcg_target(p_job uuid,p_device uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $target$
 with outcomes as(
 select 'final_qc'::text kind,id,final_grade,inspected_at at from public.final_qc_inspections where job_id=p_job and device_id=p_device and result='pass'
 union all select 'direct_ready',job_id,final_grade,ready_at from greenloop_private.qc_direct_ready where job_id=p_job and device_id=p_device
 ),latest as(select *from outcomes where at=(select max(at)from outcomes))
 select case when count(*)=1 then jsonb_agg(to_jsonb(latest))->0 end from latest;
 $target$;
 create or replace function greenloop_private.bcg_row(p_row jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $row$
 declare target jsonb;ready boolean;
 begin
  if p_row is null then return null;end if;
  target:=greenloop_private.bcg_target((p_row->>'job_id')::uuid,(p_row->>'device_id')::uuid);
  select current_status::text in('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')into ready from public.jobs where id=(p_row->>'job_id')::uuid and device_id=(p_row->>'device_id')::uuid and deleted_at is null;
  return p_row||jsonb_build_object('revision',md5(jsonb_build_object('native',p_row->>'revision','final',target)::text),
   'has_final_grade',coalesce(ready and target is not null and p_row->>'read_only_reason'is null,false),
   'values',(p_row->'values')||jsonb_build_object('final_grade',target->>'final_grade'));
 end;$row$;
 create or replace function greenloop_private.bcg_options()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $options$
 begin return greenloop_private.bci_options()||jsonb_build_object('final_grades',coalesce((select jsonb_agg(option_value order by option_value)from public.entry_options where option_group='grade'and is_active),'[]'));end;$options$;
 create or replace function greenloop_private.bcg_read(p_imeis text[],p_batch_id uuid,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $read$
 declare result jsonb;rows jsonb;
 begin
  result:=greenloop_private.bci_read(p_imeis,p_batch_id,p_offset);
  select coalesce(jsonb_agg(greenloop_private.bcg_row(x.value)order by x.ordinality),'[]')into rows from jsonb_array_elements(result->'rows')with ordinality x;
  return result||jsonb_build_object('rows',rows);
 end;$read$;
create or replace function greenloop_private.bcg_save(p_rows jsonb,p_reason text,p_code text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $save$
declare x jsonb;old jsonb;nowrow jsonb;patch jsonb;v jsonb;a jsonb:='[]';seen uuid[]:='{}';dev uuid;job uuid;before_j public.jobs%rowtype;newbatch public.receiving_batches%rowtype;prior greenloop_private.bulk_imei_audit%rowtype;fingerprint text;result jsonb;target jsonb;begin
 perform greenloop_private.bci_guard();if p_code is distinct from '1213'or p_request_id is null or length(btrim(coalesce(p_reason,'')))not between 5 and 2000 or jsonb_typeof(p_rows)is distinct from 'array'or jsonb_array_length(p_rows)=0 then raise exception 'Enter changed rows, a reason and valid correction code.'using errcode='22023';end if;
 fingerprint:=md5(jsonb_build_object('rows',p_rows,'reason',p_reason)::text);perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into prior from greenloop_private.bulk_imei_audit where request_id=p_request_id;
 if found then if prior.actor<>auth.uid()or prior.payload_hash<>fingerprint then raise exception 'This save request belongs to different changes.'using errcode='22023';end if;return prior.response||'{"replayed":true}';end if;
 for x in select value from jsonb_array_elements(p_rows)loop
 dev:=(x->>'device_id')::uuid;job:=(x->>'job_id')::uuid;
 if dev is null or dev=any(seen)then raise exception 'Choose each phone once.'using errcode='22023';end if;seen:=array_append(seen,dev);
 perform 1 from public.jobs where device_id=dev and deleted_at is null order by id for update;perform 1 from public.devices where id=dev and deleted_at is null for update;
 perform 1 from public.final_qc_inspections where job_id=job and device_id=dev order by id for update;
 perform 1 from greenloop_private.qc_direct_ready where job_id=job and device_id=dev for update;
 old:=greenloop_private.bcg_row(greenloop_private.bci_row(dev));
 if old is null or old->>'job_id'is distinct from job::text or old->>'revision'is distinct from x->>'revision'then raise exception 'IMEI % changed. Reload before saving. No changes were saved.',coalesce(old->>'imei',dev::text)using errcode='40001';end if;
 if old->>'read_only_reason'is not null then raise exception '%',old->>'read_only_reason'using errcode='22023';end if;
 patch:=x->'patch';if jsonb_typeof(patch)is distinct from 'object'or patch='{}'or exists(select 1 from jsonb_object_keys(patch)k where k not in('model','storage_gb','color','initial_bh','final_bh','batch_id','supplier_grade','gl_grade','final_grade','parts','services'))then raise exception 'Choose supported correction cells.'using errcode='22023';end if;
 v:=(old->'values')||patch;
 if nullif(btrim(v->>'model'),'')is null or length(v->>'model')>120 or length(coalesce(v->>'color',''))>120 or(v->>'storage_gb')is null or(v->>'storage_gb')::integer not between 1 and 16384 then raise exception 'Enter valid Model, GB and Color.'using errcode='22023';end if;
 if(patch?'initial_bh'and(patch->>'initial_bh')is not null and(patch->>'initial_bh')::integer not between 0 and 100)or(patch?'final_bh'and((patch->>'final_bh')is null or(patch->>'final_bh')::integer not between 1 and 100 or not(old->>'has_final_bh')::boolean))then raise exception 'Enter valid Battery Health; Final BH requires an existing result.'using errcode='22023';end if;
 if patch?'supplier_grade'and not greenloop_private.qc_grade_allowed('supplier_grade',patch->>'supplier_grade')or patch?'gl_grade'and not greenloop_private.qc_grade_allowed('gc_grade',patch->>'gl_grade')then raise exception 'Choose a saved Supplier or GL Grade.'using errcode='22023';end if;
 if patch?'final_grade'then
 if not coalesce((old->>'has_final_grade')::boolean,false)then raise exception 'Final Grade correction requires an unboxed phone in Ready Stock with one verified outcome.'using errcode='22023';end if;
 if jsonb_typeof(patch->'final_grade')is distinct from 'string'or not exists(select 1 from public.entry_options where option_group='grade'and is_active and option_value=patch->>'final_grade')then raise exception 'Choose a saved Final Grade.'using errcode='22023';end if;
 end if;
 perform greenloop_private.begin_capability('save_bulk_imei_correction_v1',jsonb_build_object('p_device_id',dev));perform greenloop_private.pf_context(true);
 if patch?'batch_id'and patch->'batch_id'is distinct from old->'values'->'batch_id'then
 if not(old->>'can_change_receipt')::boolean then raise exception 'This phone already has downstream work. Use Full Workflow Correction for linked receipt changes.'using errcode='22023';end if;
 select *into newbatch from public.receiving_batches where id=(patch->>'batch_id')::uuid for update;
 if newbatch.id is null or newbatch.supplier_id is null or exists(select 1 from public.suppliers where id=newbatch.supplier_id and deleted_at is not null)then raise exception 'Choose a valid saved Stock/Batch.'using errcode='22023';end if;
 if newbatch.planned_quantity is not null and newbatch.planned_quantity<=(select count(*)from public.jobs where receiving_batch_id=newbatch.id and deleted_at is null)then raise exception 'This Stock/Batch has no remaining capacity.'using errcode='22023';end if;
 update public.jobs set receiving_batch_id=newbatch.id,supplier_id=newbatch.supplier_id where id=job;
 end if;
 update public.devices set model=case when patch?'model'then btrim(v->>'model')else model end,storage_gb=case when patch?'storage_gb'then(v->>'storage_gb')::integer else storage_gb end,color=case when patch?'color'then nullif(btrim(v->>'color'),'')else color end,battery_health=case when patch?'initial_bh'then(v->>'initial_bh')::smallint else battery_health end,battery_health_unavailable=case when patch?'initial_bh'then(v->>'initial_bh')is null else battery_health_unavailable end,original_grade=case when patch?'supplier_grade'then v->>'supplier_grade'else original_grade end,gc_grade=case when patch?'gl_grade'then v->>'gl_grade'else gc_grade end where id=dev;
 if patch?'supplier_grade'then update public.jobs set supplier_grade=v->>'supplier_grade'where id=job;end if;
 if patch?'final_bh'then
 if exists(select 1 from public.final_qc_inspections where job_id=job)then update public.final_qc_inspections set final_battery_health=(v->>'final_bh')::smallint,final_battery_health_unavailable=false where id=(select id from public.final_qc_inspections where job_id=job order by inspected_at desc,created_at desc,id desc limit 1);
 else update greenloop_private.qc_direct_ready set battery_health=(v->>'final_bh')::smallint where job_id=job;end if;end if;
 if patch?'final_grade'then
 target:=greenloop_private.bcg_target(job,dev);
 if target->>'kind'='final_qc'then
 update public.final_qc_inspections f set final_grade=v->>'final_grade'where f.id=(target->>'id')::uuid and f.job_id=job and f.device_id=dev and f.result='pass';
 elsif target->>'kind'='direct_ready'then
 update greenloop_private.qc_direct_ready set final_grade=v->>'final_grade'where job_id=job and device_id=dev;
 else raise exception 'Ready Stock outcome changed. Reload before saving.'using errcode='40001';end if;
 if not found then raise exception 'Ready Stock outcome changed. Reload before saving.'using errcode='40001';end if;
 end if;
 if patch?'parts'or patch?'services'then perform greenloop_private.bci_work(job,v->'parts',v->'services');end if;
 nowrow:=greenloop_private.bcg_row(greenloop_private.bci_row(dev));a:=a||jsonb_build_array(jsonb_build_object('device_id',dev,'job_id',job,'imei',old->>'imei','before',old->'values','after',nowrow->'values'));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(dev,job,'bulk_imei_corrected','IMEI corrected in Reports table',jsonb_build_object('audit_id',p_request_id,'reason',btrim(p_reason),'before',old->'values','after',nowrow->'values'),auth.uid());
 perform greenloop_private.pf_context(false);perform greenloop_private.end_capability();
 end loop;
 update greenloop_private.qc_work_usage_cache set built_at='-infinity'where singleton=true;
 update public.workflow_notification_signal set revision=revision+1 where id=1;
 result:=jsonb_build_object('saved',true,'request_id',p_request_id,'phones',jsonb_array_length(a));
 insert into greenloop_private.bulk_imei_audit(request_id,actor,reason,payload_hash,changes,response)values(p_request_id,auth.uid(),btrim(p_reason),fingerprint,a,result);return result;
end;$save$;
 create or replace function public.get_bulk_imei_grade_options_v1()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $wrapper$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.bcg_options();end;$wrapper$;
 create or replace function public.get_bulk_imei_grade_correction_v1(p_imeis text[] default null,p_batch_id uuid default null,p_offset integer default 0)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $wrapper$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.bcg_read(p_imeis,p_batch_id,p_offset);end;$wrapper$;
 create or replace function public.save_bulk_imei_grade_correction_v1(p_rows jsonb,p_reason text,p_code text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $wrapper$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.bcg_save(p_rows,p_reason,p_code,p_request_id);end;$wrapper$;
 revoke all on function greenloop_private.bcg_target(uuid,uuid)from public,anon,authenticated;
 revoke all on function greenloop_private.bcg_row(jsonb)from public,anon,authenticated;
 revoke all on function greenloop_private.bcg_options()from public,anon,authenticated;
 revoke all on function greenloop_private.bcg_read(text[],uuid,integer)from public,anon,authenticated;
 revoke all on function greenloop_private.bcg_save(jsonb,text,text,uuid)from public,anon,authenticated;
 revoke all on function public.get_bulk_imei_grade_options_v1()from public,anon,authenticated;
 grant execute on function public.get_bulk_imei_grade_options_v1()to authenticated;
 revoke all on function public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)from public,anon,authenticated;
 grant execute on function public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)to authenticated;
 revoke all on function public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)from public,anon,authenticated;
 grant execute on function public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)to authenticated;
 insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)select a,b,md5(pg_get_functiondef(to_regprocedure(b))),md5(pg_get_functiondef(to_regprocedure(a)))from(values('public.get_bulk_imei_grade_options_v1()','greenloop_private.bcg_options()'),('public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)','greenloop_private.bcg_read(text[],uuid,integer)'),('public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)','greenloop_private.bcg_save(jsonb,text,text,uuid)'))x(a,b)on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_bulk_imei_grade_options_v1','{"page":"reports","capability":"bulk_imei_correction","read":true}'),('get_bulk_imei_grade_correction_v1','{"page":"reports","capability":"bulk_imei_correction","read":true}'),('save_bulk_imei_grade_correction_v1','{"page":"reports","capability":"bulk_imei_correction"}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
 create table if not exists greenloop_private.bulk_final_grade_installation(identity text primary key,hash text not null);
 alter table greenloop_private.bulk_final_grade_installation enable row level security;
 revoke all on greenloop_private.bulk_final_grade_installation from public,anon,authenticated;
 create or replace function public.get_bulk_final_grade_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when (select count(*)=9 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.bulk_final_grade_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.bulk_final_grade_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.bulk_final_grade_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.bulk_final_grade_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','greenloop_private.bcg_target(uuid,uuid)','execute')
 and not has_function_privilege('authenticated','greenloop_private.bcg_target(uuid,uuid)','execute')
 and not has_function_privilege('anon','greenloop_private.bcg_row(jsonb)','execute')
 and not has_function_privilege('authenticated','greenloop_private.bcg_row(jsonb)','execute')
 and not has_function_privilege('anon','greenloop_private.bcg_options()','execute')
 and not has_function_privilege('authenticated','greenloop_private.bcg_options()','execute')
 and not has_function_privilege('anon','greenloop_private.bcg_read(text[],uuid,integer)','execute')
 and not has_function_privilege('authenticated','greenloop_private.bcg_read(text[],uuid,integer)','execute')
 and not has_function_privilege('anon','greenloop_private.bcg_save(jsonb,text,text,uuid)','execute')
 and not has_function_privilege('authenticated','greenloop_private.bcg_save(jsonb,text,text,uuid)','execute')
 and not has_function_privilege('anon','public.get_bulk_imei_grade_options_v1()','execute')
 and has_function_privilege('authenticated','public.get_bulk_imei_grade_options_v1()','execute')
 and not has_function_privilege('anon','public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)','execute')
 and has_function_privilege('authenticated','public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)','execute')
 and not has_function_privilege('anon','public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)','execute')
 and has_function_privilege('authenticated','public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)','execute')
 and exists(select 1 from greenloop_private.office_routines where identity='public.get_bulk_imei_grade_options_v1()'and implementation='greenloop_private.bcg_options()'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.office_routines where identity='public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)'and implementation='greenloop_private.bcg_read(text[],uuid,integer)'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.office_routines where identity='public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)'and implementation='greenloop_private.bcg_save(jsonb,text,text,uuid)'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_bulk_imei_grade_options_v1'and rule='{"page":"reports","capability":"bulk_imei_correction","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_bulk_imei_grade_correction_v1'and rule='{"page":"reports","capability":"bulk_imei_correction","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='save_bulk_imei_grade_correction_v1'and rule='{"page":"reports","capability":"bulk_imei_correction"}'::jsonb)
 then '20261110-bulk-final-grade-1'end;$version$;
 revoke all on function public.get_bulk_final_grade_version()from public;grant execute on function public.get_bulk_final_grade_version()to anon,authenticated;
 insert into greenloop_private.bulk_final_grade_installation select f,md5(pg_get_functiondef(f::regprocedure))from unnest(array['greenloop_private.bcg_target(uuid,uuid)','greenloop_private.bcg_row(jsonb)','greenloop_private.bcg_options()','greenloop_private.bcg_read(text[],uuid,integer)','greenloop_private.bcg_save(jsonb,text,text,uuid)','public.get_bulk_imei_grade_options_v1()','public.get_bulk_imei_grade_correction_v1(text[],uuid,integer)','public.save_bulk_imei_grade_correction_v1(jsonb,text,text,uuid)','public.get_bulk_final_grade_version()'])f on conflict(identity)do update set hash=excluded.hash;
 if public.get_bulk_final_grade_version()is distinct from '20261110-bulk-final-grade-1'
 or public.get_bulk_imei_correction_version()is distinct from '20261106-bulk-imei-correction-1'
 or public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Bulk Final Grade verification failed. Installation rolled back.';end if;
 notify pgrst,'reload schema';
end;$bcg_install$;
select public.get_bulk_final_grade_version()as installed_bulk_final_grade_version;
