-- Read-only readiness details shared by Lab handover preview and final locked validation.
do $install$
declare api text;api_oid oid;target_oid oid;sig text;old text;updated text;n integer;t record;c record;b record;reviewed jsonb:='[]';sealed text[]:=array['greenloop_private.lbt_phone(text)','public.get_lab_transfer_readiness_version()'];
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_lab_transfer_readiness_version()')is not null then
  if public.get_lab_transfer_readiness_version()is distinct from '20261118-lab-transfer-readiness-1'then raise exception 'Existing Lab transfer readiness integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_lab_counter_membership_version()is distinct from '20261118-lab-counter-membership-1'then raise exception 'Install the verified Lab counter membership update first.';end if;
 foreach api in array array['public.lookup_lab_bulk_phone_v1(text)','public.transfer_lab_bulk_to_final_qc_v1(jsonb,uuid)']loop
  api_oid:=to_regprocedure(api);
  select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
  if n<>1 or target_oid is null then raise exception 'Missing or ambiguous Lab transfer Office implementation: %',api;end if;
  if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Lab transfer Office integrity differs: %',api;end if;
  if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Lab transfer implementation shape differs.';end if;
  if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Lab transfer implementation.';end if;
  old:=regexp_replace(pg_get_functiondef(target_oid),'\s','','g');
  if position('greenloop_private.lbt_access()'in old)=0 or position('greenloop_private.lbt_phone('in old)=0 then raise exception 'Lab transfer source boundary changed.';end if;
  sealed:=sealed||array[api,target_oid::regprocedure::text];
 end loop;
 sig:='greenloop_private.lbt_phone(text)';old:=pg_get_functiondef(sig::regprocedure);
 if not exists(select 1 from greenloop_private.lab_bulk_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Lab readiness source integrity differs.';end if;
 reviewed:=jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
 if position('selection_token'in old)=0 or position('services_saved'in old)=0 or position('job_part_requests'in old)=0 or position('lab_part_return_requests'in old)=0 then raise exception 'Lab readiness source boundary changed.';end if;
 select count(*)into n from regexp_matches(old,'result\s*:=\s*jsonb_build_object\(','g');if n<>1 then raise exception 'Lab readiness result boundary changed.';end if;
 updated:=regexp_replace(old,'result\s*:=\s*jsonb_build_object\(',$patch$
 if j.id is not null and not greenloop_private.company_job_available(j.id)then
  reasons:=reasons||jsonb_build_array('Chaman transfer: receive this phone back at Greenloop before transfer to Final QC.');
 end if;
 result:=jsonb_build_object('readiness_version','20261118-lab-transfer-readiness-1',
 'current_stage',case when j.id is not null and not greenloop_private.company_job_available(j.id)then 'Chaman transfer - awaiting Greenloop receiving'
 else coalesce((public.get_imei_duplicate_stage_v1(d.imei_1))->>'current_stage','Current stage not recorded')end,
 $patch$);execute updated;
 create table greenloop_private.lab_transfer_readiness_installation(identity text primary key,hash text not null);
 alter table greenloop_private.lab_transfer_readiness_installation enable row level security;
 revoke all on greenloop_private.lab_transfer_readiness_installation from public,anon,authenticated;
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


create or replace function public.get_lab_transfer_readiness_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_lab_counter_membership_version()='20261118-lab-counter-membership-1'
and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_transfer_readiness_installation)
and not exists(select 1 from greenloop_private.lab_transfer_readiness_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.lab_transfer_readiness_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.lab_transfer_readiness_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.lab_transfer_readiness_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261118-lab-transfer-readiness-1'end;$version$;
revoke all on function public.get_lab_transfer_readiness_version()from public;grant execute on function public.get_lab_transfer_readiness_version()to anon,authenticated;
insert into greenloop_private.lab_transfer_readiness_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_lab_transfer_readiness_version()is distinct from '20261118-lab-transfer-readiness-1'then raise exception 'Lab transfer readiness verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_lab_transfer_readiness_version()as installed_lab_transfer_readiness_version;
