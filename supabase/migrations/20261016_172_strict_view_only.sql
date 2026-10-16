-- Strict View Only: close legacy inventory RPC gaps and direct browser writes.
-- Existing data, read access, business rules and service-role jobs are preserved.
begin;

do $$ begin
 if public.get_damage_individual_pdf_version() is distinct from '20261016-damage-individual-pdf-1' then
  raise exception 'Install the verified Individual Damage PDF update first.';
 end if;
end; $$;

create table if not exists greenloop_private.strict_view_only_backup(
 identity text primary key, definition text not null, saved_at timestamptz not null default now()
);
alter table greenloop_private.strict_view_only_backup enable row level security;
revoke all on greenloop_private.strict_view_only_backup from public,anon,authenticated;

-- Three older inventory operations and two replaced legacy user editors checked
-- staff roles but omitted page edit permission. Keep their role/business rules.
do $guards$
declare target text; page_key text; routine record; body text;
begin
 foreach target in array array['move_part_lot_stock','consume_workshop_part_lot','approve_part_stock_adjustment','save_user_page_access','save_user_page_access_v2'] loop
  page_key:=case when target in ('save_user_page_access','save_user_page_access_v2') then 'user_access' else 'inventory' end;
  if (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=target and p.prokind='f')<>1 then
   raise exception 'Expected one reviewed entry routine: %. Nothing installed.',target;
  end if;
  select p.oid,p.prosrc,p.prosecdef,l.lanname,pg_get_functiondef(p.oid) ddl into routine
  from pg_proc p join pg_language l on l.oid=p.prolang
  where p.pronamespace='public'::regnamespace and p.proname=target and p.prokind='f';
  if routine.lanname<>'plpgsql' or not routine.prosecdef or routine.prosrc !~* '(^|\n)[ \t]*begin\M' then
   raise exception 'Cannot safely guard %. Nothing installed.',target;
  end if;
  insert into greenloop_private.strict_view_only_backup(identity,definition)
   values(routine.oid::regprocedure::text,routine.ddl) on conflict do nothing;
  if strpos(routine.prosrc,'-- greenloop-strict-view-only-20261016')=0 then
   body:=regexp_replace(routine.prosrc,'(^|\n)([ \t]*begin)\M',
    E'\nbegin\n  -- greenloop-strict-view-only-20261016\n  perform public.greenloop_require_entry(array['||quote_literal(page_key)||']::text[]);','i');
   execute replace(routine.ddl,routine.prosrc,body);
  end if;
  execute format('revoke all on function %s from public,anon',routine.oid::regprocedure);
  execute format('grant execute on function %s to authenticated',routine.oid::regprocedure);
 end loop;
end;
$guards$;

-- Only the two deliberately guarded legacy user editors are shared with these
-- older installation receipts. Preserve every unrelated receipt/hash.
do $refresh_reviewed_receipts$
declare receipt text;
begin
 foreach receipt in array array['greenloop_private.tv_damage_access_installation','greenloop_private.supplier_return_installation'] loop
  execute format('update %s set definition_hash=md5(pg_get_functiondef(to_regprocedure(object_identity)))
   where object_kind=''function'' and to_regprocedure(object_identity) in
    (''public.save_user_page_access(uuid,text,text,boolean,text[])''::regprocedure,
     ''public.save_user_page_access_v2(uuid,text,text,boolean,jsonb)''::regprocedure)',receipt);
 end loop;
end;
$refresh_reviewed_receipts$;

-- The shipped application writes through permission-checked SECURITY DEFINER
-- routines. Browser table/column DML would bypass those page-level checks.
-- Keep SELECT grants/policies intact. Preserve explicit service_role access,
-- including installations where that role previously inherited a PUBLIC grant.
do $table_writes$
declare r record; cols text; privilege text; service_exists boolean:=exists(select 1 from pg_roles where rolname='service_role');
begin
 for r in select c.oid,n.nspname,c.relname,c.relacl::text acl from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','p','v','m','f') order by c.oid loop
  insert into greenloop_private.strict_view_only_backup(identity,definition)
   values('acl:'||r.oid::regclass::text,jsonb_build_object('table_acl',r.acl,'column_acls',
    (select jsonb_object_agg(a.attname,a.attacl::text) from pg_attribute a where a.attrelid=r.oid and a.attnum>0 and not a.attisdropped))::text)
   on conflict do nothing;
  if service_exists then
   foreach privilege in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
    if has_table_privilege('service_role',r.oid,privilege) then
     execute format('grant %s on table %I.%I to service_role',privilege,r.nspname,r.relname);
    end if;
   end loop;
  end if;
  execute format('revoke insert,update,delete,truncate on table %I.%I from public,anon,authenticated',r.nspname,r.relname);
  select string_agg(quote_ident(a.attname),',') into cols from pg_attribute a where a.attrelid=r.oid and a.attnum>0 and not a.attisdropped;
  if cols is not null then
   execute format('revoke insert (%s),update (%s) on table %I.%I from public,anon,authenticated',cols,cols,r.nspname,r.relname);
  end if;
 end loop;
end;
$table_writes$;

create table if not exists greenloop_private.strict_view_only_installation(identity text primary key,hash text not null);
alter table greenloop_private.strict_view_only_installation enable row level security;
revoke all on greenloop_private.strict_view_only_installation from public,anon,authenticated;
insert into greenloop_private.strict_view_only_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p
 where p.pronamespace='public'::regnamespace and p.proname=any(array[
  'move_part_lot_stock','consume_workshop_part_lot','approve_part_stock_adjustment','save_user_page_access','save_user_page_access_v2','greenloop_require_entry','has_page_edit_access'])
 on conflict(identity) do update set hash=excluded.hash;

create or replace function public.get_strict_view_only_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_damage_individual_pdf_version()='20261016-damage-individual-pdf-1'
 and (select count(*)=7 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))))
  from greenloop_private.strict_view_only_installation)
 and not exists(select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relkind in ('r','p','v','m','f')
  and (has_table_privilege('anon',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
   or has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
   or has_any_column_privilege('anon',c.oid,'INSERT,UPDATE')
   or has_any_column_privilege('authenticated',c.oid,'INSERT,UPDATE')))
 and not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace
  and p.proname=any(array['move_part_lot_stock','consume_workshop_part_lot','approve_part_stock_adjustment','save_user_page_access','save_user_page_access_v2'])
  and (has_function_privilege('anon',p.oid,'EXECUTE') or not has_function_privilege('authenticated',p.oid,'EXECUTE')))
 and not exists(select 1 from pg_class c where c.oid=any(array[
  'greenloop_private.strict_view_only_backup'::regclass,'greenloop_private.strict_view_only_installation'::regclass])
  and (not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
   or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 then '20261016-strict-view-only-1' end;
$$;
revoke all on function public.get_strict_view_only_version() from public;
grant execute on function public.get_strict_view_only_version() to anon,authenticated;
do $$ begin if public.get_strict_view_only_version() is distinct from '20261016-strict-view-only-1' then
 raise exception 'Strict View Only verification failed. No changes installed.';
end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_strict_view_only_version() as installed_strict_view_only_version;
