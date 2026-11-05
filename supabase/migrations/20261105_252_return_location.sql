-- A completed supplier return has left the workshop. Keep its current location
-- consistent without changing the return date, supplier, quantities or history.
begin;
do $$begin
 if public.get_journey_status_version()is distinct from '20261105-journey-status-1'then
  raise exception 'Install verified Journey Status first.';
 end if;
end;$$;
insert into public.locations(location_code,location_name,location_type,notes)
values('RETURNED-TO-SUPPLIER','Returned to Supplier','other','Completed physical supplier returns; not an active workshop location.')
on conflict(location_code)do update set location_name=excluded.location_name;
-- Legacy Laboratory / Glass location IDs may be distinct and have unique
-- names. Keep those identities for history; normalize their display below.

create or replace function greenloop_private.jrl_location(p_status text,p_location text)returns text
language sql immutable set search_path=pg_catalog,public as $$
 select case when p_status='returned_to_supplier'then 'Returned to Supplier'
 when lower(btrim(p_location))in('laboratory','lab','glass','lab_glass','lab-glass','laboratory & glass')then 'Lab & Glass'
 else p_location end;
$$;
revoke all on function greenloop_private.jrl_location(text,text)from public,anon,authenticated;

-- This trigger does not authorize a return. Existing status/return guards and
-- permissions still run. Both legacy handover and one-step return APIs update
-- the status, so both receive the same canonical location atomically.
create or replace function greenloop_private.jrl_return_location()returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if new.current_status::text='returned_to_supplier'then
  select id into new.current_location_id from public.locations where location_code='RETURNED-TO-SUPPLIER';
  if new.current_location_id is null then raise exception 'Returned to Supplier location is not configured.';end if;
 end if;
 return new;
end;$$;
revoke all on function greenloop_private.jrl_return_location()from public,anon,authenticated;
drop trigger if exists zz_return_current_location on public.jobs;
create trigger zz_return_current_location before update of current_status,current_location_id on public.jobs
for each row execute function greenloop_private.jrl_return_location();
drop trigger if exists zz_return_current_location on public.devices;
create trigger zz_return_current_location before update of current_status,current_location_id on public.devices
for each row execute function greenloop_private.jrl_return_location();

create table if not exists greenloop_private.return_location_repairs(
 return_id uuid primary key,device_id uuid not null,job_id uuid not null,
 old_job_location uuid,old_device_location uuid,new_location uuid not null,
 handed_over_at timestamptz not null,repaired_at timestamptz not null default now()
);
alter table greenloop_private.return_location_repairs enable row level security;
revoke all on greenloop_private.return_location_repairs from public,anon,authenticated;

-- Repair only completed, current returns. Never move a requested/approved,
-- cancelled/rejected/archived return, or a phone received again on a later job.
do $repair$declare r record;loc uuid;begin
 select id into loc from public.locations where location_code='RETURNED-TO-SUPPLIER';
 for r in select sr.id,sr.device_id,sr.job_id,sr.handed_over_at,
 j.current_location_id job_location,d.current_location_id device_location
 from public.supplier_returns sr join public.jobs j on j.id=sr.job_id join public.devices d on d.id=sr.device_id
 where sr.archived_at is null and sr.status='returned'and sr.handed_over_at is not null
 and j.deleted_at is null and d.deleted_at is null
 and j.current_status::text='returned_to_supplier'and d.current_status::text='returned_to_supplier'
 and j.id=(select jj.id from public.jobs jj where jj.device_id=d.id and jj.deleted_at is null order by jj.received_at desc nulls last,jj.created_at desc,jj.id limit 1)
 and(j.current_location_id is distinct from loc or d.current_location_id is distinct from loc)
 order by j.id for update of j,d,sr loop
  insert into greenloop_private.return_location_repairs(return_id,device_id,job_id,old_job_location,old_device_location,new_location,handed_over_at)
  values(r.id,r.device_id,r.job_id,r.job_location,r.device_location,loc,r.handed_over_at)on conflict(return_id)do nothing;
  -- Use the existing private return scope only for these two location fields.
  insert into greenloop_private.supplier_return_capabilities(transaction_id,backend_pid,return_id)
  values(txid_current(),pg_backend_pid(),r.id)on conflict do nothing;
  update public.jobs set current_location_id=loc where id=r.job_id and current_status::text='returned_to_supplier'and current_location_id is distinct from loc;
  update public.devices set current_location_id=loc where id=r.device_id and current_status::text='returned_to_supplier'and current_location_id is distinct from loc;
  delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id=r.id;
 end loop;
end;$repair$;

-- Current return status takes precedence over a stale last workshop pointer.
-- The parent reader still performs Office and page permission checks.
do $readers$declare id regprocedure;ddl text;t record;needle text;replacement text;begin
 for id in select unnest(array['greenloop_private.jst_history(jsonb)'::regprocedure,'greenloop_private.jst_stage(text,uuid,uuid)'::regprocedure])loop
  ddl:=pg_get_functiondef(id);
  if id='greenloop_private.jst_history(jsonb)'::regprocedure then
   needle:='loc:=data->''device''->>''current_location'';';replacement:='loc:=greenloop_private.jrl_location(status,data->''device''->>''current_location'');';
  else
   needle:='when p_status in(''qc_passed''';
   replacement:='when p_status=''returned_to_supplier''then ''Returned to Supplier'''||chr(10)||
    ' when p_status=''supplier_return_requested''then ''Stock Return - Requested'''||chr(10)||
    ' when p_status=''return_pending''then ''Stock Return - Pending'''||chr(10)||' when p_status in(''qc_passed''';
  end if;
  if strpos(ddl,replacement)=0 then
   if strpos(ddl,needle)=0 then raise exception 'Reviewed current-location boundary differs. Nothing changed.';end if;
   execute replace(ddl,needle,replacement);
  end if;
  for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name
  where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
   execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1))where to_regprocedure(%I)=$1',t.table_name,t.hash_col,t.id_col)using id;
  end loop;
 end loop;
end;$readers$;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values('get_return_location_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.return_location_installation(identity text primary key,hash text not null);
alter table greenloop_private.return_location_installation enable row level security;
revoke all on greenloop_private.return_location_installation from public,anon,authenticated;
insert into greenloop_private.return_location_installation select signature,md5(pg_get_functiondef(signature::regprocedure))from unnest(array[
 'greenloop_private.jrl_location(text,text)','greenloop_private.jrl_return_location()',
 'greenloop_private.jst_history(jsonb)','greenloop_private.jst_stage(text,uuid,uuid)'])signature
on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.return_location_installation
select t.tgrelid::regclass::text||':'||t.tgname,md5(pg_get_triggerdef(t.oid))from pg_trigger t
where t.tgname='zz_return_current_location'and t.tgrelid in('public.jobs'::regclass,'public.devices'::regclass)
on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_return_location_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_journey_status_version()='20261105-journey-status-1'
 and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.return_location_installation where identity not like '%:zz_return_current_location')
 and(select count(*)=2 and bool_and(t.tgenabled='O'and i.hash=md5(pg_get_triggerdef(t.oid)))from pg_trigger t join greenloop_private.return_location_installation i on i.identity=t.tgrelid::regclass::text||':'||t.tgname where t.tgname='zz_return_current_location'and t.tgrelid in('public.jobs'::regclass,'public.devices'::regclass))
 and not exists(select 1 from greenloop_private.return_location_installation where identity not like '%:zz_return_current_location'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 and exists(select 1 from public.locations where location_code='RETURNED-TO-SUPPLIER'and location_name='Returned to Supplier')
 and not exists(select 1 from pg_class c where c.oid in('greenloop_private.return_location_repairs'::regclass,'greenloop_private.return_location_installation'::regclass)and(not c.relrowsecurity or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 then '20261105-return-location-1'end;
$$;
revoke all on function public.get_return_location_version()from public;grant execute on function public.get_return_location_version()to anon,authenticated;
do $$begin if public.get_return_location_version()is distinct from '20261105-return-location-1'then raise exception 'Return location verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_return_location_version()as installed_return_location_version;
