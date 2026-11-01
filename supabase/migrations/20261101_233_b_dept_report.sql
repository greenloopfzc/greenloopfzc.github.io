-- Read-only B-DEPT performance. All durations use recorded location movements.
begin;
do $$begin
 if public.get_employee_merge_version()is distinct from '20261031-employee-merge-1'then raise exception 'Install the verified Employee Merge update first.';end if;
 if to_regprocedure('public.get_b_dept_report_version()')is not null then if public.get_b_dept_report_version()is distinct from '20261101-b-dept-report-1'then raise exception 'Existing B-DEPT report needs review.';end if;end if;
end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='frame_department'and capabilities @> '[{"key":"download"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"download","label":"B-DEPT report: PDF View / Download and Excel","write":false}]'where page_key='frame_department';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(c.capabilities,'{frame_department}',(c.capabilities->'frame_department')||'["download"]')where c.capabilities->'frame_department'?'view'and exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=c.user_id and ro.role_key::text in('owner','super_admin'));
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create index if not exists bdr_location_job_time on public.device_location_history(job_id,moved_at,id);
create index if not exists bdr_result_job_time on public.frame_department_results(job_id,reviewed_at,id);
create or replace function greenloop_private.bdr_rows()returns table(
 job_id uuid,device_id uuid,imei text,model text,storage_gb integer,color text,supplier_code text,
 arrived_at timestamptz,last_reviewed_at timestamptz,passed_at timestamptz,status text,is_pending boolean,
 pass_attempts bigint,fail_attempts bigint,visits bigint,elapsed_seconds bigint,overdue boolean,reviewed_by text,history jsonb
)language sql stable security definer set search_path=pg_catalog,public as $$
 with candidates as materialized(
  select j.id,j.device_id,j.current_status,j.supplier_id from public.jobs j join public.devices d on d.id=j.device_id
  where j.deleted_at is null and d.deleted_at is null and(cast(j.current_status as text)in('frame_pending','frame_in_progress')or
   exists(select 1 from public.device_location_history h join public.locations l on l.id=h.to_location_id where h.job_id=j.id and l.location_code='FRAME')
   or exists(select 1 from public.frame_department_results r where r.job_id=j.id))
 ), movements as(
  select h.job_id,h.moved_at,l.location_code,
   lead(h.moved_at)over(partition by h.job_id order by h.moved_at,h.id)next_at
  from public.device_location_history h join candidates c on c.id=h.job_id left join public.locations l on l.id=h.to_location_id
 ), intervals as(
  select m.*,least(coalesce(m.next_at,now()),coalesce((select min(r.reviewed_at)from public.frame_department_results r where r.job_id=m.job_id and r.result='pass'and r.reviewed_at>=m.moved_at),now()),now())ends_at
  from movements m where m.location_code='FRAME'
 ), times as(
  select job_id,min(moved_at)arrived_at,count(*)visits,
   sum(greatest(0,extract(epoch from ends_at-moved_at)))::bigint seconds
  from intervals group by job_id
 ), results as(
  select r.job_id,max(r.reviewed_at)last_reviewed_at,max(r.reviewed_at)filter(where r.result='pass')passed_at,
   count(*)filter(where r.result='pass')passes,count(*)filter(where r.result='fail')fails,
   (array_agg(upper(coalesce(p.full_name,'System'))order by r.reviewed_at desc,r.id desc))[1]reviewed_by,
   jsonb_agg(jsonb_build_object('id',r.id,'result',r.result,'reviewed_at',r.reviewed_at,'reviewed_by',upper(coalesce(p.full_name,'System')),'notes',r.notes,'final_battery_health',r.final_battery_health)order by r.reviewed_at,r.id)history
  from public.frame_department_results r join candidates c on c.id=r.job_id left join public.user_profiles p on p.id=r.reviewed_by group by r.job_id
 )select c.id,d.id,d.imei_1,d.model,d.storage_gb,d.color,s.supplier_code,t.arrived_at,r.last_reviewed_at,r.passed_at,
  case when c.current_status in('supplier_return_requested','return_pending','returned_to_supplier')then 'Supplier Return'
   when c.current_status in('frame_pending','frame_in_progress')then 'Pending'
   when r.passed_at is not null and r.passed_at=r.last_reviewed_at then 'Passed'else 'Transferred'end,
  c.current_status in('frame_pending','frame_in_progress'),coalesce(r.passes,0),coalesce(r.fails,0),coalesce(t.visits,0),t.seconds,
  c.current_status in('frame_pending','frame_in_progress')and coalesce(t.seconds,0)>=172800,r.reviewed_by,coalesce(r.history,'[]')
 from candidates c join public.devices d on d.id=c.device_id left join public.suppliers s on s.id=c.supplier_id left join times t on t.job_id=c.id left join results r on r.job_id=c.id;
$$;
revoke all on function greenloop_private.bdr_rows()from public,anon,authenticated;
create or replace function public.get_b_dept_report_v1(p_filters jsonb default '{}',p_sort text default 'arrived_at',p_desc boolean default true,p_offset integer default 0,p_limit integer default 50,p_export boolean default false)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare f jsonb:=coalesce(p_filters,'{}');result jsonb;lo date;hi date;basis text;key text;kind text;direction text;total bigint;begin
 perform greenloop_private.pf_cap('frame_department','view');
 if p_export is null or p_desc is null or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 200 then raise exception 'Invalid report page.'using errcode='22023';end if;
 if jsonb_typeof(f)<>'object'or exists(select 1 from jsonb_each(f)e where e.key not in('from','to','date_basis','search','status','model','storage_gb','color','supplier_code','reviewed_by','overdue')or jsonb_typeof(e.value)<>'string'or length(e.value#>>'{}')>200)then raise exception 'Invalid report filters.'using errcode='22023';end if;
 f:=(select coalesce(jsonb_object_agg(k,v),'{}')from jsonb_each_text(f)e(k,v)where v<>'');
 if f<>'{}'then perform greenloop_private.pf_cap('frame_department','search');end if;
 if p_export then perform greenloop_private.pf_cap('frame_department','download');end if;
 if p_sort is null or p_sort not in('imei','model','storage_gb','color','supplier_code','arrived_at','last_reviewed_at','elapsed_seconds','status','fail_attempts','pass_attempts','reviewed_by')then raise exception 'Invalid report sorting.'using errcode='22023';end if;
 if p_sort<>'arrived_at'or not p_desc then perform greenloop_private.pf_cap('frame_department','sort');end if;
 lo:=nullif(f->>'from','')::date;hi:=nullif(f->>'to','')::date;basis:=coalesce(f->>'date_basis','arrival');
 if basis not in('arrival','result')or lo>hi or coalesce(f->>'overdue','false')not in('true','false')or f?'status'and f->>'status'not in('Pending','Passed','Supplier Return','Transferred','Has Fail')then raise exception 'Choose valid dates and report filters.'using errcode='22023';end if;
 key:=quote_ident(p_sort);direction:=case when p_desc then 'desc'else 'asc'end;
 execute format($query$
  with base as materialized(select *from greenloop_private.bdr_rows()),filtered as materialized(
   select *from base r where
    ($1 is null or((case when $3='result'then r.last_reviewed_at else r.arrived_at end)at time zone 'Asia/Dubai')::date>=$1)
    and($2 is null or((case when $3='result'then r.last_reviewed_at else r.arrived_at end)at time zone 'Asia/Dubai')::date<=$2)
    and(not($4?'search')or strpos(lower(concat_ws(' ',r.imei,r.model,r.color,r.supplier_code)),lower($4->>'search'))>0)
    and(not($4?'status')or r.status=$4->>'status'or $4->>'status'='Has Fail'and r.fail_attempts>0)
    and(not($4?'model')or r.model=$4->>'model')and(not($4?'storage_gb')or r.storage_gb::text=$4->>'storage_gb')
    and(not($4?'color')or r.color=$4->>'color')and(not($4?'supplier_code')or r.supplier_code=$4->>'supplier_code')
    and(not($4?'reviewed_by')or r.reviewed_by=$4->>'reviewed_by')and(coalesce($4->>'overdue','false')='false'or r.overdue)
  ),paged as(select *from filtered order by %s %s nulls last,job_id limit $5 offset $6)
  select jsonb_build_object('generated_at',now(),'filters',$4,'total',(select count(*)from filtered),
   'summary',(select jsonb_build_object('phones',count(*),'passed',count(*)filter(where status='Passed'),'pending',count(*)filter(where is_pending),'failed_phones',count(*)filter(where fail_attempts>0),'fail_attempts',coalesce(sum(fail_attempts),0),'overdue',count(*)filter(where overdue),'average_seconds',round(avg(elapsed_seconds)filter(where status='Passed')),'timed_passed',count(elapsed_seconds)filter(where status='Passed'))from filtered),
   'rows',coalesce((select jsonb_agg(to_jsonb(paged)order by %s %s nulls last,job_id)from paged),'[]'),
   'options',jsonb_build_object('model',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct model v from base where model is not null)x),
    'storage_gb',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct storage_gb v from base where storage_gb is not null)x),
    'color',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct color v from base where color is not null)x),
    'supplier_code',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct supplier_code v from base where supplier_code is not null)x),
    'reviewed_by',(select coalesce(jsonb_agg(v order by v),'[]')from(select distinct reviewed_by v from base where reviewed_by is not null)x)))
 $query$,key,direction,key,direction)into result using lo,hi,basis,f,case when p_export then 10001 else p_limit end,case when p_export then 0 else p_offset end;
 if p_export and(result->>'total')::bigint>10000 then raise exception 'This export exceeds 10,000 phone lines. Choose a shorter date range; no partial export was created.'using errcode='54000';end if;
 return result;
end;$$;
revoke all on function public.get_b_dept_report_v1(jsonb,text,boolean,integer,integer,boolean)from public,anon;grant execute on function public.get_b_dept_report_v1(jsonb,text,boolean,integer,integer,boolean)to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_b_dept_report_v1','{"page":"frame_department","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
-- Register the new API with the existing reviewed office-access boundary.
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_b_dept_report_v1'loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select string_agg('$'||i,','order by i)into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.b_dept_report_installation(identity text primary key,hash text not null);
alter table greenloop_private.b_dept_report_installation enable row level security;revoke all on greenloop_private.b_dept_report_installation from public,anon,authenticated;
create or replace function public.get_b_dept_report_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_employee_merge_version()='20261031-employee-merge-1'
 and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.b_dept_report_installation)
 and not has_function_privilege('anon','public.get_b_dept_report_v1(jsonb,text,boolean,integer,integer,boolean)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.bdr_rows()','EXECUTE')
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='frame_department'and capabilities @> '[{"key":"download","write":false}]')
 and exists(select 1 from pg_class where oid='greenloop_private.b_dept_report_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.b_dept_report_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261101-b-dept-report-1'end;
$$;
revoke all on function public.get_b_dept_report_version()from public;grant execute on function public.get_b_dept_report_version()to anon,authenticated;
insert into greenloop_private.b_dept_report_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.bdr_rows()'::regprocedure,'public.get_b_dept_report_v1(jsonb,text,boolean,integer,integer,boolean)'::regprocedure,'public.get_b_dept_report_version()'::regprocedure)or p.oid=(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_b_dept_report_v1(jsonb,text,boolean,integer,integer,boolean)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_b_dept_report_version()is distinct from '20261101-b-dept-report-1'then raise exception 'B-DEPT report integrity verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_b_dept_report_version()as installed_b_dept_report_version;
