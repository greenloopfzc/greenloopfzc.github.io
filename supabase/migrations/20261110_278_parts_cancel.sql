-- Parts can cancel a wholly unissued requirement. Reason is optional.
-- Installation adds endpoints only; no existing business records are changed.
do $pc_install$
begin
 perform set_config('lock_timeout','5s',true);
 perform set_config('statement_timeout','120s',true);
 if public.get_content_permissions_version() is distinct from '20261110-content-permissions-1'
 or (public.get_installation_component_version('get_parts_tabs_boundary_version')->'result'->>'version') is distinct from '20261107-parts-tabs-boundary-1'
 or (public.get_installation_component_version('get_parts_simple_version')->'result'->>'version') is distinct from '20261026-parts-simple-1'
 or public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version() is distinct from '20261024-office-access-1'
 then raise exception 'Verified existing Parts, office and page permissions are required. Nothing installed.';end if;
 if to_regprocedure('public.get_parts_cancel_version()')is not null then
  if public.get_parts_cancel_version()is distinct from '20261110-parts-cancel-1'then raise exception 'Existing Parts cancellation integrity differs. Nothing installed.';end if;
 elsif to_regprocedure('public.cancel_parts_request_v1(uuid,integer,uuid,text)')is not null or to_regprocedure('greenloop_private.pcc_cancel(uuid,integer,uuid,text)')is not null or to_regclass('greenloop_private.parts_cancel_installation')is not null then
  raise exception 'Unreviewed Parts cancellation objects already exist. Nothing installed.';
 end if;

 create or replace function pg_temp.pcc_reader()returns regprocedure language sql as $resolve$
 select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_parts_only_order_v1(uuid)'::regprocedure;$resolve$;
 -- Preserve the existing authorized read path after cancelling its final pending part.
 do $read_review$declare f record;body text;old text:='if not greenloop_private.ps_has_parts(p_order_id)then';new text:='if not greenloop_private.ps_has_parts(p_order_id)and not exists(select 1 from greenloop_private.parts_flow_audit where order_id=p_order_id and action=''unissued_part_cancelled_by_parts'')then';begin
  select p.*,l.lanname into strict f from pg_proc p join pg_language l on l.oid=p.prolang where p.oid=pg_temp.pcc_reader();
  if position('greenloop-parts-cancel-read-278'in f.prosrc)=0 then
   if md5(replace(replace(f.prosrc,chr(13)||chr(10),chr(10)),chr(13),chr(10)))<>'7cfad308eac61a245d3a4cd92fae59ca'
    or not f.prosecdef or f.provolatile<>'s' or f.lanname<>'plpgsql' or f.proconfig is distinct from array['search_path=pg_catalog, public']::text[]then raise exception 'Existing Parts detail reader needs review. Nothing installed.';end if;
   body:=replace(pg_get_functiondef(f.oid),chr(13),'');
   if (length(body)-length(replace(body,old,'')))/length(old)<>1 then raise exception 'Parts detail clause missing or ambiguous.';end if;
   body:=replace(body,old,new);
   body:=replace(body,'greenloop_private.ps_status(p_order_id)','case when greenloop_private.ps_has_parts(p_order_id)then greenloop_private.ps_status(p_order_id)else ''No Parts Pending''end');
   body:=replace(body,'begin',E'-- greenloop-parts-cancel-read-278\nbegin');execute body;
  end if;
 end;$read_review$;
 -- Reseal only this reviewed read implementation, never unrelated definitions.
 do $seal$declare t record;id regprocedure:=pg_temp.pcc_reader();begin
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))where to_regprocedure(implementation)=id;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=id or to_regprocedure(implementation)=id;
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where case when %I like ''%%(%%''then to_regprocedure(%I)else null end=$1',t.table_name,t.hash_col,t.id_col,t.id_col,t.id_col)using id;
  end loop;
 end;$seal$;

 create or replace function greenloop_private.pcc_cancel(p_order_id uuid,p_revision integer,p_request_id uuid,p_reason text default null)
 returns jsonb language plpgsql security definer set search_path=pg_catalog,public
 set lock_timeout='5s' set statement_timeout='120s' as $cancel$
 declare o greenloop_private.parts_flow_orders%rowtype;r public.job_part_requests%rowtype;reason text:=nullif(btrim(p_reason),'');
 begin
  -- Same permission as Issue Parts; neither view-only nor Lab-only can call this endpoint.
  perform greenloop_private.pf_cap('parts','issue');
  if length(coalesce(reason,''))>1000 then raise exception 'Cancellation reason must be 1000 characters or fewer.'using errcode='22023';end if;
  -- The same order/advisory lock as Issue prevents a stale Cancel from winning after an issue.
  o:=greenloop_private.pf_lock(p_order_id,p_revision);
  if o.completed_at is not null or o.cycle<>greenloop_private.pf_cycle(o.job_id)
   or not exists(select 1 from public.jobs where id=o.job_id and current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress'))
   then raise exception 'This order is no longer active in Lab & Glass.'using errcode='22023';end if;
  select q.*into r from public.job_part_requests q join greenloop_private.parts_flow_requests m on m.request_id=q.id
   where q.id=p_request_id and m.order_id=o.id and q.job_id=o.job_id and q.device_id=o.device_id for update of q;
  if r.id is null or r.status='cancelled' then raise exception 'Select a current part from this order.'using errcode='22023';end if;
  if r.quantity_issued<>0 or r.quantity_returned<>0 or r.quantity_installed<>0
   or exists(select 1 from public.part_issue_transactions where part_request_id=r.id)
   then raise exception 'This part has been issued. Use Return Part instead.'using errcode='22023';end if;
  perform greenloop_private.pf_context(true);
  update public.job_part_requests set status='cancelled',updated_at=now()where id=r.id;
  update public.initial_qc_part_requirements set status='not_required',reviewed_by=auth.uid(),reviewed_at=now()
   where job_id=o.job_id and greenloop_private.pp_key(part_name)=greenloop_private.pp_key(r.part_name)
   and status not in('manually_installed','unused_returned')
   and not exists(select 1 from public.job_part_requests q join greenloop_private.parts_flow_requests m on m.request_id=q.id
    where m.order_id=o.id and greenloop_private.pp_key(q.part_name)=greenloop_private.pp_key(r.part_name)and q.status<>'cancelled');
  update greenloop_private.parts_flow_orders set revision=revision+1 where id=o.id;
  insert into greenloop_private.parts_flow_audit(order_id,action,actor,details)
   values(o.id,'unissued_part_cancelled_by_parts',auth.uid(),jsonb_build_object('part',r.part_name,'request_id',r.id,'quantity',r.quantity_requested,'notes',reason));
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
   values(o.device_id,o.job_id,'parts_requirement_cancelled','Parts cancelled an unissued part',
    jsonb_build_object('part_name',r.part_name,'request_id',r.id,'order_id',o.id,'quantity',r.quantity_requested,'reason',reason),auth.uid());
  perform greenloop_private.pf_context(false);
  return jsonb_build_object('cancelled',true,'order_id',o.id,'request_id',r.id,'revision',o.revision+1);
 end;$cancel$;
 revoke all on function greenloop_private.pcc_cancel(uuid,integer,uuid,text)from public,anon,authenticated;
 create or replace function public.cancel_parts_request_v1(p_order_id uuid,p_revision integer,p_request_id uuid,p_reason text default null)
 returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $wrapper$
 begin
  -- greenloop-office-wrapper-196
  perform greenloop_private.require_office_network();
  return greenloop_private.pcc_cancel(p_order_id,p_revision,p_request_id,p_reason);
 end;$wrapper$;
 revoke all on function public.cancel_parts_request_v1(uuid,integer,uuid,text)from public,anon;
 insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
 values('public.cancel_parts_request_v1(uuid,integer,uuid,text)','greenloop_private.pcc_cancel(uuid,integer,uuid,text)',
 md5(pg_get_functiondef('greenloop_private.pcc_cancel(uuid,integer,uuid,text)'::regprocedure)),md5(pg_get_functiondef('public.cancel_parts_request_v1(uuid,integer,uuid,text)'::regprocedure)))
 on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 grant execute on function public.cancel_parts_request_v1(uuid,integer,uuid,text)to authenticated;

 create table if not exists greenloop_private.parts_cancel_installation(identity text primary key,hash text not null);
 alter table greenloop_private.parts_cancel_installation enable row level security;
 revoke all on greenloop_private.parts_cancel_installation from public,anon,authenticated;
 create or replace function public.get_parts_cancel_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when
 (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_cancel_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.parts_cancel_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.parts_cancel_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.parts_cancel_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','public.cancel_parts_request_v1(uuid,integer,uuid,text)','execute')
 and has_function_privilege('authenticated','public.cancel_parts_request_v1(uuid,integer,uuid,text)','execute')
 and not has_function_privilege('anon','greenloop_private.pcc_cancel(uuid,integer,uuid,text)','execute')
 and not has_function_privilege('authenticated','greenloop_private.pcc_cancel(uuid,integer,uuid,text)','execute')
 and exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)='public.cancel_parts_request_v1(uuid,integer,uuid,text)'::regprocedure
 and implementation='greenloop_private.pcc_cancel(uuid,integer,uuid,text)'and original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))
 then '20261110-parts-cancel-1'end;$version$;
 revoke all on function public.get_parts_cancel_version()from public;grant execute on function public.get_parts_cancel_version()to anon,authenticated;
 insert into greenloop_private.parts_cancel_installation select f,md5(pg_get_functiondef(f::regprocedure))from unnest(array[
  'public.cancel_parts_request_v1(uuid,integer,uuid,text)','greenloop_private.pcc_cancel(uuid,integer,uuid,text)','public.get_parts_cancel_version()',pg_temp.pcc_reader()::text])f on conflict(identity)do update set hash=excluded.hash;
 if public.get_parts_cancel_version()is distinct from '20261110-parts-cancel-1'
 or public.get_content_permissions_version()is distinct from '20261110-content-permissions-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Parts cancellation verification failed. Installation rolled back.';end if;
 notify pgrst,'reload schema';
end;$pc_install$;
select public.get_parts_cancel_version()as installed_parts_cancel_version;
