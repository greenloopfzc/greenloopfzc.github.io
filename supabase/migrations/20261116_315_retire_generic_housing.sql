-- Retire only the exact generic Housing option. No operational history is deleted or renamed.
DO $housing_retirement_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_returned_grade_report_version()is distinct from '20261116-returned-grade-report-1'or not exists(select 1 from greenloop_private.qc_choice_defaults_installation where to_regprocedure(identity)='greenloop_private.qca_housing(text,jsonb)'::regprocedure and hash=md5(pg_get_functiondef(to_regprocedure(identity))))or not exists(select 1 from greenloop_private.qc_auto_rules_installation where to_regprocedure(identity)='greenloop_private.qca_housing(text,jsonb)'::regprocedure and hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Verify Returned Grade Report and recorded QC helper integrity first.';end if;
if to_regprocedure('public.get_generic_housing_retirement_version()')is not null then if public.get_generic_housing_retirement_version()is distinct from '20261116-generic-housing-retired-1'then raise exception 'Existing Housing retirement integrity needs review.';end if;end if;end;$$;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;qc_sig text;begin
select implementation into strict qc_sig from greenloop_private.office_routines where to_regprocedure(identity)='public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure;
for sig in select p.oid::regprocedure::text from pg_proc p where p.oid='greenloop_private.qca_housing(text,jsonb)'::regprocedure or p.oid=to_regprocedure(qc_sig)or p.pronamespace='greenloop_private'::regnamespace and p.prosrc like '%Grade D requires Housing. Send this phone to Lab & Parts.%'loop
old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);
if sig='greenloop_private.qca_housing(text,jsonb)'then execute $helper$
create or replace function greenloop_private.qca_housing(p_grade text,p_parts jsonb)returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$declare parts jsonb:=coalesce(p_parts,'[]');begin
 if jsonb_typeof(parts)is distinct from 'array'then raise exception 'Choose a valid parts list.'using errcode='22023';end if;
 -- Generic Housing is retired. Never substitute 4G or 5G without the user's selection.
 return parts;
end;$$;
$helper$;
elsif to_regprocedure(sig)=to_regprocedure(qc_sig)then
updated:=old;
if position('generic-housing-retirement-replay'in old)=0 then
 if position('existing.request_id=request and existing.payload_hash=fingerprint'in old)=0 then raise exception 'Initial QC replay boundary changed; review before installing.';end if;
 updated:=replace(old,'existing.request_id=request and existing.payload_hash=fingerprint',$compat$existing.request_id=request and(existing.payload_hash=fingerprint or
 -- generic-housing-retirement-replay: verify the exact pre-retirement empty Grade D request, without recreating its part.
 gl='D'and jsonb_array_length(parts)=0 and existing.payload_hash=md5(jsonb_build_object('job',p_job_id,'parts',jsonb_build_array(jsonb_build_object('part_name','Housing','quantity',1,'notes','Default Housing for GL Grade D')),'findings',p_findings,'supplier_grade',sg,'gl_grade',gl,'notes',p_notes)::text))$compat$);
 if position('generic-housing-retirement-replay'in updated)=0 then raise exception 'Initial QC replay compatibility was not applied.';end if;
end if;execute updated;
else updated:=replace(old,'Grade D requires Housing. Send this phone to Lab & Parts.','Grade D must be sent to Lab & Parts.');execute updated;
end if;
 -- Reseal only the matching previously verified function receipts.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;

end loop;end;$patch$;
revoke all on function greenloop_private.qca_housing(text,jsonb)from public,anon,authenticated;
-- Global catalog guard covers every option-create/reactivate RPC and direct master update.
create or replace function greenloop_private.reject_generic_housing_option()returns trigger language plpgsql set search_path=pg_catalog,public as $$begin
if new.option_group='part_name'and new.is_active and lower(btrim(new.option_value))='housing'then raise exception 'Housing has been removed. Choose the specific Housing 4G / 5G variant when required.'using errcode='22023';end if;return new;
end;$$;
revoke all on function greenloop_private.reject_generic_housing_option()from public,anon,authenticated;
drop trigger if exists reject_generic_housing_option on public.entry_options;
create trigger reject_generic_housing_option before insert or update on public.entry_options for each row execute function greenloop_private.reject_generic_housing_option();
update public.entry_options set is_active=false where option_group='part_name'and lower(btrim(option_value))='housing'and is_active;
insert into greenloop_private.capability_rpc_rules values('get_generic_housing_retirement_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.generic_housing_retirement_installation(identity text primary key,hash text not null);alter table greenloop_private.generic_housing_retirement_installation enable row level security;revoke all on greenloop_private.generic_housing_retirement_installation from public,anon,authenticated;
create or replace function public.get_generic_housing_retirement_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_returned_grade_report_version()='20261116-returned-grade-report-1'
and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.generic_housing_retirement_installation)
and not exists(select 1 from public.entry_options where option_group='part_name'and lower(btrim(option_value))='housing'and is_active)
and exists(select 1 from pg_trigger where tgrelid='public.entry_options'::regclass and tgname='reject_generic_housing_option'and tgenabled='O'and tgfoid='greenloop_private.reject_generic_housing_option()'::regprocedure and tgtype=23)
and not has_function_privilege('authenticated','greenloop_private.qca_housing(text,jsonb)','EXECUTE')and not has_function_privilege('anon','greenloop_private.qca_housing(text,jsonb)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.reject_generic_housing_option()','EXECUTE')and not has_function_privilege('anon','greenloop_private.reject_generic_housing_option()','EXECUTE')
and exists(select 1 from pg_class where oid='greenloop_private.generic_housing_retirement_installation'::regclass and relrowsecurity)and not has_table_privilege('authenticated','greenloop_private.generic_housing_retirement_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261116-generic-housing-retired-1'end;$$;
revoke all on function public.get_generic_housing_retirement_version()from public;grant execute on function public.get_generic_housing_retirement_version()to anon,authenticated;
insert into greenloop_private.generic_housing_retirement_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.qca_housing(text,jsonb)','greenloop_private.reject_generic_housing_option()','public.get_generic_housing_retirement_version()',(select implementation from greenloop_private.office_routines where to_regprocedure(identity)='public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure)])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_generic_housing_retirement_version()is distinct from '20261116-generic-housing-retired-1'then raise exception 'Generic Housing retirement verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$housing_retirement_install$;
select public.get_generic_housing_retirement_version()as installed_generic_housing_retirement_version;
