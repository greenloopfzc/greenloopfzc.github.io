-- Accounts summaries: evaluate inventory once, never once per displayed page.
DO $accounts_speed_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_stock_units_version()is distinct from '20261113-stock-units-1'then raise exception 'Verify Stock Units first.';end if;if to_regprocedure('public.get_accounts_read_speed_version()')is not null then if public.get_accounts_read_speed_version()is distinct from '20261113-accounts-read-speed-1'then raise exception 'Existing Accounts reader integrity needs review.';end if;end if;end;$$;
-- This complete reader is private. Public APIs retain their existing50-row limit.
do $clone$declare original text;updated text;begin
 original:=pg_get_functiondef('greenloop_private.asf_report(text,jsonb,integer,integer,text,text)'::regprocedure);
 updated:=replace(original,'FUNCTION greenloop_private.asf_report(','FUNCTION greenloop_private.su_filter_report(');
 updated:=regexp_replace(updated,'p_limit\s+not\s+between\s+1\s+and\s+50','p_limit not between 1 and 2147483647','i');
 if updated=original or position('p_limit not between 1 and 2147483647'in updated)=0 then raise exception 'Review the bounded Accounts reader before installing.';end if;
 execute updated;
end;$clone$;
revoke all on function greenloop_private.su_filter_report(text,jsonb,integer,integer,text,text)from public,anon,authenticated;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;begin
 foreach sig in array array['greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','greenloop_private.su_supplier_rows()','greenloop_private.srd_rows(jsonb)','greenloop_private.sc_receipts()']loop
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);updated:=old;
 if sig like '%acard_report%'then
  if position('su_filter_report'in old)=0 then
   updated:=regexp_replace(updated,'loop\s+part\s*:=\s*greenloop_private\.asf_report\([\s\S]*?end\s+loop\s*;',$single$base:=greenloop_private.su_filter_report(p_kind,p_filters,0,2147483647,p_sort_key,p_sort_direction);source:=base->'rows'; /* one-inventory-read */$single$,'i');
   if updated=old or position('one-inventory-read'in updated)=0 or position('part:=greenloop_private.asf_report'in updated)>0 then raise exception 'Accounts page-loop boundary changed.';end if;
  end if;
 elsif sig like '%su_supplier_rows%'then
  if position('one-supplier-source'in old)=0 then
   updated:=regexp_replace(updated,$p$units\s+as\s+materialized\s*\(\s*select\s+r\s+from\s+greenloop_private\.su_units\s*\(\s*'\{\}'\s*\)\s*r\s*\)\s*,\s*originals\s+as\s+materialized\s*\(\s*select\s+r\s*,\s*r\s*->\s*'unit_original'\s*origin\s+from\s+units\s*\)$p$,$v$raw as materialized(select r,coalesce(nullif(r->>'replacement_root_record_key',''),r->>'record_key')unit_key from greenloop_private.srd_rows('{}')r),parents as materialized(select distinct r->>'replacement_of_record_key'key from raw where r->>'replacement_of_record_key'is not null),units as materialized(select distinct on(a.unit_key)a.r,a.unit_key from raw a left join parents p on p.key=a.r->>'record_key'order by a.unit_key,p.key is not null,coalesce((a.r->>'is_replacement')::boolean,false)desc,a.r->>'record_key'),originals as materialized(select u.r,coalesce(o.r,u.r)origin from units u left join raw o on o.r->>'record_key'=u.unit_key) /* one-supplier-source */$v$);
   updated:=regexp_replace(updated,$ret$from\s+greenloop_private\.srd_rows\s*\(\s*'\{\}'\s*\)\s*r\s+where\s*\(\s*r\s*->>\s*'returned'\s*\)\s*::\s*boolean$ret$,'from raw where(r->>''returned'')::boolean','i');
   if updated=old or position('one-supplier-source'in updated)=0 or position('from raw where(r->>''returned'')::boolean'in updated)=0 then raise exception 'Supplier aggregate boundary changed.';end if;
  end if;
 elsif sig like '%srd_rows%'then
  if position('one-name-check'in old)=0 then
   updated:=regexp_replace(updated,'with\s+roots\s+as\s+materialized','with name_access as materialized(select public.get_my_partner_name_access()allowed /* one-name-check */),roots as materialized');
   updated:=regexp_replace(updated,'case\s+when\s+public\.get_my_partner_name_access\(\)\s*then\s+b\.supplier_name\s+end','case when(select allowed from name_access)then b.supplier_name end');
   if updated=old or position('one-name-check'in updated)=0 then raise exception 'Stock name-privacy boundary changed.';end if;
  end if;
 else
  if position('one-receipt-name-check'in old)=0 then
   updated:=regexp_replace(updated,'with\s+recursive\s+edges\s+as','with recursive name_access as materialized(select coalesce(public.get_my_partner_name_access(),false)allowed /* one-receipt-name-check */),edges as','i');
   updated:=regexp_replace(updated,'case\s+when\s+coalesce\(public\.get_my_partner_name_access\(\),false\)then','case when(select allowed from name_access)then','i');
   if updated=old or position('one-receipt-name-check'in updated)=0 then raise exception 'Receipt name-privacy boundary changed.';end if;
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
create table if not exists greenloop_private.accounts_read_speed_installation(identity text primary key,hash text not null);alter table greenloop_private.accounts_read_speed_installation enable row level security;revoke all on greenloop_private.accounts_read_speed_installation from public,anon,authenticated;
create or replace function public.get_accounts_read_speed_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_stock_units_version()='20261113-stock-units-1'and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.accounts_read_speed_installation)and not has_function_privilege('authenticated','greenloop_private.su_filter_report(text,jsonb,integer,integer,text,text)','EXECUTE')and not has_table_privilege('authenticated','greenloop_private.accounts_read_speed_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261113-accounts-read-speed-1'end;$$;
revoke all on function public.get_accounts_read_speed_version()from public;grant execute on function public.get_accounts_read_speed_version()to anon,authenticated;
insert into greenloop_private.accounts_read_speed_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.su_filter_report(text,jsonb,integer,integer,text,text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','greenloop_private.su_supplier_rows()','greenloop_private.srd_rows(jsonb)','greenloop_private.sc_receipts()','public.get_accounts_read_speed_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_accounts_read_speed_version()is distinct from '20261113-accounts-read-speed-1'then raise exception 'Accounts reader verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$accounts_speed_install$;
select public.get_accounts_read_speed_version()as installed_accounts_read_speed_version;
