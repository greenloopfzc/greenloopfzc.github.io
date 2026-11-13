-- Chaman Shop permissions: retain the legacy validation boundary and admit the new page.
DO $chaman_access_install$ BEGIN EXECUTE $ddl$
do $patch$declare sig text;old text;updated text;parts text[];allowed_pattern text:='(v_allowed_pages[[:space:]]+constant[[:space:]]+text\[\][[:space:]]*:=[[:space:]]*array\[)([^;]*)(\]::text\[\];)';readonly_pattern text:='(where[[:space:]]+user_id[[:space:]]*=[[:space:]]*p_user_id[[:space:]]+and[[:space:]]+page_key[[:space:]]+in[[:space:]]*\()([^;]*)(\);)';reviews jsonb;r record;t record;c record;begin
 if public.get_chaman_shop_flow_version()is distinct from '20261113-chaman-section-flow-1'then raise exception 'Install the verified Chaman complete flow first.';end if;
 select p.oid::regprocedure::text into strict sig from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'cap_impl_%'and position('v_allowed_pages'in p.prosrc)>0 and position('One or more selected pages are not valid.'in p.prosrc)>0 and p.proargnames@>array['p_user_id','p_page_keys'];
 old:=pg_get_functiondef(sig::regprocedure);updated:=old;parts:=regexp_match(old,allowed_pattern);
 if parts is null then raise exception 'User Access allowed-pages boundary changed. Review before installing.';end if;
 if position('''chaman_shop'''in parts[2])=0 then updated:=regexp_replace(updated,allowed_pattern,'\1\2,''chaman_shop''\3');end if;
 parts:=regexp_match(updated,readonly_pattern);if parts is null then raise exception 'User Access default-level boundary changed. Review before installing.';end if;
 if position('''chaman_shop'''in parts[2])=0 then updated:=regexp_replace(updated,readonly_pattern,'\1\2,''chaman_shop''\3');end if;
 reviews:=jsonb_build_array(jsonb_build_object('identity',sig,'before_hash',md5(old)));if updated<>old then execute updated;end if;
 -- Update only integrity receipts that match the exact reviewed before-definition.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   for r in select *from jsonb_to_recordset(reviews)a(identity text,before_hash text)loop execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using r.identity,r.before_hash;end loop;
  end loop;
 end loop;
 for r in select *from jsonb_to_recordset(reviews)a(identity text,before_hash text)loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 end loop;
end;$patch$;
create table if not exists greenloop_private.chaman_user_access_installation(identity text primary key,hash text not null);alter table greenloop_private.chaman_user_access_installation enable row level security;revoke all on greenloop_private.chaman_user_access_installation from public,anon,authenticated;
create or replace function public.get_chaman_user_access_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_chaman_shop_flow_version()='20261113-chaman-section-flow-1'and public.get_page_capabilities_version()='20261016-page-capabilities-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.chaman_user_access_installation)
 and not has_table_privilege('authenticated','greenloop_private.chaman_user_access_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261113-chaman-user-access-1'end;$$;
revoke all on function public.get_chaman_user_access_version()from public;grant execute on function public.get_chaman_user_access_version()to anon,authenticated;
insert into greenloop_private.chaman_user_access_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'cap_impl_%'and position('v_allowed_pages'in p.prosrc)>0 and position('One or more selected pages are not valid.'in p.prosrc)>0 and p.proargnames@>array['p_user_id','p_page_keys']on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.chaman_user_access_installation values('public.get_chaman_user_access_version()',md5(pg_get_functiondef('public.get_chaman_user_access_version()'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_chaman_user_access_version()is distinct from '20261113-chaman-user-access-1'then raise exception 'Chaman User Access verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$chaman_access_install$;
select public.get_chaman_user_access_version()as installed_chaman_user_access_version;
