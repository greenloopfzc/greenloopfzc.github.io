-- Damage is a request annotation. This installer does not alter stock or issue quantities.
do $damage_install$
begin
 if public.get_parts_usage_report_version()is distinct from '20261116-parts-usage-report-1' or to_regprocedure('public.get_ranked_lab_workbench_v1(uuid,text)')is null then raise exception 'Install the verified Parts Usage and Lab workbench updates first.';end if;
 if to_regprocedure('public.get_parts_request_damage_version()')is not null then if public.get_parts_request_damage_version()is distinct from '20261117-parts-request-damage-1'then raise exception 'Existing part damage integrity differs. Nothing installed.';end if;end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Existing permission rules are not verified.';end if;
 create table if not exists greenloop_private.parts_request_damage(request_id uuid primary key,order_id uuid not null,damaged boolean not null,reason text,changed_by uuid not null,changed_at timestamptz not null default now(),source text not null check(source in('lab_glass','parts')));
 create index if not exists parts_request_damage_order_idx on greenloop_private.parts_request_damage(order_id);
 create table if not exists greenloop_private.parts_damage_commands(action_id uuid primary key,actor_id uuid not null,payload_hash text not null,result jsonb not null);
 create table if not exists greenloop_private.parts_damage_installation(identity text primary key,hash text not null);
 alter table greenloop_private.parts_request_damage enable row level security;
 alter table greenloop_private.parts_damage_commands enable row level security;
 alter table greenloop_private.parts_damage_installation enable row level security;
 revoke all on greenloop_private.parts_request_damage,greenloop_private.parts_damage_commands,greenloop_private.parts_damage_installation from public,anon,authenticated;

 create or replace function greenloop_private.pd_info(p_request uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $body$
 select jsonb_build_object('damaged',coalesce(d.damaged,false),'damage_reason',d.reason,'damage_by',u.full_name,'damage_at',d.changed_at,'damage_source',d.source)
 from(select p_request id)x left join greenloop_private.parts_request_damage d on d.request_id=x.id left join public.user_profiles u on u.id=d.changed_by;$body$;
 create or replace function greenloop_private.pd_enrich(plan jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $body$
 declare k text;rows jsonb;
 begin
  if plan is null then return null;end if;
  foreach k in array array['parts','part_history','issues']loop
   if jsonb_typeof(plan->k)='array'then
    select coalesce(jsonb_agg(r||greenloop_private.pd_info(coalesce((r->>'request_id')::uuid,(select i.part_request_id from public.part_issue_transactions i where i.id=coalesce(nullif(r->>'issue_id',''),nullif(r->>'id',''))::uuid)))order by n),'[]')into rows from jsonb_array_elements(plan->k)with ordinality a(r,n);
    plan:=jsonb_set(plan,array[k],rows);
   end if;
  end loop;
  return plan||jsonb_build_object('damage_version','20261117-parts-request-damage-1');
 end;$body$;
 create or replace function greenloop_private.pd_record(p_order uuid,p_request uuid,p_damaged boolean,p_reason text,p_source text)returns boolean language plpgsql security definer set search_path=pg_catalog,public as $body$
 declare old greenloop_private.parts_request_damage%rowtype;r public.job_part_requests%rowtype;o greenloop_private.parts_flow_orders%rowtype;notes text:=nullif(btrim(p_reason),'');details jsonb;
 begin
  select *into o from greenloop_private.parts_flow_orders where id=p_order for update;
  select req.*into r from public.job_part_requests req join greenloop_private.parts_flow_requests m on m.request_id=req.id where req.id=p_request and m.order_id=p_order for update of req;
  if r.id is null or r.job_id is distinct from o.job_id or r.device_id is distinct from o.device_id or r.status='cancelled' or r.quantity_requested<=r.quantity_issued or o.completed_at is not null then raise exception 'Only a current part request awaiting issue can be marked.'using errcode='22023';end if;
  if p_damaged is null or p_source not in('lab_glass','parts')or length(coalesce(notes,''))>1000 then raise exception 'Use a valid damage mark and optional reason up to1000 characters.'using errcode='22023';end if;
  if not p_damaged then notes:=null;end if;
  select *into old from greenloop_private.parts_request_damage where request_id=p_request;
  if coalesce(old.damaged,false)=p_damaged and old.reason is not distinct from notes then return false;end if;
  insert into greenloop_private.parts_request_damage(request_id,order_id,damaged,reason,changed_by,changed_at,source)values(p_request,p_order,p_damaged,notes,auth.uid(),now(),p_source)
   on conflict(request_id)do update set damaged=excluded.damaged,reason=excluded.reason,changed_by=excluded.changed_by,changed_at=excluded.changed_at,source=excluded.source;
  details:=jsonb_build_object('request_id',p_request,'part',r.part_name,'source',p_source,'before',jsonb_build_object('damaged',coalesce(old.damaged,false),'reason',old.reason),'after',jsonb_build_object('damaged',p_damaged,'reason',notes),'notes',notes);
  insert into greenloop_private.parts_flow_audit(order_id,action,actor,details)values(p_order,'part_damage_changed',auth.uid(),details);
  insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(o.device_id,o.job_id,'parts_request_damage_changed',case when p_damaged then 'Part request marked Damaged'else 'Part request damage mark cleared'end,details,auth.uid());
  return true;
 end;$body$;
 create or replace function greenloop_private.pd_returned(p_step_id uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $source$
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

 create or replace function public.get_lab_damage_workbench_v1(p_employee_id uuid default null,p_imei text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
 declare result jsonb;rows jsonb;
 begin
  perform greenloop_private.pf_cap('lab_glass','view');result:=public.get_ranked_lab_workbench_v1(p_employee_id,p_imei);
  select coalesce(jsonb_agg(r||jsonb_build_object('pf_plan',greenloop_private.pd_enrich(r->'pf_plan'),'returned_from_final_qc',greenloop_private.pd_returned((r->>'step_id')::uuid))order by n),'[]')into rows from jsonb_array_elements(result->'rows')with ordinality a(r,n);
  return result||jsonb_build_object('rows',rows,'damage_version','20261117-parts-request-damage-1');
 end;$body$;
 create or replace function public.get_parts_damage_order_v1(p_order_id uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $body$
 select greenloop_private.pd_enrich(public.get_parts_batch_order_v1(p_order_id));$body$;

 create or replace function public.order_lab_parts_damage_v1(p_step_id uuid,p_revision integer,p_parts jsonb,p_additional boolean,p_action_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
 declare j uuid;before_ids uuid[];o uuid;item jsonb;normalized jsonb:='[]';result jsonb;command greenloop_private.parts_damage_commands%rowtype;key_hash text;rid uuid;matches integer;changed boolean:=false;flag boolean;
 begin
  perform greenloop_private.pf_cap('lab_glass','entry');j:=greenloop_private.pf_step(p_step_id);
  if p_action_id is null or p_additional is null or p_parts is null or jsonb_typeof(p_parts)<>'array'or jsonb_array_length(p_parts)not between 1 and 100 then raise exception 'Choose valid parts before ordering.'using errcode='22023';end if;
  key_hash:=md5(jsonb_build_array('lab_order',p_step_id,p_revision,p_parts,p_additional)::text);
  select *into command from greenloop_private.parts_damage_commands where action_id=p_action_id;
  if found then if command.actor_id is distinct from auth.uid()or command.payload_hash<>key_hash then raise exception 'This action belongs to a different reviewed request.'using errcode='40001';end if;return command.result;end if;
  for item in select value from jsonb_array_elements(p_parts)loop
   if jsonb_typeof(item)<>'object'or exists(select 1 from jsonb_object_keys(item)k where k not in('name','quantity','damaged','damage_reason'))or(item?'damaged'and jsonb_typeof(item->'damaged')<>'boolean')or(item?'damage_reason'and jsonb_typeof(item->'damage_reason')not in('string','null'))or length(coalesce(item->>'damage_reason',''))>1000 then raise exception 'Use a valid damage checkbox and optional reason.'using errcode='22023';end if;
   normalized:=normalized||jsonb_build_array(jsonb_build_object('name',item->'name','quantity',item->'quantity'));
  end loop;
  select id into o from greenloop_private.parts_flow_orders where job_id=j and cycle=greenloop_private.pf_cycle(j)for update;
  select coalesce(array_agg(request_id),'{}')into before_ids from greenloop_private.parts_flow_requests where order_id=o;
  if p_additional then result:=public.add_lab_parts_v1(p_step_id,p_revision,normalized);else result:=public.submit_lab_parts_plan_v2(p_step_id,p_revision,normalized);end if;
  o:=(result->>'order_id')::uuid;if o is null then raise exception 'The saved part request could not be verified.';end if;
  for item in select value from jsonb_array_elements(p_parts)loop
   select count(*),(array_agg(r.id))[1]into matches,rid from public.job_part_requests r join greenloop_private.parts_flow_requests m on m.request_id=r.id where m.order_id=o and not(r.id=any(before_ids))and r.status<>'cancelled'and greenloop_private.pp_key(r.part_name)=greenloop_private.pp_key(item->>'name')and r.quantity_requested=(item->>'quantity')::integer;
   if matches<>1 then raise exception 'The exact new part request could not be verified.';end if;
   flag:=coalesce((item->>'damaged')::boolean,false);
   if greenloop_private.pd_record(o,rid,flag,item->>'damage_reason','lab_glass')then changed:=true;end if;
  end loop;
  if changed then update greenloop_private.parts_flow_orders set revision=revision+1 where id=o;end if;
  result:=greenloop_private.pd_enrich(greenloop_private.pp_plan(p_step_id));
  insert into greenloop_private.parts_damage_commands values(p_action_id,auth.uid(),key_hash,result);return result;
 end;$body$;

 create or replace function public.set_parts_request_damage_v1(p_order_id uuid,p_revision integer,p_request_id uuid,p_damaged boolean,p_reason text,p_action_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
 declare o greenloop_private.parts_flow_orders%rowtype;command greenloop_private.parts_damage_commands%rowtype;key_hash text;result jsonb;
 begin
  perform greenloop_private.pf_cap('parts','issue');perform pg_advisory_xact_lock(19920261026);
  if p_action_id is null or p_damaged is null or length(coalesce(p_reason,''))>1000 then raise exception 'Use a valid damage mark and optional reason up to1000 characters.'using errcode='22023';end if;
  key_hash:=md5(jsonb_build_array('parts_mark',p_order_id,p_revision,p_request_id,p_damaged,p_reason)::text);
  select *into command from greenloop_private.parts_damage_commands where action_id=p_action_id;
  if found then if command.actor_id is distinct from auth.uid()or command.payload_hash<>key_hash then raise exception 'This action belongs to a different reviewed request.'using errcode='40001';end if;return command.result;end if;
  o:=greenloop_private.pf_lock(p_order_id,p_revision);perform greenloop_private.pf_step(o.step_id);
  if greenloop_private.pf_cycle(o.job_id)<>o.cycle then raise exception 'This part request belongs to an earlier visit.'using errcode='40001';end if;
  if greenloop_private.pd_record(o.id,p_request_id,p_damaged,p_reason,'parts')then update greenloop_private.parts_flow_orders set revision=revision+1 where id=o.id;end if;
  result:=public.get_parts_damage_order_v1(o.id);
  insert into greenloop_private.parts_damage_commands values(p_action_id,auth.uid(),key_hash,result);return result;
 end;$body$;

 create or replace function greenloop_private.pd_usage_units(f jsonb,names boolean)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $body$
 select coalesce(jsonb_agg(u||jsonb_build_object('request_id',i.part_request_id,'damaged',coalesce(d.damaged,false),'damage_info',case when d.damaged then greenloop_private.pd_info(i.part_request_id)||jsonb_build_object('request_id',i.part_request_id,'part_name',u->>'part_name')end)order by n),'[]')
 from jsonb_array_elements(greenloop_private.pug_units(f,names))with ordinality a(u,n)left join public.part_issue_transactions i on 'issue:'||i.id::text=u->>'source_id'left join greenloop_private.parts_request_damage d on d.request_id=i.part_request_id;$body$;
create or replace function greenloop_private.pd_usage_read(f jsonb,p_group text,start_row integer,expected text,download boolean)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);units jsonb;groups jsonb;chosen jsonb;catalogue jsonb;totals jsonb;token text;selected_group jsonb;begin
 perform greenloop_private.pug_access(f,download);
 if start_row is null or start_row<0 or start_row%50<>0 or p_group is not null and p_group!~'^[0-9a-f]{32}$'then raise exception 'Choose a valid Parts Usage page or group.'using errcode='22023';end if;
 if (p_group is not null or start_row>0 or download)and(expected is null or expected!~'^[0-9a-f]{32}$')then raise exception 'Refresh Parts Usage before opening details or downloading.'using errcode='22023';end if;
 units:=greenloop_private.pd_usage_units(f,names);
 if jsonb_array_length(units)<>(select count(distinct u->>'source_id')from jsonb_array_elements(units)u)then raise exception 'Part history has an ambiguous original batch link. Review the stock records.'using errcode='40001';end if;
 token:=md5(jsonb_build_object('filters',f,'units',units,'names',names)::text);
 if expected is not null and expected is distinct from token then raise exception 'Parts Usage changed. Refresh before opening details or downloading.'using errcode='40001';end if;
 with p as(select u from jsonb_array_elements(units)u),g as(
  select (u->>'batch_id')::uuid batch_id,(u->>'supplier_id')::uuid supplier_id,min(u->>'supplier_code')supplier_code,min(u->>'supplier_name')supplier_name,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,min((u->>'receipt_quantity')::bigint)receipt_quantity,u->>'model'model,u->>'part_name'part_name,
   count(distinct u->>'device_id')phones,count(distinct u->>'request_id')filter(where(u->>'damaged')::boolean)damaged_requests,coalesce(jsonb_agg(distinct(u->'damage_info'))filter(where(u->>'damaged')::boolean),'[]')damage_details,sum((u->>'issued')::bigint)issued,sum((u->>'installed')::bigint)installed,sum((u->>'returned')::bigint)returned,sum((u->>'net_issued')::bigint)net_issued,sum((u->>'manual_installed')::bigint)manual_installed
  from p group by u->>'batch_id',u->>'supplier_id',u->>'model',u->>'part_name'
 )select coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('group_id',md5(jsonb_build_array(batch_id,model,part_name)::text))order by supplier_code,batch_number,model,part_name,batch_id),'[]')into groups from g;
 if p_group is not null then
  select u into selected_group from jsonb_array_elements(groups)u where u->>'group_id'=p_group;
  if selected_group is null then raise exception 'This part group no longer matches the selected report.'using errcode='40001';end if;
  with p as(select u from jsonb_array_elements(units)u where u->>'batch_id'=selected_group->>'batch_id'and u->>'model'=selected_group->>'model'and u->>'part_name'=selected_group->>'part_name'),g as(
   select (u->>'device_id')::uuid device_id,min(u->>'imei')imei,min(u->>'model')model,min((u->>'storage_gb')::integer)storage_gb,min(u->>'color')color,min(u->>'grade')grade,string_agg(distinct u->>'current_stage',', ')current_stage,string_agg(distinct u->>'technician',', 'order by u->>'technician')technician,
    min(u->>'supplier_code')supplier_code,min(u->>'supplier_name')supplier_name,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,min((u->>'receipt_quantity')::bigint)receipt_quantity,min(u->>'part_name')part_name,
    count(distinct u->>'request_id')filter(where(u->>'damaged')::boolean)damaged_requests,coalesce(jsonb_agg(distinct(u->'damage_info'))filter(where(u->>'damaged')::boolean),'[]')damage_details,sum((u->>'issued')::bigint)issued,sum((u->>'installed')::bigint)installed,sum((u->>'returned')::bigint)returned,sum((u->>'net_issued')::bigint)net_issued,sum((u->>'manual_installed')::bigint)manual_installed,min((u->>'occurred_at')::timestamptz)first_recorded,max((u->>'occurred_at')::timestamptz)last_recorded
   from p group by u->>'device_id'
  )select coalesce(jsonb_agg(to_jsonb(g)order by imei,device_id),'[]')into chosen from g;
 else chosen:=groups;end if;
 select jsonb_build_object('damaged_requests',count(distinct u->>'request_id')filter(where(u->>'damaged')::boolean),'phones',count(distinct u->>'device_id'),'issued',coalesce(sum((u->>'issued')::bigint),0),'installed',coalesce(sum((u->>'installed')::bigint),0),'returned',coalesce(sum((u->>'returned')::bigint),0),'net_issued',coalesce(sum((u->>'net_issued')::bigint),0),'manual_installed',coalesce(sum((u->>'manual_installed')::bigint),0))into totals from jsonb_array_elements(units)u;
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.planned_quantity receipt_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id))
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by batch_number,batch_id)from b),'[]'),'models',coalesce((select jsonb_agg(v order by v)from(select distinct u->>'model'v from jsonb_array_elements(units)u)x),'[]'),'parts',coalesce((select jsonb_agg(v order by v)from(select distinct u->>'part_name'v from jsonb_array_elements(units)u)x),'[]'))into catalogue;
 return jsonb_build_object('version','20261117-parts-request-damage-1','filters',f,'group_id',p_group,'selected_group',selected_group,'names_allowed',names,'snapshot',token,'totals',totals,'total',jsonb_array_length(chosen),'offset',start_row,'download',download,'rows',case when download then chosen else coalesce((select jsonb_agg(u order by n)from jsonb_array_elements(chosen)with ordinality a(u,n)where n>start_row and n<=start_row+50),'[]')end,'catalogue',catalogue,'generated_at',now());
end;$$;

 create or replace function public.get_parts_usage_report_v2(p_filters jsonb default '{}',p_group text default null,p_offset integer default 0,p_expected text default null)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $body$select greenloop_private.pd_usage_read(coalesce(p_filters,'{}'),p_group,p_offset,p_expected,false);$body$;
 create or replace function public.export_parts_usage_report_v2(p_filters jsonb,p_group text,p_expected text)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $body$select greenloop_private.pd_usage_read(coalesce(p_filters,'{}'),p_group,0,p_expected,true);$body$;
 revoke all on function greenloop_private.pd_info(uuid) from public,anon,authenticated;
 revoke all on function greenloop_private.pd_enrich(jsonb) from public,anon,authenticated;
 revoke all on function greenloop_private.pd_record(uuid,uuid,boolean,text,text) from public,anon,authenticated;
 revoke all on function greenloop_private.pd_returned(uuid) from public,anon,authenticated;
 revoke all on function public.get_lab_damage_workbench_v1(uuid,text) from public,anon,authenticated;
 grant execute on function public.get_lab_damage_workbench_v1(uuid,text) to authenticated;
 revoke all on function public.get_parts_damage_order_v1(uuid) from public,anon,authenticated;
 grant execute on function public.get_parts_damage_order_v1(uuid) to authenticated;
 revoke all on function public.order_lab_parts_damage_v1(uuid,integer,jsonb,boolean,uuid) from public,anon,authenticated;
 grant execute on function public.order_lab_parts_damage_v1(uuid,integer,jsonb,boolean,uuid) to authenticated;
 revoke all on function public.set_parts_request_damage_v1(uuid,integer,uuid,boolean,text,uuid) from public,anon,authenticated;
 grant execute on function public.set_parts_request_damage_v1(uuid,integer,uuid,boolean,text,uuid) to authenticated;
 revoke all on function greenloop_private.pd_usage_units(jsonb,boolean) from public,anon,authenticated;
 revoke all on function greenloop_private.pd_usage_read(jsonb,text,integer,text,boolean) from public,anon,authenticated;
 revoke all on function public.get_parts_usage_report_v2(jsonb,text,integer,text) from public,anon,authenticated;
 grant execute on function public.get_parts_usage_report_v2(jsonb,text,integer,text) to authenticated;
 revoke all on function public.export_parts_usage_report_v2(jsonb,text,text) from public,anon,authenticated;
 grant execute on function public.export_parts_usage_report_v2(jsonb,text,text) to authenticated;
 insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_lab_damage_workbench_v1','{"page":"lab_glass","capability":"view","read":true}'),('get_parts_damage_order_v1','{"page":"parts","capability":"view","read":true}'),('order_lab_parts_damage_v1','{"page":"lab_glass","capability":"entry"}'),('set_parts_request_damage_v1','{"page":"parts","capability":"issue"}'),('get_parts_usage_report_v2','{"page":"reports","capability":"parts_usage","read":true}'),('export_parts_usage_report_v2','{"page":"reports","capability":"parts_usage_download","read":true}'),('get_parts_request_damage_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
 create or replace function public.get_parts_request_damage_version()returns text language sql stable security definer set search_path=pg_catalog,public as $body$
 select case when public.get_parts_usage_report_version()='20261116-parts-usage-report-1'and(select count(*)=13 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_damage_installation)
 and not exists(select 1 from greenloop_private.parts_damage_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='greenloop_private'::regnamespace and(has_function_privilege('anon',p.oid,'EXECUTE')or has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and not has_function_privilege('anon','public.get_lab_damage_workbench_v1(uuid,text)','EXECUTE')and has_function_privilege('authenticated','public.get_lab_damage_workbench_v1(uuid,text)','EXECUTE')
 and not has_function_privilege('anon','public.get_parts_damage_order_v1(uuid)','EXECUTE')and has_function_privilege('authenticated','public.get_parts_damage_order_v1(uuid)','EXECUTE')
 and not has_function_privilege('anon','public.order_lab_parts_damage_v1(uuid,integer,jsonb,boolean,uuid)','EXECUTE')and has_function_privilege('authenticated','public.order_lab_parts_damage_v1(uuid,integer,jsonb,boolean,uuid)','EXECUTE')
 and not has_function_privilege('anon','public.set_parts_request_damage_v1(uuid,integer,uuid,boolean,text,uuid)','EXECUTE')and has_function_privilege('authenticated','public.set_parts_request_damage_v1(uuid,integer,uuid,boolean,text,uuid)','EXECUTE')
 and not has_function_privilege('anon','public.get_parts_usage_report_v2(jsonb,text,integer,text)','EXECUTE')and has_function_privilege('authenticated','public.get_parts_usage_report_v2(jsonb,text,integer,text)','EXECUTE')
 and not has_function_privilege('anon','public.export_parts_usage_report_v2(jsonb,text,text)','EXECUTE')and has_function_privilege('authenticated','public.export_parts_usage_report_v2(jsonb,text,text)','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.parts_request_damage'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.parts_request_damage','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.parts_request_damage','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.parts_damage_commands'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.parts_damage_commands','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.parts_damage_commands','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.parts_damage_installation'::regclass and relrowsecurity)and not has_table_privilege('anon','greenloop_private.parts_damage_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.parts_damage_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_lab_damage_workbench_v1'and rule='{"page":"lab_glass","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_parts_damage_order_v1'and rule='{"page":"parts","capability":"view","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='order_lab_parts_damage_v1'and rule='{"page":"lab_glass","capability":"entry"}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='set_parts_request_damage_v1'and rule='{"page":"parts","capability":"issue"}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_parts_usage_report_v2'and rule='{"page":"reports","capability":"parts_usage","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='export_parts_usage_report_v2'and rule='{"page":"reports","capability":"parts_usage_download","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_parts_request_damage_version'and rule='{"read":true}'::jsonb)
 and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then '20261117-parts-request-damage-1'end;$body$;
 revoke all on function public.get_parts_request_damage_version()from public;grant execute on function public.get_parts_request_damage_version()to anon,authenticated;
 insert into greenloop_private.parts_damage_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.pd_info(uuid)','greenloop_private.pd_enrich(jsonb)','greenloop_private.pd_record(uuid,uuid,boolean,text,text)','greenloop_private.pd_returned(uuid)','public.get_lab_damage_workbench_v1(uuid,text)','public.get_parts_damage_order_v1(uuid)','public.order_lab_parts_damage_v1(uuid,integer,jsonb,boolean,uuid)','public.set_parts_request_damage_v1(uuid,integer,uuid,boolean,text,uuid)','greenloop_private.pd_usage_units(jsonb,boolean)','greenloop_private.pd_usage_read(jsonb,text,integer,text,boolean)','public.get_parts_usage_report_v2(jsonb,text,integer,text)','public.export_parts_usage_report_v2(jsonb,text,text)','public.get_parts_request_damage_version()'])s on conflict(identity)do update set hash=excluded.hash;
 if public.get_parts_request_damage_version()is distinct from '20261117-parts-request-damage-1'then raise exception 'Parts damage verification failed. Nothing installed.';end if;
 notify pgrst,'reload schema';
end;$damage_install$;
select public.get_parts_request_damage_version()as installed_parts_request_damage_version;
