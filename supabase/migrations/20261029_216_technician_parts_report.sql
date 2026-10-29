-- Pending parts by current technician. Read-only reporting, separate view/export grants.
begin;
do $$begin if public.get_work_option_usage_version()is distinct from '20261028-work-option-usage-1'then raise exception 'Verified Work Options and Auto Save update is required.';end if;if to_regprocedure('public.get_technician_parts_report_version()')is not null then if public.get_technician_parts_report_version()is distinct from '20261029-technician-parts-1'then raise exception 'Existing Technician Parts Report needs review.';end if;end if;end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='parts'and capabilities @> '[{"key":"technician_report"}]')then
  -- Freeze legacy grants before adding actions, so ordinary accounts gain no new access implicitly.
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"technician_report","label":"View Technician Parts Report","write":false},{"key":"technician_download","label":"Technician report: PDF View / Download and Excel","write":false}]'where page_key='parts';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(c.capabilities,'{parts}',(c.capabilities->'parts')||'["technician_report","technician_download"]')where c.capabilities->'parts'?'view'and exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=c.user_id and ro.role_key::text in('owner','super_admin'));
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create or replace function greenloop_private.technician_parts_pending()returns table(order_id uuid,request_id uuid,device_id uuid,imei text,model text,storage_gb integer,color text,supplier_code text,batch_number text,technician_key text,technician_name text,part_name text,quantity bigint,ordered_at timestamptz)language sql stable security definer set search_path=pg_catalog,public as $$
 select o.id,r.id,d.id,d.imei_1,d.model,d.storage_gb,coalesce(nullif(btrim(d.color),''),'Not recorded'),s.supplier_code,b.batch_number,
 coalesce(t.id::text,case when nullif(btrim(st.assigned_technician_name),'')is null then 'unassigned'else 'legacy:'||greenloop_private.ed_key(st.assigned_technician_name)end),
 coalesce(t.full_name,nullif(btrim(st.assigned_technician_name),''),'Unassigned'),r.part_name,(r.quantity_requested-r.quantity_issued)::bigint,o.submitted_at
 from greenloop_private.parts_flow_orders o join greenloop_private.parts_flow_requests m on m.order_id=o.id join public.job_part_requests r on r.id=m.request_id
 join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null join public.job_work_order_steps st on st.id=o.step_id
 left join lateral(select tr.id,tr.full_name from public.technician_roster tr where greenloop_private.ed_matches(st.assigned_technician_roster_id,st.assigned_technician_name,tr.id,tr.full_name)order by tr.is_active desc,tr.created_at,tr.id limit 1)t on true
 left join public.suppliers s on s.id=j.supplier_id left join public.receiving_batches b on b.id=j.receiving_batch_id
 where o.completed_at is null and o.cycle=greenloop_private.pf_cycle(o.job_id)and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and r.status<>'cancelled'and r.quantity_requested>r.quantity_issued;
$$;
revoke all on function greenloop_private.technician_parts_pending()from public,anon,authenticated;
create or replace function public.get_parts_technician_report_v1(p_technician text default '',p_group jsonb default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare tech text:=coalesce(p_technician,'');result jsonb;begin
 perform greenloop_private.pf_cap('parts','view');perform greenloop_private.pf_cap('parts','technician_report');
 if length(tech)>180 or(p_group is not null and(jsonb_typeof(p_group)is distinct from 'object'or not(p_group?'technician_key'and p_group?'model'and p_group?'color'and p_group?'part_name')or exists(select 1 from jsonb_object_keys(p_group)k where k not in('technician_key','model','color','part_name'))or exists(select 1 from jsonb_each(p_group)e where jsonb_typeof(e.value)<>'string'or length(e.value#>>'{}')>200)))then raise exception 'Choose a valid technician or parts line.'using errcode='22023';end if;
 with source as materialized(select *from greenloop_private.technician_parts_pending()),employees as materialized(
 select tr.id::text key,tr.full_name name from public.technician_roster tr where tr.is_active
 union select technician_key,technician_name from source
 union select 'unassigned','Unassigned'
 ),filtered as materialized(select *from source where tech=''or technician_key=tech),groups as(
 select technician_key,technician_name,model,color,part_name,sum(quantity)::bigint quantity,count(distinct device_id)::integer phones from filtered group by technician_key,technician_name,model,color,part_name
 ),details as(select *from filtered where p_group is not null and technician_key=p_group->>'technician_key'and model=p_group->>'model'and color=p_group->>'color'and part_name=p_group->>'part_name')
 select jsonb_build_object('generated_at',statement_timestamp(),'technician_key',tech,'technician_name',case when tech=''then 'All Technicians'else(select name from employees where key=tech order by name limit 1)end,
 'technicians',coalesce((select jsonb_agg(jsonb_build_object('key',e.key,'name',e.name,'phones',(select count(distinct device_id)from source where technician_key=e.key))order by lower(e.name),e.key)from employees e),'[]'),
 'rows',coalesce((select jsonb_agg(to_jsonb(g)order by lower(technician_name),lower(model),lower(part_name),lower(color),technician_key)from groups g),'[]'),
 'phones',(select count(distinct device_id)from filtered),'quantity',coalesce((select sum(quantity)from filtered),0),'lines',(select count(*)from groups),
 'details',coalesce((select jsonb_agg(jsonb_build_object('order_id',order_id,'request_id',request_id,'imei',imei,'model',model,'storage_gb',storage_gb,'color',color,'supplier_code',supplier_code,'batch_number',batch_number,'technician_name',technician_name,'part_name',part_name,'quantity',quantity,'ordered_at',ordered_at)order by imei,request_id)from details),'[]'))into result;
 if tech<>''and result->>'technician_name'is null then raise exception 'This technician is not available. Refresh the report.'using errcode='22023';end if;
 if p_group is not null and tech<>''and p_group->>'technician_key'<>tech then raise exception 'Choose a line for the selected technician.'using errcode='22023';end if;
 return result;
end;$$;
create or replace function public.export_parts_technician_report_v1(p_technician text default '')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.pf_cap('parts','view');perform greenloop_private.pf_cap('parts','technician_report');perform greenloop_private.pf_cap('parts','technician_download');return public.get_parts_technician_report_v1(p_technician,null);
end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_parts_technician_report_v1','{"all":[{"page":"parts","capability":"view"},{"page":"parts","capability":"technician_report"}],"read":true}'),
 ('export_parts_technician_report_v1','{"all":[{"page":"parts","capability":"view"},{"page":"parts","capability":"technician_report"},{"page":"parts","capability":"technician_download"}],"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_parts_technician_report_v1','export_parts_technician_report_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;

create table if not exists greenloop_private.technician_parts_installation(identity text primary key,hash text not null);
alter table greenloop_private.technician_parts_installation enable row level security;revoke all on greenloop_private.technician_parts_installation from public,anon,authenticated;
insert into greenloop_private.technician_parts_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where(p.pronamespace='public'::regnamespace and p.proname in('get_parts_technician_report_v1','export_parts_technician_report_v1'))or(p.pronamespace='greenloop_private'::regnamespace and p.proname='technician_parts_pending')or p.oid in(select to_regprocedure(r.implementation)from greenloop_private.office_routines r join pg_proc f on f.oid=to_regprocedure(r.identity)where f.proname in('get_parts_technician_report_v1','export_parts_technician_report_v1'))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_technician_parts_report_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_work_option_usage_version()='20261028-work-option-usage-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.technician_parts_installation)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='parts'and capabilities @> '[{"key":"technician_report","write":false},{"key":"technician_download","write":false}]')
 and exists(select 1 from pg_class where oid='greenloop_private.technician_parts_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.technician_parts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.technician_parts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.technician_parts_installation where identity like 'greenloop_private.%'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261029-technician-parts-1'end;$$;
revoke all on function public.get_technician_parts_report_version()from public;grant execute on function public.get_technician_parts_report_version()to anon,authenticated;
do $$begin if public.get_technician_parts_report_version()is distinct from '20261029-technician-parts-1'then raise exception 'Technician Parts Report verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_technician_parts_report_version()as installed_technician_parts_report_version;
