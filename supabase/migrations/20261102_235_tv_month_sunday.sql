-- TV-only current-month damage and Sunday-free overdue time. No business rows change.
begin;
do $$begin
 if public.get_tv_overdue_version()is distinct from '20261101-tv-overdue-1'then raise exception 'Install the verified TV Overdue update first.';end if;
 if to_regprocedure('public.get_tv_month_sunday_version()')is not null then
  if public.get_tv_month_sunday_version()is distinct from '20261102-tv-month-sunday-1'then raise exception 'Existing TV month and Sunday update needs review.';end if;
 end if;
end;$$;
create or replace function greenloop_private.tv_work_seconds(p_start timestamptz,p_end timestamptz)
returns numeric language plpgsql immutable strict set search_path=pg_catalog,public as $$
declare s timestamp:=p_start at time zone 'Asia/Dubai';e timestamp:=p_end at time zone 'Asia/Dubai';first_sunday date;last_sunday date;excluded numeric:=0;begin
 if e<=s then return 0;end if;
 first_sunday:=s::date+((7-extract(dow from s)::integer)%7);
 last_sunday:=e::date-extract(dow from e)::integer;
 if last_sunday>=first_sunday then
  excluded:=((last_sunday-first_sunday)/7+1)*86400;
  if extract(dow from s)=0 then excluded:=excluded-extract(epoch from(s-s::date));end if;
  if extract(dow from e)=0 then excluded:=excluded-extract(epoch from(e::date+interval '1 day'-e));end if;
 end if;
 return greatest(0,extract(epoch from(e-s))-excluded);
end;$$;
create or replace view greenloop_private.tv_month_damage as
select *from greenloop_private.tv_selected_damage
where occurred_at>=date_trunc('month',now()at time zone 'Asia/Dubai')at time zone 'Asia/Dubai'
and occurred_at<(date_trunc('month',now()at time zone 'Asia/Dubai')+interval '1 month')at time zone 'Asia/Dubai';
revoke all on greenloop_private.tv_month_damage from public,anon,authenticated;
-- Clone only the reviewed TV reader chain. Ordinary reports and the original
-- all-history readers keep their sources, IDs, prices, formulas and permissions.
do $clone$declare f record;n text;names text[];ddl text;begin
 select array_agg(proname order by length(proname)desc,proname)into names from pg_proc
 where pronamespace='greenloop_private'::regnamespace and(proname like 'tv_read_%'or proname in('tv_selected_damage_copy_rows','tv_selected_damage_copy_values','tv_selected_manual_damage_employee_value','tv_selected_damage_basis_rows'));
 if cardinality(names)<>14 then raise exception 'Reviewed TV reader chain differs.';end if;
 for f in select p.oid,p.proname from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=any(names)loop
  ddl:=pg_get_functiondef(f.oid);
  foreach n in array names loop ddl:=replace(ddl,'greenloop_private.'||n||'(','greenloop_private.tvm_'||n||'(');end loop;
  ddl:=regexp_replace(ddl,'greenloop_private\.tv_selected_damage\y','greenloop_private.tv_month_damage','g');
  if f.proname='tv_read_damage_basis_summary'then
   if strpos(ddl,'when p_scope in (''month'',''payable'')')=0 then raise exception 'Reviewed TV summary range differs.';end if;
   ddl:=replace(ddl,'when p_scope in (''month'',''payable'')','when p_scope in (''month'',''payable'',''all'',''value'')');
  end if;
  execute ddl;
 end loop;
end;$clone$;
-- Route the same three public, Office-guarded and field-masked TV APIs through
-- the monthly clones. Preserve the full permission and account guards.
do $patch$declare f record;ddl text;n text;count_changed integer:=0;begin
 for f in select p.oid,p.proname from pg_proc p where p.oid in(
  select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)
  where src.proname in('get_damage_tv_cards_v1','get_damage_tv_employee_v1','get_damage_tv_details_v1'))loop
  ddl:=pg_get_functiondef(f.oid);
  foreach n in array array['tv_read_get_manual_damage_cards_v6','tv_read_get_manual_damage_employee_rows_v4','tv_read_get_damage_tv_summary_v2']loop
   ddl:=replace(ddl,'greenloop_private.'||n||'(','greenloop_private.tvm_'||n||'(');
  end loop;
  if strpos(ddl,'greenloop_private.tvm_')=0 then raise exception 'Reviewed TV capability reader differs.';end if;
  execute ddl;count_changed:=count_changed+1;
 end loop;
 if count_changed<>3 then raise exception 'Expected three TV capability readers.';end if;
 ddl:=pg_get_functiondef('greenloop_private.tvr_rows()'::regprocedure);
 if strpos(ddl,'greenloop_private.tv_work_seconds')=0 then
  if strpos(ddl,'st.elapsed_seconds')=0 then raise exception 'Reviewed overdue clock differs.';end if;
  ddl:=replace(ddl,'st.elapsed_seconds','greenloop_private.tv_work_seconds(st.entered_at,now())');execute ddl;
 end if;
end;$patch$;
-- Private helpers are callable only through existing guarded readers.
do $acl$declare f record;begin for f in select oid::regprocedure signature from pg_proc where pronamespace='greenloop_private'::regnamespace and(proname like 'tvm_%'or proname='tv_work_seconds')loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);end loop;end;$acl$;
-- Re-seal just the four reviewed modified functions in preceding receipts.
do $seal$declare f regprocedure;t record;begin
 for f in select p.oid from pg_proc p where p.oid='greenloop_private.tvr_rows()'::regprocedure or p.oid in(
  select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)
  where src.proname in('get_damage_tv_cards_v1','get_damage_tv_employee_v1','get_damage_tv_details_v1'))loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(f))where to_regprocedure(implementation)=f;
  for t in select c.table_name,c.column_name,h.column_name hash_col from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name in('hash','definition_hash')where c.table_schema='greenloop_private'and c.column_name in('identity','object_identity')and right(c.table_name,13)='_installation'loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where %I=$1::text',t.table_name,t.hash_col,t.column_name)using f;
  end loop;
 end loop;
end;$seal$;
create table if not exists greenloop_private.tv_month_sunday_installation(identity text primary key,hash text not null);
alter table greenloop_private.tv_month_sunday_installation enable row level security;
revoke all on greenloop_private.tv_month_sunday_installation from public,anon,authenticated;
create or replace function public.get_tv_month_sunday_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
select case when public.get_tv_overdue_version()='20261101-tv-overdue-1'
and(select count(*)=21 and bool_and(coalesce(hash=case when identity='greenloop_private.tv_month_damage'then md5(pg_get_viewdef('greenloop_private.tv_month_damage'::regclass,true))else md5(pg_get_functiondef(to_regprocedure(identity)))end,false))from greenloop_private.tv_month_sunday_installation)
and not exists(select 1 from greenloop_private.tv_month_sunday_installation where identity like 'greenloop_private.%'and identity<>'greenloop_private.tv_month_damage'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and not has_table_privilege('anon','greenloop_private.tv_month_damage','SELECT')and not has_table_privilege('authenticated','greenloop_private.tv_month_damage','SELECT')
and(select relrowsecurity from pg_class where oid='greenloop_private.tv_month_sunday_installation'::regclass)
and not has_table_privilege('anon','greenloop_private.tv_month_sunday_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.tv_month_sunday_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
then '20261102-tv-month-sunday-1'end;
$$;
revoke all on function public.get_tv_month_sunday_version()from public;grant execute on function public.get_tv_month_sunday_version()to anon,authenticated;
insert into greenloop_private.tv_month_sunday_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and(p.proname like 'tvm_%'or p.proname in('tv_work_seconds','tvr_rows'))or p.oid in(
 select to_regprocedure(r.implementation)from greenloop_private.capability_routines r join pg_proc src on src.oid=to_regprocedure(r.identity)where src.proname in('get_damage_tv_cards_v1','get_damage_tv_employee_v1','get_damage_tv_details_v1'))
or p.oid='public.get_tv_month_sunday_version()'::regprocedure on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.tv_month_sunday_installation values('greenloop_private.tv_month_damage',md5(pg_get_viewdef('greenloop_private.tv_month_damage'::regclass,true)))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_tv_month_sunday_version()is distinct from '20261102-tv-month-sunday-1'then raise exception 'TV monthly and Sunday verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_tv_month_sunday_version()as installed_tv_month_sunday_version;
