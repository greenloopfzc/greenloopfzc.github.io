-- The capability wrapper added in 173 retained this RPC's SECURITY INVOKER
-- setting. Authenticated callers therefore could not reach its private guard.
-- Run only this guarded wrapper as its existing owner; keep the private schema
-- and implementations inaccessible to browser roles. Business logic is unchanged.
begin;

do $$ begin
 if public.get_settings_appearance_version() is distinct from '20261017-settings-appearance-1' then
  raise exception 'Install and verify the Settings / Appearance update first. Nothing changed.';
 end if;
end; $$;

create table if not exists greenloop_private.ready_stock_rework_permission_backup (
 identity text primary key, definition text not null, saved_at timestamptz not null default now()
);
create table if not exists greenloop_private.ready_stock_rework_permission_installation (
 identity text primary key, definition_hash text not null
);
alter table greenloop_private.ready_stock_rework_permission_backup enable row level security;
alter table greenloop_private.ready_stock_rework_permission_installation enable row level security;
revoke all on greenloop_private.ready_stock_rework_permission_backup,
 greenloop_private.ready_stock_rework_permission_installation from public,anon,authenticated;

do $repair$
declare
 target regprocedure := 'public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid)'::regprocedure;
 routine record;
begin
 select p.prosrc,pg_get_functiondef(p.oid) ddl,r.implementation,r.wrapped_hash
 into strict routine from pg_proc p join greenloop_private.capability_routines r
 on to_regprocedure(r.identity)=p.oid where p.oid=target and r.kind='write';
 if routine.wrapped_hash is distinct from md5(routine.ddl)
 or strpos(routine.prosrc,'greenloop-capability-wrapper-20261016')=0
 or strpos(routine.prosrc,'greenloop_private.begin_capability(''send_ready_stock_for_rework_atomic_v2''')=0
 or not exists(select 1 from greenloop_private.capability_rpc_rules
   where rpc_name='send_ready_stock_for_rework_atomic_v2'
   and rule='{"page":"ready_stock","capability":"rework"}'::jsonb) then
  raise exception 'Rework function differs from the reviewed permission wrapper. Nothing changed.';
 end if;
 insert into greenloop_private.ready_stock_rework_permission_backup(identity,definition)
 values(target::text,routine.ddl) on conflict do nothing;

 alter function public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid) security definer;
 alter function public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid) set search_path=pg_catalog,public;
 revoke all on function public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid) from public,anon;
 grant execute on function public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid) to authenticated;

 -- Refresh only receipts for the one reviewed function whose execution
 -- settings changed. No permission assignments or operational rows are edited.
 update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(target))
 where to_regprocedure(identity)=target;
 update greenloop_private.mobile_device_installation set definition_hash=md5(pg_get_functiondef(target))
 where object_kind='function' and to_regprocedure(object_identity)=target;
 insert into greenloop_private.ready_stock_rework_permission_installation
 values(target::text,md5(pg_get_functiondef(target)))
 on conflict(identity) do update set definition_hash=excluded.definition_hash;
end;
$repair$;

create or replace function public.get_ready_stock_rework_permission_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_settings_appearance_version()='20261017-settings-appearance-1'
 and public.get_greenloop_mobile_device_version()='20261001-multi-brand-devices-1'
 and exists (
  select 1 from pg_proc p
  join greenloop_private.ready_stock_rework_permission_installation i on to_regprocedure(i.identity)=p.oid
  where p.oid='public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid)'::regprocedure
  and p.prosecdef and p.proconfig @> array['search_path=pg_catalog, public']
  and i.definition_hash=md5(pg_get_functiondef(p.oid))
 )
 and has_function_privilege('authenticated','public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid)','EXECUTE')
 and not has_function_privilege('anon','public.send_ready_stock_for_rework_atomic_v2(text,text,text,uuid)','EXECUTE')
 and not has_schema_privilege('authenticated','greenloop_private','USAGE')
 and not has_schema_privilege('anon','greenloop_private','USAGE')
 and not exists (
  select 1 from unnest(array['ready_stock_rework_permission_backup','ready_stock_rework_permission_installation']) t
  join pg_class c on c.oid=('greenloop_private.'||t)::regclass
  where not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 ) then '20261017-ready-stock-rework-permissions-1' end;
$$;
revoke all on function public.get_ready_stock_rework_permission_version() from public;
grant execute on function public.get_ready_stock_rework_permission_version() to anon,authenticated;
do $$ begin
 if public.get_ready_stock_rework_permission_version() is distinct from '20261017-ready-stock-rework-permissions-1' then
  raise exception 'Ready Stock rework permission verification failed. Nothing installed.';
 end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_ready_stock_rework_permission_version() as installed_ready_stock_rework_permission_version;
