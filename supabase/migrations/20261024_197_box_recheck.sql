-- Returned boxes stay reserved until corrected, reprinted and resubmitted.
begin;
do $$begin if public.get_office_access_version() is distinct from '20261024-office-access-1' then raise exception 'Verified Office Access must be installed first.';end if;if to_regprocedure('public.get_box_recheck_version()') is not null then if public.get_box_recheck_version() is distinct from '20261024-box-recheck-1' then raise exception 'Existing Box Recheck could not be verified. Installation stopped.';end if;end if;end;$$;
alter table greenloop_private.box_workflow drop constraint if exists box_workflow_state_check;
alter table greenloop_private.box_workflow add constraint box_workflow_state_check check(state in ('draft','accounts','recheck','exported','legacy'));
alter table greenloop_private.box_workflow add column if not exists recheck_reason text;
alter table greenloop_private.box_workflow add column if not exists recheck_at timestamptz;
alter table greenloop_private.box_workflow add column if not exists recheck_by uuid;
alter table greenloop_private.box_workflow add column if not exists last_sent_at timestamptz;
alter table greenloop_private.box_workflow add column if not exists recheck_count integer not null default 0;
-- Keep a returned box returned when its source data is corrected through Reports.
do $$declare d text;begin
 select pg_get_functiondef('greenloop_private.box_source_changed()'::regprocedure) into d;
 if strpos(d,'state in (''draft'',''recheck'')')=0 then
  if strpos(d,'state=''draft'' then ''draft''')=0 then raise exception 'Box source trigger needs review.';end if;
  d:=replace(d,'state=''draft'' then ''draft''','state in (''draft'',''recheck'') then state');execute d;
 end if;
 select pg_get_functiondef('greenloop_private.box_item_changed()'::regprocedure) into d;
 if strpos(d,'v_state not in (''draft'',''recheck'')')=0 then
  if strpos(d,'v_state<>''draft''')=0 then raise exception 'Box item trigger needs review.';end if;
  d:=replace(d,'v_state<>''draft''','v_state not in (''draft'',''recheck'')');execute d;
 end if;
 update greenloop_private.box_workflow_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity in ('greenloop_private.box_source_changed()','greenloop_private.box_item_changed()');
end;$$;
create or replace function greenloop_private.require_box_review_cap(p_page text,p_cap text) returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if greenloop_private.damage_tv_only(auth.uid()) or not coalesce(public.has_page_capability_v1(p_page,p_cap),false) then raise exception 'This box action is not allowed for your account.' using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.lock_box_recheck(p_box uuid,p_revision integer) returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare w greenloop_private.box_workflow%rowtype;begin
 perform pg_advisory_xact_lock(16320261010);perform 1 from public.export_boxes where id=p_box for update;
 select * into w from greenloop_private.box_workflow where box_id=p_box for update;
 if not found then raise exception 'Box not found.' using errcode='22023';end if;
 if p_revision is distinct from w.revision then raise exception 'Box changed. Reload it before continuing.' using errcode='40001';end if;
 if w.state<>'recheck' then raise exception 'Only a box returned for Recheck can be corrected or resent.' using errcode='22023';end if;
end;$$;
create or replace function public.get_box_status_v1(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 50,p_sort_key text default 'saved_at',p_sort_direction text default 'desc') returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare f date;t date;s text;st text;result jsonb;begin
 perform greenloop_private.require_box_review_cap('export_boxes','view');
 if jsonb_typeof(p_filters) is distinct from 'object' or exists(select 1 from jsonb_object_keys(p_filters) k where k not in ('_from','_to','_search','state')) or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or p_sort_key is null or p_sort_key not in ('saved_at','box_number','quantity','state') or p_sort_direction is null or p_sort_direction not in ('asc','desc') then raise exception 'Select valid box filters and sorting.' using errcode='22023';end if;
 if p_filters<>'{}' then perform greenloop_private.require_box_review_cap('export_boxes','search');end if;
 if p_sort_key<>'saved_at' or p_sort_direction<>'desc' then perform greenloop_private.require_box_review_cap('export_boxes','sort');end if;
 f:=nullif(p_filters->>'_from','')::date;t:=nullif(p_filters->>'_to','')::date;s:=lower(btrim(coalesce(p_filters->>'_search','')));st:=nullif(p_filters->>'state','');
 if f>t or st is not null and st not in ('Pending Verification','Recheck','Verified','Historical') then raise exception 'Select valid dates and box status.' using errcode='22023';end if;
 with all_boxes as materialized(select b.id,b.box_number,w.revision,w.state raw_state,case w.state when 'accounts' then 'Pending Verification' when 'recheck' then 'Recheck' when 'exported' then 'Verified' else 'Historical' end state,
 coalesce(w.saved_at,b.closed_at,b.opened_at) saved_at,coalesce(w.last_sent_at,w.saved_at) last_sent_at,w.recheck_reason,w.recheck_at,w.verified_at,w.recheck_count,
 (select full_name from public.user_profiles where id=w.saved_by) saved_by_name,(select full_name from public.user_profiles where id=w.verified_by) verified_by_name,
 (select count(*)::integer from public.export_box_items where box_id=b.id) quantity
 from public.export_boxes b join greenloop_private.box_workflow w on w.box_id=b.id where w.state in ('accounts','recheck','exported','legacy')),
 q as materialized(select * from all_boxes where (f is null or (saved_at at time zone 'Asia/Dubai')::date>=f) and(t is null or(saved_at at time zone 'Asia/Dubai')::date<=t) and(s='' or strpos(lower(box_number),s)>0) and(st is null or state=st)),
 page_rows as(select * from q order by
 case when p_sort_key='saved_at' and p_sort_direction='asc' then saved_at end asc,case when p_sort_key='saved_at' and p_sort_direction='desc' then saved_at end desc,
 case when p_sort_key='box_number' and p_sort_direction='asc' then box_number end asc,case when p_sort_key='box_number' and p_sort_direction='desc' then box_number end desc,
 case when p_sort_key='quantity' and p_sort_direction='asc' then quantity end asc,case when p_sort_key='quantity' and p_sort_direction='desc' then quantity end desc,
 case when p_sort_key='state' and p_sort_direction='asc' then state end asc,case when p_sort_key='state' and p_sort_direction='desc' then state end desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from q),'rows',coalesce((select jsonb_agg(to_jsonb(p)) from page_rows p),'[]'),'facets',jsonb_build_object('state',(select coalesce(jsonb_agg(distinct state),'[]') from all_boxes))) into result;return result;
end;$$;
create or replace function public.get_box_entry_review_v1(p_box_id uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare b public.export_boxes%rowtype;w greenloop_private.box_workflow%rowtype;items jsonb;names boolean;begin
 perform greenloop_private.require_box_review_cap('export_boxes','view');
 select * into b from public.export_boxes where id=p_box_id;if not found then raise exception 'Box not found.' using errcode='22023';end if;
 select * into w from greenloop_private.box_workflow where box_id=p_box_id;
 if w.state not in ('accounts','recheck','exported','legacy') then raise exception 'This box has not been saved to Accounts.' using errcode='22023';end if;
 names:=public.get_my_partner_name_access();
 select coalesce(jsonb_agg(to_jsonb(r) order by r.serial_no),'[]') into items from (select i.id,i.serial_no,i.imei,i.model,i.storage_gb,i.color,i.final_grade,d.device_number,d.serial_number,s.supplier_code,case when names then s.company_name end supplier_name,coalesce(rb.received_at,j.received_at) received_at,rb.invoice_number from public.export_box_items i join public.devices d on d.id=i.device_id join public.jobs j on j.id=i.job_id left join public.receiving_batches rb on rb.id=j.receiving_batch_id left join public.suppliers s on s.id=j.supplier_id where i.box_id=p_box_id)r;
 return jsonb_build_object('box',jsonb_build_object('box_id',b.id,'box_number',b.box_number,'state',w.state,'revision',w.revision,'saved_at',coalesce(w.saved_at,b.closed_at,b.opened_at),'last_sent_at',coalesce(w.last_sent_at,w.saved_at),'recheck_reason',w.recheck_reason,'recheck_at',w.recheck_at,'recheck_by_name',(select full_name from public.user_profiles where id=w.recheck_by),'verified_at',w.verified_at,'verified_by_name',(select full_name from public.user_profiles where id=w.verified_by),'printed_revision',w.printed_revision,'printed_at',w.printed_at,'recheck_count',w.recheck_count),'lines',items);
end;$$;
create or replace function public.request_box_recheck_v1(p_box_id uuid,p_revision integer,p_reason text) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare w greenloop_private.box_workflow%rowtype;bnum text;begin
 perform greenloop_private.require_box_review_cap('accounts','verify');
 if length(btrim(coalesce(p_reason,''))) not between 2 and 1000 then raise exception 'Enter the reason for Recheck (2 to 1000 characters).' using errcode='22023';end if;
 perform pg_advisory_xact_lock(16320261010);select box_number into bnum from public.export_boxes where id=p_box_id for update;select * into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if p_revision is distinct from w.revision then raise exception 'Box changed. Reload before requesting Recheck.' using errcode='40001';end if;
 if w.state is distinct from 'accounts' then raise exception 'Only a box awaiting Accounts verification can be returned for Recheck.' using errcode='22023';end if;
 update greenloop_private.box_workflow set state='recheck',revision=revision+1,printed_revision=null,printed_at=null,printed_by=null,recheck_reason=btrim(p_reason),recheck_at=now(),recheck_by=auth.uid(),recheck_count=recheck_count+1,verified_at=null,verified_by=null,customer_id=null,customer_name=null,customer_code=null where box_id=p_box_id;
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) values(p_box_id,bnum,'recheck_requested',auth.uid(),jsonb_build_object('reason',btrim(p_reason),'reviewed_revision',p_revision));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)select device_id,job_id,'box_returned_for_recheck','Accounts returned box for Recheck',jsonb_build_object('box_number',bnum,'reason',btrim(p_reason),'next_status','accounts_pending'),auth.uid() from public.export_box_items where box_id=p_box_id;return true;
end;$$;
create or replace function public.add_box_recheck_imei_v1(p_box_id uuid,p_revision integer,p_imei text) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare j record;loc uuid;grade text;seq integer;bnum text;cap integer;begin
 perform greenloop_private.require_box_review_cap('export_boxes','scan');perform greenloop_private.lock_box_recheck(p_box_id,p_revision);
 if p_imei is null or p_imei!~'^[0-9]{15}$' then raise exception 'Enter a valid 15-digit IMEI.' using errcode='22023';end if;
 perform greenloop_private.reject_secondary_imei(p_imei);
 if exists(select 1 from public.export_box_items where imei=p_imei) then raise exception 'This IMEI is already in an export box.' using errcode='23505';end if;
 select capacity into cap from public.export_boxes where id=p_box_id;if(select count(*) from public.export_box_items where box_id=p_box_id)>=cap then raise exception 'This box has reached its capacity.' using errcode='22023';end if;
 select job.id job_id,job.device_id,job.current_location_id,d.model,d.storage_gb,d.color,coalesce(nullif(btrim(d.gc_grade),''),nullif(btrim(d.original_grade),'')) device_grade into j from public.jobs job join public.devices d on d.id=job.device_id where d.imei_1=p_imei and d.deleted_at is null and job.deleted_at is null and job.current_status::text in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment') order by job.received_at desc limit 1 for update of job,d;
 if not found then raise exception 'This IMEI is not available in Ready Stock.' using errcode='22023';end if;
 select coalesce(nullif(btrim(final_grade),''),j.device_grade) into grade from public.final_qc_inspections where job_id=j.job_id and result='pass' order by inspected_at desc limit 1;
 select id into loc from public.locations where location_code='BOX-ENTRY' and is_active;if loc is null then raise exception 'Box Entry location is not configured.';end if;
 select coalesce(max(serial_no),0)+1 into seq from public.export_box_items where box_id=p_box_id;select box_number into bnum from public.export_boxes where id=p_box_id;
 insert into public.export_box_items(box_id,job_id,device_id,serial_no,imei,model,storage_gb,color,final_grade,scanned_by) values(p_box_id,j.job_id,j.device_id,seq,p_imei,j.model,j.storage_gb,j.color,coalesce(grade,j.device_grade,'-'),auth.uid());
 update public.jobs set current_status='accounts_pending',current_location_id=loc,closed_at=null where id=j.job_id;update public.devices set current_status='accounts_pending',current_location_id=loc where id=j.device_id;
 insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by) values(j.device_id,j.job_id,j.current_location_id,loc,'Added to returned box',bnum,auth.uid());
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) values(p_box_id,bnum,'recheck_imei_added',auth.uid(),jsonb_build_object('imei',p_imei,'job_id',j.job_id));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(j.device_id,j.job_id,'box_recheck_imei_added','Added to returned export box',jsonb_build_object('box_number',bnum,'next_status','accounts_pending'),auth.uid());return true;
end;$$;
create or replace function public.remove_box_recheck_imei_v1(p_box_id uuid,p_revision integer,p_item_id uuid) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare i public.export_box_items%rowtype;loc uuid;prior uuid;bnum text;r record;begin
 perform greenloop_private.require_box_review_cap('export_boxes','scan');perform greenloop_private.lock_box_recheck(p_box_id,p_revision);
 select * into i from public.export_box_items where id=p_item_id and box_id=p_box_id for update;if not found then raise exception 'Phone line not found in this box.' using errcode='22023';end if;
 select id into loc from public.locations where location_code='PRODUCTION' and is_active;if loc is null then raise exception 'Ready Stock location is not configured.';end if;
 select current_location_id into prior from public.jobs where id=i.job_id for update;perform 1 from public.devices where id=i.device_id for update;select box_number into bnum from public.export_boxes where id=p_box_id;
 delete from public.export_box_items where id=i.id;
 for r in select id,serial_no,row_number() over(order by serial_no,id)::integer seq from public.export_box_items where box_id=p_box_id order by serial_no,id loop if r.serial_no<>r.seq then update public.export_box_items set serial_no=r.seq where id=r.id;end if;end loop;
 update public.jobs set current_status='production_pending',current_location_id=loc,closed_at=null where id=i.job_id;update public.devices set current_status='production_pending',current_location_id=loc where id=i.device_id;
 insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by) values(i.device_id,i.job_id,prior,loc,'Removed from returned box',bnum,auth.uid());
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) values(p_box_id,bnum,'recheck_imei_removed',auth.uid(),jsonb_build_object('imei',i.imei,'job_id',i.job_id));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(i.device_id,i.job_id,'box_recheck_imei_removed','Removed from returned export box',jsonb_build_object('box_number',bnum,'next_status','production_pending'),auth.uid());return true;
end;$$;
create or replace function public.confirm_box_recheck_print_v1(p_box_id uuid,p_revision integer) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_box_review_cap('export_boxes','print');perform greenloop_private.lock_box_recheck(p_box_id,p_revision);
 if not exists(select 1 from public.export_box_items where box_id=p_box_id) then raise exception 'Print a non-empty corrected box.' using errcode='22023';end if;
 update greenloop_private.box_workflow set printed_revision=revision,printed_at=now(),printed_by=auth.uid() where box_id=p_box_id;
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) select p_box_id,box_number,'recheck_print_confirmed',auth.uid(),jsonb_build_object('revision',p_revision) from public.export_boxes where id=p_box_id;return true;
end;$$;
create or replace function public.resend_box_to_accounts_v1(p_box_id uuid,p_revision integer) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$declare w greenloop_private.box_workflow%rowtype;begin
 perform greenloop_private.require_box_review_cap('export_boxes','save');perform greenloop_private.lock_box_recheck(p_box_id,p_revision);select * into w from greenloop_private.box_workflow where box_id=p_box_id;
 if w.printed_revision is distinct from w.revision or w.printed_at is null or not exists(select 1 from public.export_box_items where box_id=p_box_id) then raise exception 'Print the corrected box and confirm printing before sending it to Accounts.' using errcode='22023';end if;
 update greenloop_private.box_workflow set state='accounts',last_sent_at=now() where box_id=p_box_id;
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) select p_box_id,box_number,'resubmitted_to_accounts',auth.uid(),jsonb_build_object('revision',p_revision,'recheck_count',w.recheck_count) from public.export_boxes where id=p_box_id;
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)select device_id,job_id,'box_resubmitted_accounts','Corrected box sent back to Accounts',jsonb_build_object('box_number',(select box_number from public.export_boxes where id=p_box_id),'next_status','accounts_pending'),auth.uid() from public.export_box_items where box_id=p_box_id;return true;
end;$$;

insert into greenloop_private.capability_rpc_rules values('get_box_status_v1','{"page":"export_boxes","capability":"view","read":true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_box_entry_review_v1','{"page":"export_boxes","capability":"view","read":true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_box_recheck_v1','{"page":"accounts","capability":"verify"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_box_recheck_imei_v1','{"page":"export_boxes","capability":"scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('remove_box_recheck_imei_v1','{"page":"export_boxes","capability":"scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('confirm_box_recheck_print_v1','{"page":"export_boxes","capability":"print"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('resend_box_to_accounts_v1','{"page":"export_boxes","capability":"save"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r) where identity='rules';
-- Register the added APIs with the existing office boundary and its audit snapshots.
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid) ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_box_status_v1','get_box_entry_review_v1','request_box_recheck_v1','add_box_recheck_imei_v1','remove_box_recheck_imei_v1','confirm_box_recheck_print_v1','resend_box_to_accounts_v1') loop
  impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');
  impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);
  select coalesce(string_agg('$'||i,',' order by i),'') into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s) returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's' then 'stable' else 'volatile' end,body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid))) on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
 revoke all on function greenloop_private.require_box_review_cap(text,text),greenloop_private.lock_box_recheck(uuid,integer) from public,anon,authenticated;
end;$wrap$;
create table if not exists greenloop_private.box_recheck_installation(identity text primary key,hash text not null);
alter table greenloop_private.box_recheck_installation enable row level security;
revoke all on greenloop_private.box_recheck_installation from public,anon,authenticated;
insert into greenloop_private.box_recheck_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where (p.pronamespace='public'::regnamespace and p.proname in ('get_box_status_v1','get_box_entry_review_v1','request_box_recheck_v1','add_box_recheck_imei_v1','remove_box_recheck_imei_v1','confirm_box_recheck_print_v1','resend_box_to_accounts_v1')) or(p.pronamespace='greenloop_private'::regnamespace and p.proname in ('require_box_review_cap','lock_box_recheck')) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_box_recheck_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_office_access_version()='20261024-office-access-1' and public.get_box_workflow_version()='20261010-box-workflow-1'
 and (select count(*)=9 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.box_recheck_installation)
 and not has_table_privilege('authenticated','greenloop_private.box_recheck_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.box_recheck_installation where identity like 'greenloop_private.%' and (has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE') or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 and exists(select 1 from pg_constraint where conrelid='greenloop_private.box_workflow'::regclass and conname='box_workflow_state_check' and convalidated and strpos(pg_get_constraintdef(oid),'recheck')>0)
 and (select count(*)=5 from pg_attribute where attrelid='greenloop_private.box_workflow'::regclass and not attisdropped and attname in ('recheck_reason','recheck_at','recheck_by','last_sent_at','recheck_count'))
 then '20261024-box-recheck-1' end;$$;
revoke all on function public.get_box_recheck_version() from public;grant execute on function public.get_box_recheck_version() to anon,authenticated;
do $$begin if public.get_box_recheck_version() is distinct from '20261024-box-recheck-1' then raise exception 'Box Recheck installation verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_box_recheck_version() as installed_box_recheck_version;
