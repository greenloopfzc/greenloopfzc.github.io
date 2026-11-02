-- Damage PDFs follow the generating account's saved employee selection.
begin;
do $$begin
 if public.get_tv_month_sunday_version()is distinct from '20261102-tv-month-sunday-1'then raise exception 'Install the verified TV Month / Sunday update first.';end if;
 if to_regprocedure('public.get_damage_pdf_selection_version()')is not null then
  if public.get_damage_pdf_selection_version()is distinct from '20261102-damage-pdf-selection-1'then raise exception 'Existing Damage PDF Selection update needs review.';end if;
 end if;
end;$$;
create or replace function greenloop_private.damage_pdf_employee_visible(p_id uuid,p_name text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce((select e.employee_keys is null
 or coalesce(p_id::text=any(e.employee_keys),false)
 or(p_id is null and(coalesce(('legacy:'||greenloop_private.manual_damage_normalized(p_name))=any(e.employee_keys),false)
 or coalesce(greenloop_private.damage_pdf_employee_key(null,p_name)=any(e.employee_keys),false)))
 from greenloop_private.damage_tv_employees e where e.user_id=auth.uid()),true);
$$;
create or replace view greenloop_private.damage_pdf_selected_rows as
select r.*from greenloop_private.manual_damage_effective r
where greenloop_private.damage_pdf_employee_visible(r.employee_id,r.damaged_by);
create or replace view greenloop_private.damage_pdf_selected_options as
select o.*from public.manual_damage_options o where o.kind<>'employee'
or greenloop_private.damage_pdf_employee_visible(o.id,o.label)
or exists(select 1 from greenloop_private.damage_pdf_selected_rows r
 where greenloop_private.damage_pdf_employee_key(r.employee_id,r.damaged_by)=o.id::text);
revoke all on greenloop_private.damage_pdf_selected_rows,greenloop_private.damage_pdf_selected_options from public,anon,authenticated;
revoke all on function greenloop_private.damage_pdf_employee_visible(uuid,text)from public,anon,authenticated;
-- Apply before count limits, date/technician filtering and aggregation, including
-- legacy PDF export versions. Preserve all existing download/Office/TV-only guards.
do $patch$declare f record;ddl text;changed integer:=0;begin
 for f in select p.oid,p.proname from pg_proc p where p.oid in(
  select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)
  where src.proname in('get_damage_pdf_employees_v1','get_manual_damage_export_v1','get_manual_damage_export_v2','get_manual_damage_export_v3','get_manual_damage_export_v4'))loop
  ddl:=pg_get_functiondef(f.oid);
  ddl:=regexp_replace(ddl,'greenloop_private\.manual_damage_effective\y','greenloop_private.damage_pdf_selected_rows','g');
  ddl:=regexp_replace(ddl,'public\.manual_damage_options\y','greenloop_private.damage_pdf_selected_options','g');
  execute ddl;changed:=changed+1;
 end loop;
 if changed<>5 then raise exception 'Reviewed Damage PDF reader chain differs.';end if;
end;$patch$;
-- Update receipts only for the five reviewed reader implementations above.
do $seal$declare f regprocedure;t record;begin
 for f in select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)
 where src.proname in('get_damage_pdf_employees_v1','get_manual_damage_export_v1','get_manual_damage_export_v2','get_manual_damage_export_v3','get_manual_damage_export_v4')loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  for t in select c.table_name,c.column_name,h.column_name hash_col from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name in('hash','definition_hash')where c.table_schema='greenloop_private'and c.column_name in('identity','object_identity')and right(c.table_name,13)='_installation'loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where %I=$1::text',t.table_name,t.hash_col,t.column_name)using f;
  end loop;
 end loop;
end;$seal$;
create table if not exists greenloop_private.damage_pdf_selection_installation(identity text primary key,hash text not null);
alter table greenloop_private.damage_pdf_selection_installation enable row level security;
revoke all on greenloop_private.damage_pdf_selection_installation from public,anon,authenticated;
create or replace function public.get_damage_pdf_selection_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
select case when public.get_tv_month_sunday_version()='20261102-tv-month-sunday-1'
and(select count(*)=9 and bool_and(coalesce(hash=case when identity in('greenloop_private.damage_pdf_selected_rows','greenloop_private.damage_pdf_selected_options')then md5(pg_get_viewdef(identity::regclass,true))else md5(pg_get_functiondef(to_regprocedure(identity)))end,false))from greenloop_private.damage_pdf_selection_installation)
and not exists(select 1 from greenloop_private.damage_pdf_selection_installation where identity like 'greenloop_private.%'and identity not in('greenloop_private.damage_pdf_selected_rows','greenloop_private.damage_pdf_selected_options')and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and not has_table_privilege('anon','greenloop_private.damage_pdf_selected_rows','SELECT')and not has_table_privilege('authenticated','greenloop_private.damage_pdf_selected_rows','SELECT')
and not has_table_privilege('anon','greenloop_private.damage_pdf_selected_options','SELECT')and not has_table_privilege('authenticated','greenloop_private.damage_pdf_selected_options','SELECT')
and not has_table_privilege('anon','greenloop_private.damage_pdf_selection_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.damage_pdf_selection_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and(select relrowsecurity from pg_class where oid='greenloop_private.damage_pdf_selection_installation'::regclass)
then '20261102-damage-pdf-selection-1'end;
$$;
revoke all on function public.get_damage_pdf_selection_version()from public;grant execute on function public.get_damage_pdf_selection_version()to anon,authenticated;
insert into greenloop_private.damage_pdf_selection_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('public.get_damage_pdf_selection_version()'::regprocedure,'greenloop_private.damage_pdf_employee_visible(uuid,text)'::regprocedure)or p.oid in(
 select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)where src.proname in('get_damage_pdf_employees_v1','get_manual_damage_export_v1','get_manual_damage_export_v2','get_manual_damage_export_v3','get_manual_damage_export_v4'))on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.damage_pdf_selection_installation select n,md5(pg_get_viewdef(n::regclass,true))from unnest(array['greenloop_private.damage_pdf_selected_rows','greenloop_private.damage_pdf_selected_options'])n on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_damage_pdf_selection_version()is distinct from '20261102-damage-pdf-selection-1'then raise exception 'Damage PDF employee selection verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_damage_pdf_selection_version()as installed_damage_pdf_selection_version;
