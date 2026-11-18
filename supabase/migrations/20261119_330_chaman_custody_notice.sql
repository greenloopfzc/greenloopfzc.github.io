-- Accurate Chaman phase labels; no dispatch, receiving, sale or stock records are changed.
do $install$
declare api text:='public.get_imei_duplicate_stage_v1(text)';api_oid oid;target_oid oid;sig text;old text;updated text;n integer;t record;c record;b record;reviewed jsonb:='[]';sealed text[]:=array['greenloop_private.chaman_custody_notice(uuid)','greenloop_private.chaman_stage_identity(jsonb)','greenloop_private.lbt_phone(text)','public.get_imei_duplicate_stage_v1(text)','public.get_chaman_custody_notice_version()'];
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_chaman_custody_notice_version()')is not null then
  if public.get_chaman_custody_notice_version()is distinct from '20261119-chaman-custody-notice-1'then raise exception 'Existing Chaman custody notice integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_lab_transfer_readiness_version()is distinct from '20261118-lab-transfer-readiness-1'then raise exception 'Install the verified Lab readiness update first.';end if;
 api_oid:=to_regprocedure(api);
 select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
 if n<>1 or target_oid is null then raise exception 'Missing or ambiguous IMEI stage Office implementation.';end if;
 if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'IMEI stage Office integrity differs.';end if;
 if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'IMEI stage implementation shape differs.';end if;
 if position('is_active_staff()'in pg_get_functiondef(target_oid))=0 or position('user_page_permissions'in pg_get_functiondef(target_oid))=0 or position('public.devices'in pg_get_functiondef(target_oid))=0 or position('primary_imei'in pg_get_functiondef(target_oid))=0 or position('matched_type'in pg_get_functiondef(target_oid))=0 or position('current_stage'in pg_get_functiondef(target_oid))=0 then raise exception 'IMEI stage source boundary changed.';end if;
 old:=pg_get_functiondef(api_oid);
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(old,'"',''),'\s','','g'))=0 then raise exception 'Disconnected IMEI stage implementation.';end if;
 if position('require_office_network()'in regexp_replace(old,'\s','','g'))=0 or position('qcis_stage('in old)=0 then raise exception 'IMEI stage wrapper boundary changed.';end if;
 select count(*)into n from regexp_matches(old,'return\s+([^;]+);','g');if n<>1 then raise exception 'IMEI stage return boundary changed.';end if;
 reviewed:=jsonb_build_array(jsonb_build_object('identity',api,'hash',md5(old)));
 sealed:=sealed||target_oid::regprocedure::text;
 create or replace function greenloop_private.chaman_custody_notice(p_device uuid)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $notice$
 select case when count(*)=1 then jsonb_agg(jsonb_build_object('phase',l.phase,
  'current_stage',case l.phase when 'out_pending'then 'Chaman receiving pending'when 'shop'then 'Chaman Shop'when 'return_pending'then 'GL receiving pending'else 'Chaman status not verified'end,
  'reason',case l.phase when 'out_pending'then 'Chaman receiving pending'when 'shop'then 'At Chaman Shop'when 'return_pending'then 'GL receiving pending'else 'Chaman status not verified'end))->0
  when count(*)>1 then jsonb_build_object('phase','unverified','current_stage','Chaman status not verified','reason','Chaman status not verified')end
 from greenloop_private.chaman_lines l where l.device_id=p_device and l.phase<>'company'and l.voided_at is null;
 $notice$;
 create or replace function greenloop_private.chaman_stage_identity(p_data jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $identity$
 select p_data||coalesce((select jsonb_build_object('current_stage',x.notice->>'current_stage','chaman_phase',x.notice->>'phase')
 from public.devices d cross join lateral(select greenloop_private.chaman_custody_notice(d.id)notice)x
 where coalesce((p_data->>'found')::boolean,false)and d.imei_1=p_data->>'primary_imei'and d.deleted_at is null and x.notice is not null),'{}'::jsonb);
 $identity$;
 revoke all on function greenloop_private.chaman_custody_notice(uuid),greenloop_private.chaman_stage_identity(jsonb)from public,anon,authenticated;
 updated:=regexp_replace(old,'return\s+([^;]+);',$wrap$return greenloop_private.chaman_stage_identity(\1);$wrap$);execute updated;
 sig:='greenloop_private.lbt_phone(text)';old:=pg_get_functiondef(sig::regprocedure);
 if not exists(select 1 from greenloop_private.lab_transfer_readiness_installation where to_regprocedure(identity)=sig::regprocedure and hash=md5(old))then raise exception 'Lab custody source integrity differs.';end if;
 reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));
 updated:=old;
 select count(*)into n from regexp_matches(updated,'result\s+jsonb\s*;','g');if n<>1 then raise exception 'Lab custody declaration changed.';end if;
 updated:=regexp_replace(updated,'result\s+jsonb\s*;','result jsonb;custody jsonb;');
 select count(*)into n from regexp_matches(updated,$scope$if\s+j\.id\s+is\s+not\s+null\s+and\s+not\s+greenloop_private\.company_job_available\(j\.id\)then\s+reasons\s*:=\s*reasons\s*\|\|\s*jsonb_build_array\('Chaman transfer: receive this phone back at Greenloop before transfer to Final QC\.'\);\s*end\s+if\s*;$scope$,'g');if n<>1 then raise exception 'Lab custody reason boundary changed.';end if;
 updated:=regexp_replace(updated,$scope$if\s+j\.id\s+is\s+not\s+null\s+and\s+not\s+greenloop_private\.company_job_available\(j\.id\)then\s+reasons\s*:=\s*reasons\s*\|\|\s*jsonb_build_array\('Chaman transfer: receive this phone back at Greenloop before transfer to Final QC\.'\);\s*end\s+if\s*;$scope$,$patch$custody:=greenloop_private.chaman_custody_notice(d.id);
 if custody is not null then reasons:=jsonb_build_array(custody->>'reason');
 elsif j.id is not null and not greenloop_private.company_job_available(j.id)then reasons:=reasons||jsonb_build_array('Company custody not verified.');end if;$patch$);
 select count(*)into n from regexp_matches(updated,$scope$'current_stage',\s*case\s+when\s+j\.id\s+is\s+not\s+null\s+and\s+not\s+greenloop_private\.company_job_available\(j\.id\)then\s*'Chaman transfer - awaiting Greenloop receiving'\s*else\s*coalesce\(\(public\.get_imei_duplicate_stage_v1\(d\.imei_1\)\)->>'current_stage','Current stage not recorded'\)end$scope$,'g');if n<>1 then raise exception 'Lab custody stage boundary changed.';end if;
 updated:=regexp_replace(updated,$scope$'current_stage',\s*case\s+when\s+j\.id\s+is\s+not\s+null\s+and\s+not\s+greenloop_private\.company_job_available\(j\.id\)then\s*'Chaman transfer - awaiting Greenloop receiving'\s*else\s*coalesce\(\(public\.get_imei_duplicate_stage_v1\(d\.imei_1\)\)->>'current_stage','Current stage not recorded'\)end$scope$,$patch$'chaman_phase',custody->>'phase','current_stage',coalesce(custody->>'current_stage',(public.get_imei_duplicate_stage_v1(d.imei_1))->>'current_stage','Current stage not recorded')$patch$);execute updated;
 create table greenloop_private.chaman_custody_notice_installation(identity text primary key,hash text not null);
 alter table greenloop_private.chaman_custody_notice_installation enable row level security;
 revoke all on greenloop_private.chaman_custody_notice_installation from public,anon,authenticated;
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
 update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
 update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
end loop;



create or replace function public.get_chaman_custody_notice_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_lab_transfer_readiness_version()='20261118-lab-transfer-readiness-1'
and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.chaman_custody_notice_installation)
and not exists(select 1 from greenloop_private.chaman_custody_notice_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.chaman_custody_notice_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.chaman_custody_notice_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.chaman_custody_notice_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261119-chaman-custody-notice-1'end;$version$;
revoke all on function public.get_chaman_custody_notice_version()from public;grant execute on function public.get_chaman_custody_notice_version()to anon,authenticated;
insert into greenloop_private.chaman_custody_notice_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_chaman_custody_notice_version()is distinct from '20261119-chaman-custody-notice-1'then raise exception 'Chaman custody notice verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_chaman_custody_notice_version()as installed_chaman_custody_notice_version;
