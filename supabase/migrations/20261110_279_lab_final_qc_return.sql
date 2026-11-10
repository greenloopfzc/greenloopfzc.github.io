-- Read-only provenance for the Lab phone header. No failure reason is exposed.
do $lqr_install$
begin
 perform set_config('lock_timeout','5s',true);
 perform set_config('statement_timeout','120s',true);
 if public.get_parts_cancel_version()is distinct from '20261110-parts-cancel-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified existing Lab, page and office installations are required. Nothing installed.';end if;
 if to_regprocedure('public.get_lab_final_qc_return_version()')is not null then
  if public.get_lab_final_qc_return_version()is distinct from '20261110-lab-final-qc-return-1'then raise exception 'Existing Lab Final QC return integrity differs. Nothing installed.';end if;
 elsif to_regprocedure('public.get_lab_return_workbench_v1(uuid,text)')is not null or to_regprocedure('greenloop_private.lqr_workbench(uuid,text)')is not null or to_regclass('greenloop_private.lab_final_qc_return_installation')is not null then
  raise exception 'Unreviewed Lab Final QC return objects already exist. Nothing installed.';
 end if;

 create or replace function greenloop_private.lqr_returned(p_step_id uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $source$
 select coalesce((
  select arrival.from_code='FINAL-QC' and arrival.movement_reason='Final QC failed - returned for rework'
   and final.result='fail' and final.failure_department in('laboratory','glass')
  from public.job_work_order_steps s
  join public.job_work_orders w on w.id=s.work_order_id
  join public.jobs j on j.id=w.job_id and j.deleted_at is null
  join public.devices d on d.id=j.device_id and d.deleted_at is null
  join lateral(
   select h.movement_reason,fr.location_code from_code
   from public.device_location_history h
   join public.locations dest on dest.id=h.to_location_id
   left join public.locations fr on fr.id=h.from_location_id
   where h.device_id=d.id and h.job_id=j.id and dest.location_code in('LAB','GLASS')
    and coalesce(fr.location_code,'')not in('LAB','GLASS')
   order by h.moved_at desc,h.id desc limit 1
  )arrival on true
  join lateral(select f.result,f.failure_department from public.final_qc_inspections f
   where f.job_id=j.id order by f.attempt_number desc,f.inspected_at desc,f.id desc limit 1)final on true
  where s.id=p_step_id and s.department in('laboratory','glass')and s.step_status='in_progress'
   and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
 ),false);
 $source$;
 revoke all on function greenloop_private.lqr_returned(uuid)from public,anon,authenticated;

 create or replace function greenloop_private.lqr_workbench(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $reader$
 declare result jsonb;rows jsonb;
 begin
  perform greenloop_private.pf_cap('lab_glass','view');
  -- The native read retains search, employee, IMEI2, active-stock and name visibility rules.
  result:=public.get_ranked_lab_workbench_v1(p_employee_id,p_imei);
  select coalesce(jsonb_agg(r.value||jsonb_build_object('returned_from_final_qc',greenloop_private.lqr_returned((r.value->>'step_id')::uuid))order by r.ordinality),'[]'::jsonb)
   into rows from jsonb_array_elements(result->'rows')with ordinality r;
  return result||jsonb_build_object('rows',rows);
 end;$reader$;
 revoke all on function greenloop_private.lqr_workbench(uuid,text)from public,anon,authenticated;
 create or replace function public.get_lab_return_workbench_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $wrapper$
 begin
  -- greenloop-office-wrapper-196
  perform greenloop_private.require_office_network();
  return greenloop_private.lqr_workbench(p_employee_id,p_imei);
 end;$wrapper$;
 revoke all on function public.get_lab_return_workbench_v1(uuid,text)from public,anon,authenticated;
 grant execute on function public.get_lab_return_workbench_v1(uuid,text)to authenticated;
 insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
 values('public.get_lab_return_workbench_v1(uuid,text)','greenloop_private.lqr_workbench(uuid,text)',md5(pg_get_functiondef('greenloop_private.lqr_workbench(uuid,text)'::regprocedure)),md5(pg_get_functiondef('public.get_lab_return_workbench_v1(uuid,text)'::regprocedure)))
 on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 insert into greenloop_private.capability_rpc_rules values('get_lab_return_workbench_v1','{"page":"lab_glass","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';

 create table if not exists greenloop_private.lab_final_qc_return_installation(identity text primary key,hash text not null);
 alter table greenloop_private.lab_final_qc_return_installation enable row level security;
 revoke all on greenloop_private.lab_final_qc_return_installation from public,anon,authenticated;
 create or replace function public.get_lab_final_qc_return_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when
 (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_final_qc_return_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.lab_final_qc_return_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.lab_final_qc_return_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.lab_final_qc_return_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','public.get_lab_return_workbench_v1(uuid,text)','execute')
 and has_function_privilege('authenticated','public.get_lab_return_workbench_v1(uuid,text)','execute')
 and not has_function_privilege('authenticated','greenloop_private.lqr_returned(uuid)','execute')
 and not has_function_privilege('anon','greenloop_private.lqr_returned(uuid)','execute')
 and not has_function_privilege('authenticated','greenloop_private.lqr_workbench(uuid,text)','execute')
 and not has_function_privilege('anon','greenloop_private.lqr_workbench(uuid,text)','execute')
 and exists(select 1 from greenloop_private.office_routines where identity='public.get_lab_return_workbench_v1(uuid,text)'and implementation='greenloop_private.lqr_workbench(uuid,text)'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_lab_return_workbench_v1'and rule='{"page":"lab_glass","capability":"view","read":true}'::jsonb)
 then '20261110-lab-final-qc-return-1'end;$version$;
 revoke all on function public.get_lab_final_qc_return_version()from public;
 grant execute on function public.get_lab_final_qc_return_version()to anon,authenticated;
 insert into greenloop_private.lab_final_qc_return_installation select f,md5(pg_get_functiondef(f::regprocedure))from unnest(array['greenloop_private.lqr_returned(uuid)','greenloop_private.lqr_workbench(uuid,text)','public.get_lab_return_workbench_v1(uuid,text)','public.get_lab_final_qc_return_version()'])f on conflict(identity)do update set hash=excluded.hash;
 if public.get_lab_final_qc_return_version()is distinct from '20261110-lab-final-qc-return-1'
 or public.get_parts_cancel_version()is distinct from '20261110-parts-cancel-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Lab return label verification failed. Installation rolled back.';end if;
 notify pgrst,'reload schema';
end;$lqr_install$;
select public.get_lab_final_qc_return_version()as installed_lab_final_qc_return_version;
