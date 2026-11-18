-- One atomic Issuance edit: grades, parts and services; no automatic transfer.
do $install$
declare api_oid oid;target_oid oid;matches integer;old text;updated text;n integer;sig text;original_sig text;
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_issuance_grade_edit_version()')is not null then
  if public.get_issuance_grade_edit_version()is distinct from '20261118-issuance-grade-edit-1'then raise exception 'Existing Issuance grade-edit integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_operational_loading_version()is distinct from '20261118-operational-loading-1'then raise exception 'Install the verified operational-loading prerequisite first.';end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Permission rules integrity differs.';end if;
 api_oid:='public.update_qc_issuance_requirements_v1(uuid,text,jsonb,jsonb,uuid)'::regprocedure;
 select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
 if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous registered Issuance implementation.';end if;
 if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Registered Issuance implementation integrity differs.';end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Issuance implementation.';end if;
 original_sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;sig:=original_sig;
updated:=regexp_replace(updated,'FUNCTION [^(]+\([^)]*\)', 'FUNCTION greenloop_private.qcig_save(p_job_id uuid,p_revision text,p_parts jsonb,p_services jsonb,p_supplier_grade text,p_gl_grade text,p_request_id uuid)');
select count(*)into n from regexp_matches(updated,$token$changed\s*boolean:=false;$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$changed\s*boolean:=false;$token$,$replacement$changed boolean:=false;sg text;gg text;$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$fingerprint:=md5\(jsonb_build_object\('job',p_job_id,'revision',p_revision,'parts',parts,'services',services\)::text\);$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$fingerprint:=md5\(jsonb_build_object\('job',p_job_id,'revision',p_revision,'parts',parts,'services',services\)::text\);$token$,$replacement$if p_supplier_grade~'[[:cntrl:]]'or p_gl_grade~'[[:cntrl:]]'then raise exception 'Choose valid grade values.'using errcode='22023';end if;
sg:=nullif(upper(regexp_replace(btrim(p_supplier_grade),'\s+',' ','g')),'');gg:=nullif(upper(regexp_replace(btrim(p_gl_grade),'\s+',' ','g')),'');
if gg is null or length(gg)>120 or length(sg)>120 then raise exception 'Select a GL Grade and valid optional Supplier Grade.'using errcode='22023';end if;
if sg is not null and not exists(select 1 from greenloop_private.qc_grade_options g where g.kind='supplier_grade'and g.name=sg)then
 if upper(regexp_replace(btrim(r.supplier_grade),'\s+',' ','g'))=sg then sg:=r.supplier_grade;else raise exception 'Choose Supplier Grade from the saved dropdown.'using errcode='22023';end if;
end if;
if not exists(select 1 from greenloop_private.qc_grade_options g where g.kind='gc_grade'and g.name=gg)then
 if upper(regexp_replace(btrim(r.gl_grade),'\s+',' ','g'))=gg then gg:=r.gl_grade;else raise exception 'Choose GL Grade from the saved dropdown.'using errcode='22023';end if;
end if;
fingerprint:=md5(jsonb_build_object('job',p_job_id,'revision',p_revision,'parts',parts,'services',services,'supplier_grade',sg,'gl_grade',gg)::text);$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$before_work:=jsonb_build_object\('parts',r\.parts,'services',r\.services\);$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$before_work:=jsonb_build_object\('parts',r\.parts,'services',r\.services\);$token$,$replacement$before_work:=jsonb_build_object('parts',r.parts,'services',r.services,'supplier_grade',r.supplier_grade,'gl_grade',r.gl_grade);$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$begin_capability\('update_qc_issuance_requirements_v1'$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$begin_capability\('update_qc_issuance_requirements_v1'$token$,$replacement$begin_capability('update_qc_issuance_details_v2'$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$perform\s*public\.greenloop_require_entry\(array\['qc_issuance'\]::text\[\]\);$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$perform\s*public\.greenloop_require_entry\(array\['qc_issuance'\]::text\[\]\);$token$,$replacement$perform public.greenloop_require_entry(array['qc_issuance']::text[]);
update public.jobs set supplier_grade=sg where id=p_job_id and supplier_grade is distinct from sg;
update public.devices set gc_grade=gg where id=s.device_id and gc_grade is distinct from gg;$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$after_work:=jsonb_build_object\('parts',r\.parts,'services',r\.services\);$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$after_work:=jsonb_build_object\('parts',r\.parts,'services',r\.services\);$token$,$replacement$after_work:=jsonb_build_object('parts',r.parts,'services',r.services,'supplier_grade',r.supplier_grade,'gl_grade',r.gl_grade);$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$'Issuance\s*parts\s*and\s*services\s*updated'$token$,'g');if n<>1 then raise exception 'Reviewed Issuance boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$'Issuance\s*parts\s*and\s*services\s*updated'$token$,$replacement$'Issuance grades, parts and services updated'$replacement$,'g');

if position('FUNCTION greenloop_private.qcig_save('in updated)=0 then raise exception 'Issuance worker signature could not be verified.';end if;
execute updated;
revoke all on function greenloop_private.qcig_save(uuid,text,jsonb,jsonb,text,text,uuid)from public,anon,authenticated;
create or replace function public.get_qc_issuance_choices_v2()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $choices$
begin
 perform greenloop_private.qcia_require();
 return public.get_qc_issuance_choices_v1()||jsonb_build_object('version','20261118-issuance-grade-edit-1',
 'supplier_grades',coalesce((select jsonb_agg(jsonb_build_object('name',name)order by name)from greenloop_private.qc_grade_options where kind='supplier_grade'),'[]'),
 'gc_grades',coalesce((select jsonb_agg(jsonb_build_object('name',name)order by name)from greenloop_private.qc_grade_options where kind='gc_grade'),'[]'));
end;$choices$;
create or replace function public.update_qc_issuance_details_v2(p_job_id uuid,p_revision text,p_parts jsonb,p_services jsonb,p_supplier_grade text,p_gl_grade text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $save$
begin
 perform greenloop_private.require_office_network();
 return greenloop_private.qcig_save(p_job_id,p_revision,p_parts,p_services,p_supplier_grade,p_gl_grade,p_request_id);
end;$save$;
revoke all on function public.get_qc_issuance_choices_v2(),public.update_qc_issuance_details_v2(uuid,text,jsonb,jsonb,text,text,uuid)from public,anon,authenticated;
grant execute on function public.get_qc_issuance_choices_v2(),public.update_qc_issuance_details_v2(uuid,text,jsonb,jsonb,text,text,uuid)to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_choices_v2','{"page":"qc_issuance","capability":"view","read":true}'),('update_qc_issuance_details_v2','{"page":"qc_issuance","capability":"entry"}'),('get_issuance_grade_edit_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table greenloop_private.issuance_grade_edit_installation(identity text primary key,hash text not null);
alter table greenloop_private.issuance_grade_edit_installation enable row level security;revoke all on greenloop_private.issuance_grade_edit_installation from public,anon,authenticated;
create or replace function public.get_issuance_grade_edit_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_operational_loading_version()='20261118-operational-loading-1'
and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.issuance_grade_edit_installation)
and not exists(select 1 from greenloop_private.issuance_grade_edit_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.issuance_grade_edit_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.issuance_grade_edit_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.issuance_grade_edit_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))
then '20261118-issuance-grade-edit-1'end;$version$;
revoke all on function public.get_issuance_grade_edit_version()from public;grant execute on function public.get_issuance_grade_edit_version()to anon,authenticated;
insert into greenloop_private.issuance_grade_edit_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(array[original_sig,'greenloop_private.qcig_save(uuid,text,jsonb,jsonb,text,text,uuid)','public.get_qc_issuance_choices_v2()','public.update_qc_issuance_details_v2(uuid,text,jsonb,jsonb,text,text,uuid)','public.get_issuance_grade_edit_version()'])identity;
if public.get_issuance_grade_edit_version()is distinct from '20261118-issuance-grade-edit-1'then raise exception 'Issuance grade-edit verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_issuance_grade_edit_version()as installed_issuance_grade_edit_version;
