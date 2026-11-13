-- Read-only IMEI inventory speed: one privacy decision and indexed unit parent join.
DO $imei_speed_install$ BEGIN EXECUTE $ddl$
create or replace function greenloop_private.isu_units(f jsonb)returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with raw as materialized(select r,coalesce(nullif(r->>'replacement_root_record_key',''),r->>'record_key')unit_key from greenloop_private.srd_rows(f)r),parents as materialized(select distinct r->>'replacement_of_record_key'key from raw where r->>'replacement_of_record_key'is not null),history as materialized(select unit_key,jsonb_agg(r order by r->>'record_key')members,(jsonb_agg(r)filter(where r->>'record_key'=unit_key))->0 original from raw group by unit_key having count(*)>1),ranked as(select a.*,count(*)over(partition by a.unit_key)history_records,row_number()over(partition by a.unit_key order by p.key is not null,coalesce((a.r->>'is_replacement')::boolean,false)desc,a.r->>'record_key')n from raw a left join parents p on p.key=a.r->>'record_key')
 select r||jsonb_build_object('unit_key',u.unit_key,'unit_history_records',history_records)||case when h.members is null then '{}'::jsonb else jsonb_build_object('unit_history',h.members,'unit_original',coalesce(h.original,r))end from ranked u left join history h using(unit_key)where n=1;
 $$;
 revoke all on function greenloop_private.isu_units(jsonb)from public,anon,authenticated;
create or replace function greenloop_private.isu_hydrate(rows jsonb)returns jsonb language sql immutable set search_path=pg_catalog,public as $$select coalesce(jsonb_agg(case when r?'unit_key'and not(r?'unit_history')then r||jsonb_build_object('unit_original',r-array['unit_key','unit_history_records','serial_no'],'unit_history',jsonb_build_array(r-array['unit_key','unit_history_records','serial_no']))else r end order by n),'[]')from jsonb_array_elements(rows)with ordinality x(r,n);$$;
revoke all on function greenloop_private.isu_hydrate(jsonb)from public,anon,authenticated;
do $clone$declare old text;updated text;begin
 old:=pg_get_functiondef('greenloop_private.aid_report(jsonb,integer,integer,text,text,boolean,text)'::regprocedure);
 updated:=replace(old,'FUNCTION greenloop_private.aid_report(','FUNCTION greenloop_private.isu_report(');
 updated:=replace(updated,'greenloop_private.su_units(f)','greenloop_private.isu_units(f)');
 if updated=old or position('FUNCTION greenloop_private.isu_report('in updated)=0 or position('greenloop_private.isu_units(f)'in updated)=0 then raise exception 'IMEI inventory source changed. Review before installing.';end if;execute updated;
end;$clone$;
revoke all on function greenloop_private.isu_report(jsonb,integer,integer,text,text,boolean,text)from public,anon,authenticated;
do $patch$declare sig text;old text;updated text;before_hash text;t record;c record;begin
 if public.get_accounts_read_speed_version()is distinct from '20261113-accounts-read-speed-1'then raise exception 'Verify Accounts Read Speed first.';end if;
 if to_regprocedure('public.get_accounts_imei_speed_version()')is not null then if public.get_accounts_imei_speed_version()is distinct from '20261113-accounts-imei-speed-1'then raise exception 'Existing IMEI reader integrity needs review.';end if;end if;
 foreach sig in array array['greenloop_private.cl_base_aid_rows(jsonb)','greenloop_private.su_units(jsonb)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)']loop
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);updated:=old;
 if sig like '%cl_base_aid_rows%'then
  if position('imei-one-privacy-check'in old)=0 then
   updated:=regexp_replace(updated,'with\s+phones\s+as\s+materialized','with name_access as materialized(select public.get_my_partner_name_access()allowed /* imei-one-privacy-check */),phones as materialized','i');
   updated:=regexp_replace(updated,'case\s+when\s+public\.get_my_partner_name_access\(\)\s*then\s+s\.company_name\s+end','case when(select allowed from name_access)then s.company_name end','gi');
   if updated=old or position('imei-one-privacy-check'in updated)=0 or position('case when public.get_my_partner_name_access()'in updated)>0 then raise exception 'IMEI privacy reader boundary changed.';end if;
  end if;
 elsif sig like '%su_units%'then
  if position('imei-parent-join'in old)=0 then
   updated:=regexp_replace(updated,$p$exists\s*\(\s*select\s+1\s+from\s+parents\s+child\s+where\s+child\.key\s*=\s*raw\.r\s*->>\s*'record_key'\s*\)$p$,'child.key is not null','i');
   updated:=regexp_replace(updated,'\)\s*n\s+from\s+raw\s*\)',')n from raw left join parents child on child.key=raw.r->>''record_key'' /* imei-parent-join */)','i');
   if updated=old or position('imei-parent-join'in updated)=0 or position('order by child.key is not null'in updated)=0 then raise exception 'IMEI original-unit reader boundary changed.';end if;
  end if;
 else
  if position('imei-lean-units'in old)=0 then
   updated:=regexp_replace(updated,'greenloop_private\.aid_report\(p_filters','greenloop_private.isu_report(p_filters /* imei-lean-units */');
   updated:=regexp_replace(updated,$h$return case when p_kind='customer'then result else greenloop_private.chaman_accounts\(result,ids\)end;$h$,$v$if p_kind='imei'then result:=jsonb_set(result,'{rows}',greenloop_private.isu_hydrate(result->'rows'));end if;return case when p_kind='customer'then result else greenloop_private.chaman_accounts(result,ids)end;$v$);
   if updated=old or position('isu_hydrate'in updated)=0 then raise exception 'IMEI report source boundary changed.';end if;
  end if;
 end if;
 if updated<>old then execute updated;end if;
 -- Reseal only receipts whose existing reviewed before-hash matches.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;
end;$patch$;
create table if not exists greenloop_private.accounts_imei_speed_installation(identity text primary key,hash text not null);alter table greenloop_private.accounts_imei_speed_installation enable row level security;revoke all on greenloop_private.accounts_imei_speed_installation from public,anon,authenticated;
create or replace function public.get_accounts_imei_speed_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_accounts_read_speed_version()='20261113-accounts-read-speed-1'and(select count(*)=7 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.accounts_imei_speed_installation)and not exists(select 1 from unnest(array['greenloop_private.isu_units(jsonb)','greenloop_private.isu_report(jsonb,integer,integer,text,text,boolean,text)','greenloop_private.isu_hydrate(jsonb)'])sig where has_function_privilege('authenticated',sig,'EXECUTE')or has_function_privilege('anon',sig,'EXECUTE'))and not has_table_privilege('authenticated','greenloop_private.accounts_imei_speed_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261113-accounts-imei-speed-1'end;$$;
revoke all on function public.get_accounts_imei_speed_version()from public;grant execute on function public.get_accounts_imei_speed_version()to anon,authenticated;
insert into greenloop_private.accounts_imei_speed_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.cl_base_aid_rows(jsonb)','greenloop_private.su_units(jsonb)','greenloop_private.isu_units(jsonb)','greenloop_private.isu_hydrate(jsonb)','greenloop_private.isu_report(jsonb,integer,integer,text,text,boolean,text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','public.get_accounts_imei_speed_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_accounts_imei_speed_version()is distinct from '20261113-accounts-imei-speed-1'then raise exception 'IMEI speed verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$imei_speed_install$;
select public.get_accounts_imei_speed_version()as installed_accounts_imei_speed_version;
