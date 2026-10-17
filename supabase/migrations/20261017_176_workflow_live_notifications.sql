-- Token-only Realtime invalidation. Existing authorized count RPC stays intact.
-- No phone/part details are replicated and no business rows are modified.
begin;
do $$ begin
 if public.get_ready_stock_rework_permission_version() is distinct from '20261017-ready-stock-rework-permissions-1' then
  raise exception 'Install and verify the Ready Stock rework permissions update first. Nothing changed.';
 end if;
end; $$;

create table if not exists public.workflow_notification_signal (
 id smallint primary key check (id=1),
 revision bigint not null default 0
);
insert into public.workflow_notification_signal(id) values(1) on conflict do nothing;
alter table public.workflow_notification_signal enable row level security;
revoke all on public.workflow_notification_signal from public,anon,authenticated;
grant select on public.workflow_notification_signal to authenticated;
drop policy if exists workflow_notification_signal_read on public.workflow_notification_signal;
create policy workflow_notification_signal_read on public.workflow_notification_signal
 for select to authenticated using (
 public.has_page_capability_v1('initial_qc','view')
 or public.has_page_capability_v1('lab_glass','view')
 or public.has_page_capability_v1('parts','view')
 or public.has_page_capability_v1('final_qc','view')
 or public.has_page_capability_v1('frame_department','view')
 );

create or replace function greenloop_private.signal_workflow_change()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 -- Several workflow tables change during one transfer. Emit once per committed
 -- transaction, including bulk operations. A rollback also rolls back the token.
 if current_setting('greenloop.workflow_signal_tx',true) is distinct from txid_current()::text then
  update public.workflow_notification_signal set revision=revision+1 where id=1;
  perform set_config('greenloop.workflow_signal_tx',txid_current()::text,true);
 end if;
 return null;
end; $$;
revoke all on function greenloop_private.signal_workflow_change() from public,anon,authenticated;

do $triggers$
declare source text;
begin
 foreach source in array array['jobs','job_work_orders','job_work_order_steps','job_part_requests','lab_part_return_requests'] loop
  execute format('drop trigger if exists greenloop_workflow_signal on public.%I',source);
  -- Defer the token lock until business writes finish. Locking one shared token
  -- midway through multi-phone writes can introduce a new lock-order deadlock.
  execute format('create constraint trigger greenloop_workflow_signal after insert or update or delete on public.%I deferrable initially deferred for each row execute function greenloop_private.signal_workflow_change()',source);
  execute format('drop trigger if exists greenloop_workflow_signal_truncate on public.%I',source);
  execute format('create trigger greenloop_workflow_signal_truncate after truncate on public.%I for each statement execute function greenloop_private.signal_workflow_change()',source);
 end loop;
 -- Keep every existing Realtime table. Publish only our two-column token table.
 if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
  create publication supabase_realtime;
 end if;
 if not exists(select 1 from pg_publication where pubname='supabase_realtime' and pubupdate) then
  raise exception 'The existing Realtime publication does not publish updates. Nothing changed.';
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='workflow_notification_signal') then
  alter publication supabase_realtime add table public.workflow_notification_signal;
 end if;
end;
$triggers$;

create table if not exists greenloop_private.workflow_notification_installation (
 object_name text primary key, definition_hash text not null
);
alter table greenloop_private.workflow_notification_installation enable row level security;
revoke all on greenloop_private.workflow_notification_installation from public,anon,authenticated;
insert into greenloop_private.workflow_notification_installation values
 ('trigger_function',md5(pg_get_functiondef('greenloop_private.signal_workflow_change()'::regprocedure))),
 ('read_policy',(select md5(pg_get_expr(polqual,polrelid)) from pg_policy where polrelid='public.workflow_notification_signal'::regclass and polname='workflow_notification_signal_read'))
on conflict(object_name) do update set definition_hash=excluded.definition_hash;

create or replace function public.get_workflow_live_notifications_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_ready_stock_rework_permission_version()='20261017-ready-stock-rework-permissions-1'
 and exists(select 1 from pg_class where oid='public.workflow_notification_signal'::regclass and relrowsecurity)
 and exists(select 1 from public.workflow_notification_signal where id=1)
 and has_table_privilege('authenticated','public.workflow_notification_signal','SELECT')
 and not has_table_privilege('authenticated','public.workflow_notification_signal','INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','public.workflow_notification_signal','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.signal_workflow_change()','EXECUTE')
 and exists(select 1 from greenloop_private.workflow_notification_installation where object_name='trigger_function' and definition_hash=md5(pg_get_functiondef('greenloop_private.signal_workflow_change()'::regprocedure)))
 and exists(select 1 from pg_policy p join greenloop_private.workflow_notification_installation i on i.object_name='read_policy' and i.definition_hash=md5(pg_get_expr(p.polqual,p.polrelid))
   where p.polrelid='public.workflow_notification_signal'::regclass and p.polname='workflow_notification_signal_read' and p.polcmd='r' and p.polroles=array['authenticated'::regrole::oid])
 and (select count(*)=1 from pg_policy where polrelid='public.workflow_notification_signal'::regclass)
 and exists(select 1 from pg_publication where pubname='supabase_realtime' and pubupdate)
 and exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='workflow_notification_signal')
 and not exists (
   select 1 from unnest(array['jobs','job_work_orders','job_work_order_steps','job_part_requests','lab_part_return_requests']) source
   where not exists(select 1 from pg_trigger t where t.tgrelid=('public.'||source)::regclass
     and t.tgname='greenloop_workflow_signal' and t.tgenabled='O'
     and t.tgfoid='greenloop_private.signal_workflow_change()'::regprocedure and t.tgtype=29 and t.tgdeferrable and t.tginitdeferred)
   or not exists(select 1 from pg_trigger t where t.tgrelid=('public.'||source)::regclass
     and t.tgname='greenloop_workflow_signal_truncate' and t.tgenabled='O'
     and t.tgfoid='greenloop_private.signal_workflow_change()'::regprocedure and t.tgtype=32)
 ) then '20261017-workflow-live-notifications-1' end;
$$;
revoke all on function public.get_workflow_live_notifications_version() from public;
grant execute on function public.get_workflow_live_notifications_version() to anon,authenticated;
do $$ begin
 if public.get_workflow_live_notifications_version() is distinct from '20261017-workflow-live-notifications-1' then
  raise exception 'Workflow live notification verification failed. Nothing installed.';
 end if;
end; $$;
notify pgrst,'reload schema';
commit;
select public.get_workflow_live_notifications_version() as installed_workflow_live_notifications_version;
