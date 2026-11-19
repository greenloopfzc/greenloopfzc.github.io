-- One fresh Parts Ordered membership for badge, sidebar and paged tabs.
-- No stock, requests, issues, returns, custody or work history is repaired here.
do $install$
declare api text;api_oid oid;target_oid oid;office_oid oid;n integer;sig text;old text;updated text;t record;c record;b record;reviewed jsonb:='[]';sealed text[]:=array['greenloop_private.pqm_orders()','public.get_parts_queue_membership_version()'];
begin
perform set_config('search_path','pg_catalog,public',true);
if to_regprocedure('public.get_parts_queue_membership_version()')is not null then if public.get_parts_queue_membership_version()is distinct from '20261119-parts-queue-membership-1'then raise exception 'Existing Parts queue integrity differs. Nothing installed.';end if;return;end if;
if public.get_stage_change_parts_version()is distinct from '20261119-stage-change-parts-1'or public.get_parts_tabs_boundary_version()is distinct from '20261107-parts-tabs-boundary-1'or public.get_background_read_speed_version()is distinct from '20261118-background-read-speed-1'then raise exception 'Install the verified Parts and stage-correction prerequisites first.';end if;
create or replace function greenloop_private.pqm_orders()returns table(order_id uuid,device_id uuid,job_id uuid,needs_issue boolean)language sql stable security definer set search_path=pg_catalog,public as $f$
with candidates as materialized(
 select o.*
 from greenloop_private.parts_flow_orders o join public.jobs j on j.id=o.job_id and j.device_id=o.device_id and j.deleted_at is null
 join public.devices d on d.id=j.device_id and d.deleted_at is null
 join public.job_work_orders w on w.job_id=j.id and w.status<>'cancelled'
 join public.job_work_order_steps s on s.id=o.step_id and s.work_order_id=w.id
 where o.completed_at is null and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and greenloop_private.company_job_available(j.id)
 and j.id=(select x.id from public.jobs x where x.device_id=d.id and x.deleted_at is null order by x.received_at desc nulls last,x.created_at desc,x.id desc limit 1)
),cycles as materialized(select device_id,job_id,count(*)::integer cycle from greenloop_private.bgr_stays(null)group by device_id,job_id),eligible as(
 select o.*from candidates o left join cycles cy on cy.device_id=o.device_id and cy.job_id=o.job_id
 where greenloop_private.ps_has_parts(o.id)and o.cycle=coalesce(cy.cycle,0)
),latest as(select distinct on(device_id)*from eligible order by device_id,submitted_at desc,id desc)
select o.id,o.device_id,o.job_id,exists(select 1 from greenloop_private.parts_flow_requests m join public.job_part_requests r on r.id=m.request_id where m.order_id=o.id and r.status<>'cancelled'and r.quantity_requested>r.quantity_issued)from latest o;$f$;
revoke all on function greenloop_private.pqm_orders()from public,anon,authenticated;

-- Resolve the actual registered Parts tabs reader, never an OID-derived name.
api:='public.get_parts_order_tabs_v1(text,jsonb,integer,integer,text,text)';api_oid:=to_regprocedure(api);
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if n<>1 or target_oid is null then raise exception 'Missing or ambiguous Parts tabs Office implementation.';end if;
if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Parts tabs Office integrity differs.';end if;
if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Parts tabs implementation.';end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)or position('greenloop_private.pf_cap(''parts'',''view'')'in regexp_replace(old,'\s','','g'))=0 or position('filteredasmaterialized'in regexp_replace(old,'\s','','g'))=0 then raise exception 'Parts tabs source boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||array[api,sig];
select count(*)into n from regexp_matches(old,$pat$\),base\s+as\s+materialized\(select\s+o\.id\s+order_id$pat$,'g');if n<>1 then raise exception 'Parts tabs base boundary differs.';end if;
updated:=regexp_replace(old,$pat$\),base\s+as\s+materialized\(select\s+o\.id\s+order_id$pat$,$repl$),current_orders as materialized(select *from greenloop_private.pqm_orders()),visible as materialized(
 select o.*from current_orders q join greenloop_private.parts_flow_orders o on o.id=q.order_id
 union all select l.*from latest l where l.completed_at is not null and not exists(select 1 from current_orders q where q.device_id=l.device_id)
),base as materialized(select exists(select 1 from current_orders q where q.order_id=o.id and q.needs_issue)issue_pending,o.id order_id$repl$);
select count(*)into n from regexp_matches(updated,$pat$from\s+latest\s+o\s+join\s+public\.jobs$pat$,'g');if n<>1 then raise exception 'Parts tabs visible boundary differs.';end if;
updated:=regexp_replace(updated,$pat$from\s+latest\s+o\s+join\s+public\.jobs$pat$,'from visible o join public.jobs');
select count(*)into n from regexp_matches(updated,$pat$when\s+status\s*=\s*'Issued'\s+then\s*'issued'\s+else\s*'pending'$pat$,'g');if n<>1 then raise exception 'Parts tabs classification boundary differs.';end if;
updated:=regexp_replace(updated,$pat$when\s+status\s*=\s*'Issued'\s+then\s*'issued'\s+else\s*'pending'$pat$,$repl$when issue_pending then 'pending' else 'issued'$repl$);
updated:=replace(updated,$q$jsonb_build_object('total',$q$,$q$jsonb_build_object('queue_version','20261119-parts-queue-membership-1','total',$q$);execute updated;

api:='public.get_parts_pending_imei_counts_v1()';api_oid:=to_regprocedure(api);
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,office_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if n<>1 or office_oid is null or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=office_oid and original_hash=md5(pg_get_functiondef(office_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Missing, ambiguous or changed Parts badge Office implementation.';end if;
if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=office_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Parts badge Office implementation.';end if;
target_oid:=office_oid;
if position('into ordered'in pg_get_functiondef(target_oid))=0 then
 select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.capability_routines where to_regprocedure(identity)in(api_oid,office_oid);
 if n<>1 or target_oid is null or not exists(select 1 from greenloop_private.capability_routines where to_regprocedure(implementation)=target_oid and to_regprocedure(identity)in(api_oid,office_oid)and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Missing, ambiguous or changed Parts badge capability implementation.';end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(office_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Parts badge capability implementation.';end if;
end if;
if not exists(select 1 from pg_proc where oid=target_oid and pronamespace='greenloop_private'::regnamespace and prosecdef and pronargs=0 and prorettype='jsonb'::regtype)then raise exception 'Parts badge shape differs.';end if;
sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||array[api,office_oid::regprocedure::text,sig];
select count(*)into n from regexp_matches(old,$pat$with\s+bgr_stay_counts\s+as\s+materialized[\s\S]*?;\s*select\s+count\(distinct\s+imei\)::bigint\s+into\s+returned$pat$,'g');if n<>1 then raise exception 'Parts badge issue boundary differs.';end if;
updated:=regexp_replace(old,$pat$with\s+bgr_stay_counts\s+as\s+materialized[\s\S]*?;\s*select\s+count\(distinct\s+imei\)::bigint\s+into\s+returned$pat$,$repl$select count(*)::bigint into ordered from greenloop_private.pqm_orders()where needs_issue;
 select count(distinct imei)::bigint into returned$repl$);execute updated;

sig:='greenloop_private.sbn_counts()';old:=pg_get_functiondef(sig::regprocedure);
if not exists(select 1 from greenloop_private.background_read_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Sidebar counts source integrity differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
select count(*)into n from regexp_matches(old,$pat$with\s+bgr_stay_counts\s+as\s+materialized[\s\S]*?\)pending;$pat$,'g');if n<>1 then raise exception 'Sidebar Parts boundary differs.';end if;
updated:=regexp_replace(old,$pat$with\s+bgr_stay_counts\s+as\s+materialized[\s\S]*?\)pending;$pat$,$repl$select count(distinct imei)into n from(
 select d.imei_1 imei from greenloop_private.pqm_orders()q join public.devices d on d.id=q.device_id where q.needs_issue
 union select imei from greenloop_private.pp_returns()where status='pending')pending;$repl$);execute updated;

-- Reports handover must finalize its protected Parts order too, so that its
-- history is Completed rather than an abandoned uncompleted issue list.
sig:='greenloop_private.scp_apply(uuid,text,text,uuid,text,text,uuid)';old:=pg_get_functiondef(sig::regprocedure);
if not exists(select 1 from greenloop_private.stage_change_parts_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Reports stage completion integrity differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
select count(*)into n from regexp_matches(old,$pat$res\s*:=\s*public\.complete_lab_technician_line\(step\);$pat$,'g');if n<>1 then raise exception 'Reports Parts completion boundary differs.';end if;
updated:=regexp_replace(old,$pat$res\s*:=\s*public\.complete_lab_technician_line\(step\);$pat$,$repl$review:=greenloop_private.ps_plan(step);
  res:=public.complete_parts_only_lab_v1(step,(review->>'revision')::integer,(review->>'services_revision')::integer);$repl$);execute updated;

-- Advance only integrity receipts that still match each reviewed old body.
for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
 update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
end loop;
insert into greenloop_private.capability_rpc_rules values('get_parts_queue_membership_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table greenloop_private.parts_queue_membership_installation(identity text primary key,hash text not null);
alter table greenloop_private.parts_queue_membership_installation enable row level security;revoke all on greenloop_private.parts_queue_membership_installation from public,anon,authenticated;
create or replace function public.get_parts_queue_membership_version()returns text language sql stable security definer set search_path=pg_catalog,public as $f$
select case when public.get_stage_change_parts_version()='20261119-stage-change-parts-1'and public.get_parts_tabs_boundary_version()='20261107-parts-tabs-boundary-1'and public.get_background_read_speed_version()='20261118-background-read-speed-1'
and(select count(*)=case when position('into ordered'in pg_get_functiondef((select min(to_regprocedure(implementation)::oid)from greenloop_private.office_routines where to_regprocedure(identity)='public.get_parts_pending_imei_counts_v1()'::regprocedure)))>0 then 8 else 9 end and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.parts_queue_membership_installation)
and not exists(select 1 from(values('public.get_parts_order_tabs_v1(text,jsonb,integer,integer,text,text)'),('public.get_parts_pending_imei_counts_v1()'))a(api)where not exists(select 1 from greenloop_private.office_routines o where to_regprocedure(o.identity)=to_regprocedure(a.api)and o.original_hash=md5(pg_get_functiondef(to_regprocedure(o.implementation)))and o.wrapped_hash=md5(pg_get_functiondef(to_regprocedure(o.identity)))and position((select 'greenloop_private.'||proname||'('from pg_proc where oid=to_regprocedure(o.implementation))in regexp_replace(replace(pg_get_functiondef(to_regprocedure(o.identity)),'"',''),'\s','','g'))>0)or(select count(distinct to_regprocedure(o.implementation))from greenloop_private.office_routines o where to_regprocedure(o.identity)=to_regprocedure(a.api))<>1)
and not exists(select 1 from greenloop_private.parts_queue_membership_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.parts_queue_membership_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.parts_queue_membership_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.parts_queue_membership_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261119-parts-queue-membership-1'end;$f$;
revoke all on function public.get_parts_queue_membership_version()from public;grant execute on function public.get_parts_queue_membership_version()to anon,authenticated;
insert into greenloop_private.parts_queue_membership_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from(select distinct unnest(sealed)identity)x;
if public.get_parts_queue_membership_version()is distinct from '20261119-parts-queue-membership-1'then raise exception 'Parts queue verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_parts_queue_membership_version()as installed_parts_queue_membership_version;
