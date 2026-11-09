-- Read-only IMEI activity presentation. No operational or historical rows change.
begin;
do $$begin
 if to_regprocedure('public.get_imei_activity_journey_version()')is not null then if public.get_imei_activity_journey_version()is distinct from '20261109-imei-activity-1'then raise exception 'Existing IMEI activity integrity differs.';end if;end if;
 if public.get_installation_component_engine_version()is distinct from '20261107-installation-components-1'
 or public.get_installation_component_version('get_journey_status_version')->'result'->>'version' is distinct from '20261105-journey-status-1'
 then raise exception 'Verified journey support is required.';end if;
end;$$;
create or replace function greenloop_private.ia_read(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare data jsonb;d public.devices%rowtype;j public.jobs%rowtype;latest public.jobs%rowtype;b public.receiving_batches%rowtype;i public.initial_qc_inspections%rowtype;
 r jsonb;detail jsonb;details jsonb;output jsonb:='[]';code text;parts text;services text;automatic boolean;direct_transfer boolean;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('imei_search','view');
 data:=public.search_imei_journey_v1(p_imei);
 if data->>'found'is distinct from 'true'then return data;end if;
 select *into d from public.devices where imei_1=data->'device'->>'imei_1'and deleted_at is null;
 if d.id is null then return data;end if;
 select *into latest from public.jobs where device_id=d.id and deleted_at is null order by received_at desc nulls last,created_at desc,id limit 1;
 data:=jsonb_set(data,'{device}',(data->'device')||jsonb_build_object('initial_battery_health',d.battery_health,'supplier_grade',latest.supplier_grade,'gl_grade',d.gc_grade,'grade_source','Current saved grades'));
 for r in select value from jsonb_array_elements(coalesce(data->'rows','[]'))loop
  j:=null;b:=null;i:=null;automatic:=false;direct_transfer:=false;
  select *into j from public.jobs where device_id=d.id and deleted_at is null and job_number=r->>'job_number';
  if r->>'id'like 'receipt:%'then
   select rb.*into b from public.receiving_batches rb where rb.id::text=split_part(r->>'id',':',2)and exists(select 1 from public.jobs where device_id=d.id and receiving_batch_id=rb.id and deleted_at is null);
  elsif j.id is not null then select *into b from public.receiving_batches where id=j.receiving_batch_id;end if;
  details:='[]';
  for detail in select value from jsonb_array_elements(coalesce(r->'details','[]'))loop
   if lower(detail->>'label')='supplier code'and b.id is not null and b.planned_quantity is not null then
    select supplier_code into code from public.suppliers where id=b.supplier_id;
    if code is not null then detail:=jsonb_set(detail,'{value}',to_jsonb(regexp_replace(code,'-\([0-9]+\)$','')||'-('||b.planned_quantity::text||')'));end if;
   end if;
   details:=details||jsonb_build_array(detail);
  end loop;
  if r->>'id'like 'initial-qc:%'then
   select *into i from public.initial_qc_inspections where device_id=d.id and id::text=split_part(r->>'id',':',2);
   if i.id is not null then
    select string_agg(part_name||' × '||quantity_required::text,'; 'order by identified_at,id)into parts from public.initial_qc_part_requirements where inspection_id=i.id;
    select string_agg(check_item,'; 'order by created_at,id)into services from public.initial_qc_findings where inspection_id=i.id and issue_found and public.is_initial_qc_service(check_item);
    details:=details||jsonb_build_array(jsonb_build_object('label','Saved parts requirements','value',coalesce(parts,'No parts requirements recorded')),jsonb_build_object('label','Saved service requirements','value',coalesce(services,'No service requirements recorded')));
    if i.job_id=latest.id and i.id=(select id from public.initial_qc_inspections where job_id=latest.id order by inspected_at desc,id limit 1)then
     details:=details||jsonb_build_array(jsonb_build_object('label','Supplier grade (current saved)','value',latest.supplier_grade),jsonb_build_object('label','GL grade (current saved)','value',d.gc_grade),jsonb_build_object('label','Grade source','value','Current saved grades; not an inspection-time snapshot.'));
    end if;
   end if;
  end if;
  if r->>'id'like 'event:%'then
   select e.event_type='initial_qc_direct_to_frame'into direct_transfer from public.device_events e where e.device_id=d.id and e.id::text=split_part(r->>'id',':',2);
  end if;
  if r->>'id'like 'final-qc:%'then
   select f.routed_to_frame and position('Initial QC direct route to Frame'in coalesce(f.notes,''))>0 into automatic from public.final_qc_inspections f where f.device_id=d.id and f.id::text=split_part(r->>'id',':',2);
  elsif j.id is not null and r->>'stage'in('movement','event','workflow','final_qc')then
   automatic:=exists(select 1 from public.device_events e where e.device_id=d.id and e.job_id=j.id and e.event_type='initial_qc_direct_to_frame'and e.created_at=(r->>'occurred_at')::timestamptz)
    and((r->>'id'like 'movement:%'and exists(select 1 from public.device_location_history m where m.device_id=d.id and m.id::text=split_part(r->>'id',':',2)and m.movement_reason in('Initial QC completed - no repair required','Initial QC completed – no repair required','Final QC routed to Frame for required work')))
    or(r->>'id'like 'event:%'and exists(select 1 from public.device_events e where e.device_id=d.id and e.id::text=split_part(r->>'id',':',2)and e.event_type='final_qc_routed_to_frame')));
  end if;
  r:=jsonb_set(r,'{details}',details)||jsonb_build_object('automatic_direct_bdept',coalesce(automatic,false),'direct_bdept_transfer',coalesce(direct_transfer,false));
  output:=output||jsonb_build_array(r);
 end loop;
 return jsonb_set(data,'{rows}',output)||jsonb_build_object('activity_presentation_version','20261109-imei-activity-1');
end;$$;
revoke all on function greenloop_private.ia_read(text)from public,anon,authenticated;
create or replace function public.get_imei_activity_journey_v1(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.ia_read(p_imei);end;$$;
revoke all on function public.get_imei_activity_journey_v1(text)from public,anon,authenticated;
grant execute on function public.get_imei_activity_journey_v1(text)to authenticated;
insert into greenloop_private.office_routines values('public.get_imei_activity_journey_v1(text)','greenloop_private.ia_read(text)',md5(pg_get_functiondef('greenloop_private.ia_read(text)'::regprocedure)),md5(pg_get_functiondef('public.get_imei_activity_journey_v1(text)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_imei_activity_journey_v1','{"page":"imei_search","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.imei_activity_installation(identity text primary key,hash text not null);
alter table greenloop_private.imei_activity_installation enable row level security;
revoke all on greenloop_private.imei_activity_installation from public,anon,authenticated;
create or replace function public.get_imei_activity_journey_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_activity_installation)
 and has_function_privilege('authenticated','public.get_imei_activity_journey_v1(text)','EXECUTE')and not has_function_privilege('anon','public.get_imei_activity_journey_v1(text)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.ia_read(text)','EXECUTE')and not has_function_privilege('anon','greenloop_private.ia_read(text)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.imei_activity_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.imei_activity_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.imei_activity_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_imei_activity_journey_v1'and rule='{"page":"imei_search","capability":"view","read":true}'::jsonb)
 then '20261109-imei-activity-1'end;
$$;
revoke all on function public.get_imei_activity_journey_version()from public;grant execute on function public.get_imei_activity_journey_version()to anon,authenticated;
insert into greenloop_private.imei_activity_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.ia_read(text)','public.get_imei_activity_journey_v1(text)','public.get_imei_activity_journey_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_imei_activity_journey_version()is distinct from '20261109-imei-activity-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'IMEI activity installation failed verification. No changes installed.';end if;
end;$$;
notify pgrst,'reload schema';commit;
select public.get_imei_activity_journey_version()as installed_imei_activity_journey_version;
