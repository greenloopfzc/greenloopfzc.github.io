-- Read-only Lab overdue drill-down. No workflow or TV settings are changed.
begin;
do $$begin if public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'then raise exception 'Install verified QC Direct Ready first.';end if;end;$$;

create or replace function greenloop_private.loc_rows()
returns table(employee_key text,employee_name text,device_id uuid,job_id uuid,imei text,model text,storage_gb integer,color text,battery_health integer,supplier_code text,batch_number text,invoice_number text,department text,entered_at timestamptz,elapsed_seconds numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
 select distinct on(st.device_id)
 case when t.id is not null then t.id::text when nullif(btrim(s.assigned_technician_name),'')is not null then 'legacy:'||greenloop_private.ed_key(s.assigned_technician_name)else 'unassigned'end,
 upper(coalesce(nullif(btrim(t.full_name),''),nullif(btrim(s.assigned_technician_name),''),'Unassigned')),
 d.id,j.id,d.imei_1,d.model,d.storage_gb,d.color,d.battery_health::integer,
 coalesce(r.supplier_code,sp.supplier_code,'Not recorded')||case when r.received_quantity is not null then '-('||r.received_quantity::text||')'else ''end||case when nullif(r.supplier_name,'')is not null then ' '||r.supplier_name else ''end,
 r.batch_number,r.invoice_number,case when j.current_status in('glass_pending','glass_in_progress')then 'Glass'else 'Lab & Glass'end,
 st.entered_at,greenloop_private.tv_work_seconds(st.entered_at,now())
 from greenloop_private.lab_stays_v1(null)st
 join public.jobs j on j.id=st.job_id and j.deleted_at is null
 join public.devices d on d.id=st.device_id and d.deleted_at is null
 left join lateral(select step.*from public.job_work_orders w join public.job_work_order_steps step on step.work_order_id=w.id
  where w.job_id=j.id and step.department=case when j.current_status in('glass_pending','glass_in_progress')then 'glass'::public.work_department else 'laboratory'::public.work_department end
  and step.step_status in('pending','in_progress')order by(step.step_status='in_progress')desc,step.assigned_at desc nulls last,step.created_at desc,step.id limit 1)s on true
 left join lateral(select roster.*from public.technician_roster roster where greenloop_private.ed_matches(s.assigned_technician_roster_id,s.assigned_technician_name,roster.id,roster.full_name)order by roster.is_active desc,roster.created_at,roster.id limit 1)t on true
 left join greenloop_private.sc_receipts()r on r.batch_id=j.receiving_batch_id
 left join public.suppliers sp on sp.id=j.supplier_id
 where st.ongoing and greenloop_private.tv_work_seconds(st.entered_at,now())>172800
 order by st.device_id,st.entered_at,st.job_id;
$$;
revoke all on function greenloop_private.loc_rows()from public,anon,authenticated;

create or replace function greenloop_private.loc_report(p_employee_key text default null,p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.pf_cap('lab_glass','view');
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 or p_employee_key is not null and(length(p_employee_key)not between 1 and 200)then raise exception 'Choose a valid Lab overdue page.'using errcode='22023';end if;
 with phones as materialized(select *from greenloop_private.loc_rows()),employees as materialized(
  select employee_key,min(employee_name)employee_name,count(*)phone_count,max(elapsed_seconds)oldest_seconds from phones group by employee_key
 ),employee_page as(select *from employees order by oldest_seconds desc,employee_name,employee_key offset p_offset limit p_limit),
 selected as materialized(select *from phones where employee_key=p_employee_key),phone_page as(select *from selected order by elapsed_seconds desc,device_id offset p_offset limit p_limit)
 select jsonb_build_object('server_now',now(),'threshold_days',2,'sunday_excluded',true,'phone_count',(select count(*)from phones),'employee_count',(select count(*)from employees),
  'employee_key',p_employee_key,'employee_name',(select min(employee_name)from selected),'total',case when p_employee_key is null then(select count(*)from employees)else(select count(*)from selected)end,
  'offset',p_offset,'limit',p_limit,
  'employees',case when p_employee_key is null then coalesce((select jsonb_agg(to_jsonb(e)order by oldest_seconds desc,employee_name,employee_key)from employee_page e),'[]')else '[]'::jsonb end,
  'rows',case when p_employee_key is not null then coalesce((select jsonb_agg(to_jsonb(p)order by elapsed_seconds desc,device_id)from phone_page p),'[]')else '[]'::jsonb end)into result;
 return result;
end;$$;
revoke all on function greenloop_private.loc_report(text,integer,integer)from public,anon,authenticated;

create or replace function public.get_lab_overdue_report_v1(p_employee_key text default null,p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.loc_report(p_employee_key,p_offset,p_limit);
end;$$;
revoke all on function public.get_lab_overdue_report_v1(text,integer,integer)from public,anon,authenticated;
grant execute on function public.get_lab_overdue_report_v1(text,integer,integer)to authenticated;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
values('public.get_lab_overdue_report_v1(text,integer,integer)','greenloop_private.loc_report(text,integer,integer)',md5(pg_get_functiondef('greenloop_private.loc_report(text,integer,integer)'::regprocedure)),md5(pg_get_functiondef('public.get_lab_overdue_report_v1(text,integer,integer)'::regprocedure)))
on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_lab_overdue_report_v1','{"page":"lab_glass","capability":"view","read":true}'),('get_lab_overdue_card_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.lab_overdue_card_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_overdue_card_installation enable row level security;revoke all on greenloop_private.lab_overdue_card_installation from public,anon,authenticated;
insert into greenloop_private.lab_overdue_card_installation select id,md5(pg_get_functiondef(id::regprocedure))from unnest(array['greenloop_private.loc_rows()','greenloop_private.loc_report(text,integer,integer)','public.get_lab_overdue_report_v1(text,integer,integer)'])id on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_lab_overdue_card_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_direct_ready_version()='20261105-qc-direct-ready-1'
 and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_overdue_card_installation)
 and has_function_privilege('authenticated','public.get_lab_overdue_report_v1(text,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','public.get_lab_overdue_report_v1(text,integer,integer)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.loc_rows()','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.loc_report(text,integer,integer)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.lab_overdue_card_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261105-lab-overdue-card-1'end;
$$;
revoke all on function public.get_lab_overdue_card_version()from public;grant execute on function public.get_lab_overdue_card_version()to anon,authenticated;
do $$begin if public.get_lab_overdue_card_version()is distinct from '20261105-lab-overdue-card-1'then raise exception 'Lab overdue verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_lab_overdue_card_version()as installed_lab_overdue_card_version;
