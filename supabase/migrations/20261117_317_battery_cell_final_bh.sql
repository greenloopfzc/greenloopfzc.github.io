-- Exact issued battery replacement sets Final BH100; Initial BH/history stay intact.
begin;
do $$begin
 if public.get_diagnostic_battery_issued_version()is distinct from '20261107-diagnostic-battery-issued-1'
 or public.get_qc_fast_work_trays_version()is distinct from '20261111-qc-fast-work-trays-1'
 then raise exception 'Install the verified Diagnostic Battery and QC fast trays prerequisites first.';end if;
 if to_regprocedure('public.get_battery_cell_final_bh_version()')is not null then if public.get_battery_cell_final_bh_version()is distinct from '20261117-battery-cell-final-bh-1'then raise exception 'Existing Battery Cell rule integrity needs review.';end if;end if;
end;$$;
create temporary table rb317_before on commit drop as select oid::regprocedure::text identity,md5(pg_get_functiondef(oid))hash from pg_proc where oid=any(array['greenloop_private.qca_battery_changed(uuid)'::regprocedure::oid,'greenloop_private.qcf_rows(text[],boolean)'::regprocedure::oid]);
create or replace function greenloop_private.qca_battery_issue_parts(p_step uuid)returns text[]language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(array_agg(distinct case greenloop_private.pp_key(r.part_name)when 'battery cell'then 'Battery Cell'else 'Diagnostic Battery'end order by case greenloop_private.pp_key(r.part_name)when 'battery cell'then 'Battery Cell'else 'Diagnostic Battery'end),'{}'::text[])
 from public.job_work_order_steps f join public.job_work_orders w on w.id=f.work_order_id
 join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
 join public.job_part_requests r on r.job_id=j.id and r.device_id=d.id and r.status<>'cancelled'
 join public.part_issue_transactions i on i.part_request_id=r.id
 where f.id=p_step and f.department='final_qc'and greenloop_private.pp_key(r.part_name)in('diagnostic battery','battery cell')
 and i.quantity_issued-i.quantity_returned-coalesce((select sum(ret.quantity)from greenloop_private.parts_flow_returns ret where ret.issue_id=i.id and ret.status='pending'),0)>0;
$$;
create or replace function greenloop_private.qca_battery_changed(p_step uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$select cardinality(greenloop_private.qca_battery_issue_parts(p_step))>0;$$;
create or replace function greenloop_private.qca_battery_defaults_v2(p_steps uuid[])returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(r||jsonb_build_object('battery_replacement_issued',r->'diagnostic_battery_installed','battery_issue_parts',to_jsonb(greenloop_private.qca_battery_issue_parts((r->>'step_id')::uuid)))order by n),'[]'::jsonb)
 from jsonb_array_elements(public.get_final_qc_battery_defaults_v1(p_steps))with ordinality x(r,n);
$$;
revoke all on function greenloop_private.qca_battery_issue_parts(uuid),greenloop_private.qca_battery_changed(uuid),greenloop_private.qca_battery_defaults_v2(uuid[])from public,anon,authenticated;
do $$declare old text;updated text;begin
 old:=pg_get_functiondef('greenloop_private.qcf_rows(text[],boolean)'::regprocedure);
 if position('greenloop_private.qca_battery_defaults_v2(step_ids)'in old)=0 then
  updated:=regexp_replace(old,'public\.get_final_qc_battery_defaults_v1\s*\(\s*step_ids\s*\)','greenloop_private.qca_battery_defaults_v2(step_ids)','g');
  if old=updated or position('greenloop_private.qca_battery_defaults_v2(step_ids)'in updated)=0 then raise exception 'Final QC snapshot boundary differs. Nothing installed.';end if;execute updated;
 end if;
end;$$;
-- Refresh only intact receipts for these exact reviewed routine identities.
do $$declare b record;t record;c record;begin
 for b in select *from rb317_before loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
 end loop;end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 end loop;
end;$$;
create table if not exists greenloop_private.battery_cell_bh_installation(identity text primary key,hash text not null);alter table greenloop_private.battery_cell_bh_installation enable row level security;revoke all on greenloop_private.battery_cell_bh_installation from public,anon,authenticated;
create or replace function public.get_battery_cell_final_bh_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_diagnostic_battery_issued_version()='20261107-diagnostic-battery-issued-1'and public.get_qc_fast_work_trays_version()='20261111-qc-fast-work-trays-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.battery_cell_bh_installation)
 and not has_function_privilege('authenticated','greenloop_private.qca_battery_issue_parts(uuid)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.qca_battery_defaults_v2(uuid[])','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.qca_battery_issue_parts(uuid)','EXECUTE')and not has_function_privilege('anon','greenloop_private.qca_battery_defaults_v2(uuid[])','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.battery_cell_bh_installation'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.battery_cell_bh_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.battery_cell_bh_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261117-battery-cell-final-bh-1'end;$$;
revoke all on function public.get_battery_cell_final_bh_version()from public;grant execute on function public.get_battery_cell_final_bh_version()to anon,authenticated;
insert into greenloop_private.battery_cell_bh_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.qca_battery_issue_parts(uuid)','greenloop_private.qca_battery_changed(uuid)','greenloop_private.qca_battery_defaults_v2(uuid[])','greenloop_private.qcf_rows(text[],boolean)','public.get_battery_cell_final_bh_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_battery_cell_final_bh_version()is distinct from '20261117-battery-cell-final-bh-1'then raise exception 'Battery Cell rule verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_battery_cell_final_bh_version()as installed_battery_cell_final_bh_version;
