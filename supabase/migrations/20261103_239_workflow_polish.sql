begin;
do $$begin
 if public.get_qc_choice_defaults_version()is distinct from '20261103-qc-choice-defaults-1'then raise exception 'Install verified QC Choices first.';end if;
 if to_regprocedure('public.get_workflow_polish_version()')is not null then if public.get_workflow_polish_version()is distinct from '20261103-workflow-polish-1'then raise exception 'Existing workflow update needs review.';end if;end if;
end;$$;
-- Capture the incoming QC service list once. Existing Lab saves always win.
create or replace function greenloop_private.wp_seed_services(p_job uuid)returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare st uuid;cy integer;names jsonb;inserted integer;begin
 perform pg_advisory_xact_lock(19920261026);
 select s.id into st from public.job_work_orders w join public.job_work_order_steps s on s.work_order_id=w.id join public.jobs j on j.id=w.job_id and j.deleted_at is null where w.job_id=p_job and s.department in('laboratory','glass')and s.step_status='in_progress'and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')order by w.created_at desc,s.step_order,s.id limit 1;
 if st is null then return;end if;cy:=greenloop_private.pf_cycle(p_job);
 if exists(select 1 from greenloop_private.lab_only_services where job_id=p_job and cycle=cy)then return;end if;
 select coalesce(jsonb_agg(x->>'name'),'[]')into names from jsonb_array_elements(greenloop_private.ps_service_state(st)->'services')x;
 insert into greenloop_private.lab_only_services(job_id,cycle,step_id,revision,names,saved_by)values(p_job,cy,st,1,names,auth.uid())on conflict(job_id,cycle)do nothing;
 get diagnostics inserted=row_count;
 if inserted>0 then
 insert into greenloop_private.lab_only_services_audit(job_id,cycle,action,actor,previous_names,names)values(p_job,cy,'initial_qc_services_saved',auth.uid(),'[]',names);
 end if;
end;$$;
revoke all on function greenloop_private.wp_seed_services(uuid)from public,anon,authenticated;
do $patch$declare impl regprocedure;ddl text;t record;needle text:='  perform greenloop_private.qdp_publish(p_job_id,v_result.inspection_id);';begin
 select to_regprocedure(implementation)into impl from greenloop_private.capability_routines where to_regprocedure(identity)='public.complete_initial_qc_lab_first(uuid,text,text,text,jsonb,jsonb,uuid,text,text)'::regprocedure;
 if impl is null then raise exception 'Reviewed Initial QC implementation is missing.';end if;ddl:=pg_get_functiondef(impl);
 if strpos(ddl,'greenloop_private.wp_seed_services')=0 then
  if strpos(ddl,needle)=0 then raise exception 'Initial QC service boundary differs. Nothing was changed.';end if;
  execute replace(ddl,needle,needle||E'\n  perform greenloop_private.wp_seed_services(p_job_id);');
 end if;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
 for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='greenloop_private'and c.relkind='r'and c.relname like '%installation'and exists(select 1 from pg_attribute where attrelid=c.oid and attname='identity')and exists(select 1 from pg_attribute where attrelid=c.oid and attname='hash')loop
  execute format('update greenloop_private.%I set hash=md5(pg_get_functiondef($1))where to_regprocedure(identity)=$1',t.relname)using impl;
 end loop;
end;$patch$;
-- Pending incoming lists become saved defaults; edited and completed lists stay intact.
do $$declare j record;begin for j in select distinct w.job_id from public.job_work_orders w join public.job_work_order_steps s on s.work_order_id=w.id join public.jobs job on job.id=w.job_id and job.deleted_at is null where s.department in('laboratory','glass')and s.step_status='in_progress'and job.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')loop perform greenloop_private.wp_seed_services(j.job_id);end loop;end;$$;
create or replace function public.remove_draft_box_imei_v1(p_box_id uuid,p_revision integer,p_item_id uuid)returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare b public.export_boxes%rowtype;w greenloop_private.box_workflow%rowtype;i public.export_box_items%rowtype;loc uuid;prior uuid;r record;begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('export_boxes','scan');perform greenloop_private.begin_capability('remove_draft_box_imei_v1',jsonb_build_object('p_box_id',p_box_id,'p_revision',p_revision,'p_item_id',p_item_id));
 perform pg_advisory_xact_lock(16320261010);
 select *into b from public.export_boxes where id=p_box_id for update;
 select *into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if b.id is null or b.box_status::text<>'open'or w.state is distinct from 'draft'or w.saved_at is not null then raise exception 'Only an unsaved draft box can remove a phone.'using errcode='22023';end if;
 if p_revision is distinct from w.revision then raise exception 'Box changed. Reload before removing this phone.'using errcode='40001';end if;
 select *into i from public.export_box_items where id=p_item_id and box_id=p_box_id for update;
 if not found then raise exception 'Phone line was not found in this box.'using errcode='22023';end if;
 select id into loc from public.locations where location_code='PRODUCTION'and is_active;
 if loc is null then raise exception 'Ready Stock location is missing.';end if;
 select current_location_id into prior from public.jobs where id=i.job_id for update;perform 1 from public.devices where id=i.device_id for update;
 delete from public.export_box_items where id=i.id;
 for r in select id,serial_no,row_number()over(order by serial_no,id)::integer seq from public.export_box_items where box_id=p_box_id order by serial_no,id loop if r.serial_no<>r.seq then update public.export_box_items set serial_no=r.seq where id=r.id;end if;end loop;
 update public.jobs set current_status='production_pending',current_location_id=loc,closed_at=null where id=i.job_id;
 update public.devices set current_status='production_pending',current_location_id=loc where id=i.device_id;
 insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by)values(i.device_id,i.job_id,prior,loc,'Removed from draft box',b.box_number,auth.uid());
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)values(p_box_id,b.box_number,'draft_imei_removed',auth.uid(),jsonb_build_object('imei',i.imei,'job_id',i.job_id));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(i.device_id,i.job_id,'draft_box_imei_removed','Phone removed from draft box',jsonb_build_object('box_number',b.box_number,'next_status','production_pending'),auth.uid());perform greenloop_private.end_capability();return true;
end;$$;
revoke all on function public.remove_draft_box_imei_v1(uuid,integer,uuid)from public,anon;grant execute on function public.remove_draft_box_imei_v1(uuid,integer,uuid)to authenticated;
create or replace function public.get_workflow_supplier_receipts_v1(p_page text,p_imeis text[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare names boolean;begin
 perform greenloop_private.require_office_network();
 if p_page is null or p_page not in('initial_qc','final_qc','lab_glass','frame_department','parts','ready_stock','imei_search','reports','stock_received','imei_entry','ready_stock_journey','accounts','stock_exported','export_boxes')then raise exception 'Choose an allowed workflow page.'using errcode='42501';end if;
 perform greenloop_private.pf_cap(p_page,'view');
 if p_imeis is null or cardinality(p_imeis)>250 or exists(select 1 from unnest(p_imeis)x where x is null or x!~'^[0-9]{15}$')then raise exception 'Choose up to 250 valid IMEIs.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 return(select coalesce(jsonb_agg(to_jsonb(x)),'[]')from(select distinct on(d.imei_1)d.imei_1 imei,s.supplier_code,b.planned_quantity,case when names then s.company_name else null end supplier_name
 from public.devices d join public.jobs j on j.device_id=d.id and j.deleted_at is null left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=j.supplier_id where d.deleted_at is null and d.imei_1=any(p_imeis)order by d.imei_1,j.created_at desc,j.id)x);
end;$$;
revoke all on function public.get_workflow_supplier_receipts_v1(text,text[])from public,anon;grant execute on function public.get_workflow_supplier_receipts_v1(text,text[])to authenticated;
insert into greenloop_private.capability_rpc_rules values('remove_draft_box_imei_v1','{"page":"export_boxes","capability":"scan"}'),('get_workflow_supplier_receipts_v1','{"dynamic":"filter_source","parameter":"p_page","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';

create or replace function public.get_workflow_supplier_batches_v1(p_page text,p_batch_ids uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare names boolean;begin
 perform greenloop_private.require_office_network();
 if p_page is null or p_page not in('initial_qc','final_qc','lab_glass','frame_department','parts','ready_stock','imei_search','reports','stock_received','imei_entry','ready_stock_journey','accounts','stock_exported','export_boxes')then raise exception 'Choose an allowed workflow page.'using errcode='42501';end if;
 perform greenloop_private.pf_cap(p_page,'view');
 if p_batch_ids is null or cardinality(p_batch_ids)>250 or array_position(p_batch_ids,null)is not null then raise exception 'Choose up to 250 stock batches.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 return(select coalesce(jsonb_agg(jsonb_build_object('batch_id',b.id,'supplier_code',s.supplier_code,'planned_quantity',b.planned_quantity,'supplier_name',case when names then s.company_name end)),'[]')from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where b.id=any(p_batch_ids));
end;$$;
revoke all on function public.get_workflow_supplier_batches_v1(text,uuid[])from public,anon;grant execute on function public.get_workflow_supplier_batches_v1(text,uuid[])to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_workflow_supplier_batches_v1','{"dynamic":"filter_source","parameter":"p_page","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('remove_draft_box_imei_v1','get_workflow_supplier_receipts_v1','get_workflow_supplier_batches_v1')loop
 impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
 select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
 execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);
 insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.workflow_polish_installation(identity text primary key,hash text not null);
alter table greenloop_private.workflow_polish_installation enable row level security;revoke all on greenloop_private.workflow_polish_installation from public,anon,authenticated;
create or replace function public.get_workflow_polish_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_qc_choice_defaults_version()='20261103-qc-choice-defaults-1'
 and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.workflow_polish_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.workflow_polish_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.workflow_polish_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.workflow_polish_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.workflow_polish_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not has_function_privilege('anon','public.get_workflow_supplier_receipts_v1(text,text[])','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.wp_seed_services(uuid)','EXECUTE')and not has_function_privilege('anon','public.remove_draft_box_imei_v1(uuid,integer,uuid)','EXECUTE')
 then '20261103-workflow-polish-1'end;$$;
revoke all on function public.get_workflow_polish_version()from public;grant execute on function public.get_workflow_polish_version()to anon,authenticated;
insert into greenloop_private.workflow_polish_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.wp_seed_services(uuid)'::regprocedure,'public.remove_draft_box_imei_v1(uuid,integer,uuid)'::regprocedure,'public.get_workflow_supplier_receipts_v1(text,text[])'::regprocedure,'public.get_workflow_supplier_batches_v1(text,uuid[])'::regprocedure,'public.get_workflow_polish_version()'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.workflow_polish_installation select implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines where to_regprocedure(identity)in('public.remove_draft_box_imei_v1(uuid,integer,uuid)'::regprocedure,'public.get_workflow_supplier_receipts_v1(text,text[])'::regprocedure,'public.get_workflow_supplier_batches_v1(text,uuid[])'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_workflow_polish_version()is distinct from '20261103-workflow-polish-1'then raise exception 'Workflow polish verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_workflow_polish_version()as installed_workflow_polish_version;
