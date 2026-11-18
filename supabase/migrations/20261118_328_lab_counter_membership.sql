-- Align Lab phone-list membership with existing current technician card counts.
-- No business records, assignments, counts, stock quantities or histories are rewritten.
do $install$
declare api text:='public.get_lab_employee_rows_v1(uuid)';api_oid oid;target_oid oid;sig text;old text;updated text;n integer;t record;c record;b record;reviewed jsonb:='[]';
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_lab_counter_membership_version()')is not null then
  if public.get_lab_counter_membership_version()is distinct from '20261118-lab-counter-membership-1'then raise exception 'Existing Lab counter membership integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_background_read_speed_version()is distinct from '20261118-background-read-speed-1'then raise exception 'Install the verified background read update first.';end if;
 api_oid:=to_regprocedure(api);
 select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
 if n<>1 or target_oid is null then raise exception 'Missing or ambiguous Lab membership Office implementation.';end if;
 if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Lab membership Office integrity differs.';end if;
 if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Lab membership implementation shape differs.';end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Lab membership implementation.';end if;
 sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
 if position('get_lab_technician_rows_v2'in old)=0 or position('ed_unassigned_rows'in old)=0 or position('pf_cap(''lab_glass'',''view'')'in regexp_replace(old,'\s','','g'))=0 then raise exception 'Lab membership source boundary changed.';end if;
 reviewed:=jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
 select count(*)into n from regexp_matches(updated,'end\s+if\s*;\s*return\s+result\s*;','g');if n<>1 then raise exception 'Lab membership return boundary changed.';end if;
 updated:=regexp_replace(updated,'end\s+if\s*;\s*return\s+result\s*;',$replacement$end if;
 -- Lab cards and phone lines share the same current stage/custody membership.
 select coalesce(jsonb_agg(r.value order by r.n),'[]'::jsonb)into result
 from jsonb_array_elements(result)with ordinality r(value,n)
 join public.job_work_order_steps s on s.id=(r.value->>'step_id')::uuid
 join public.job_work_orders w on w.id=s.work_order_id
 join public.jobs j on j.id=w.job_id and j.id=(r.value->>'job_id')::uuid and j.deleted_at is null
 join public.devices d on d.id=j.device_id and d.id=w.device_id and d.deleted_at is null
 where s.step_status='in_progress'and s.department in('laboratory','glass')
 and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')
 and greenloop_private.company_job_available(j.id)and d.imei_1=r.value->>'imei';
 return result;$replacement$,'g');execute updated;
 create table greenloop_private.lab_counter_membership_installation(identity text primary key,hash text not null);
 alter table greenloop_private.lab_counter_membership_installation enable row level security;
 revoke all on greenloop_private.lab_counter_membership_installation from public,anon,authenticated;
-- Advance only receipts that still exactly match the reviewed prior definition.
for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
end loop;

create or replace function public.get_lab_counter_membership_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_background_read_speed_version()='20261118-background-read-speed-1'
and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_counter_membership_installation)
and not exists(select 1 from greenloop_private.lab_counter_membership_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.lab_counter_membership_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.lab_counter_membership_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.lab_counter_membership_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261118-lab-counter-membership-1'end;$version$;
revoke all on function public.get_lab_counter_membership_version()from public;grant execute on function public.get_lab_counter_membership_version()to anon,authenticated;
insert into greenloop_private.lab_counter_membership_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(array[sig,api,'public.get_lab_counter_membership_version()'])identity;
if public.get_lab_counter_membership_version()is distinct from '20261118-lab-counter-membership-1'then raise exception 'Lab counter membership verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_lab_counter_membership_version()as installed_lab_counter_membership_version;
