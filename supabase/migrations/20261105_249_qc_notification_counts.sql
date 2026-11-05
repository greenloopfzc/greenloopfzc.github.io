-- Separate unsaved QC work from saved inspections awaiting Issuance.
-- Read-only business query: no jobs, inspections or issuance receipts change.
begin;
do $$begin
 if public.get_qc_issuance_version() is distinct from '20261104-qc-inspection-issuance-1' then
  raise exception 'Install verified QC Inspection / Issuance first.';
 end if;
end;$$;

create or replace function greenloop_private.qcn_counts() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.qcis_require();
 return jsonb_build_object(
  'initial_qc',(select count(*) from public.jobs j
   join public.devices d on d.id=j.device_id and d.deleted_at is null
   where j.deleted_at is null and j.current_status='initial_qc_pending'
   and not exists(select 1 from greenloop_private.qc_saved_issuance s
    where s.job_id=j.id and s.state='awaiting_issuance')),
  'qc_issuance',(select count(*) from greenloop_private.qc_saved_issuance s
   join public.initial_qc_inspections i on i.id=s.inspection_id and i.job_id=s.job_id
   join public.jobs j on j.id=s.job_id and j.deleted_at is null and j.current_status='initial_qc_pending'
   join public.devices d on d.id=s.device_id and d.deleted_at is null
   where s.state='awaiting_issuance')
 );
end;$$;
revoke all on function greenloop_private.qcn_counts() from public,anon,authenticated;

create or replace function public.get_qc_stage_notification_counts_v1() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();
 return greenloop_private.qcn_counts();
end;$$;
revoke all on function public.get_qc_stage_notification_counts_v1() from public,anon,authenticated;
grant execute on function public.get_qc_stage_notification_counts_v1() to authenticated;
insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)
values('public.get_qc_stage_notification_counts_v1()','greenloop_private.qcn_counts()',
 md5(pg_get_functiondef('greenloop_private.qcn_counts()'::regprocedure)),
 md5(pg_get_functiondef('public.get_qc_stage_notification_counts_v1()'::regprocedure)))
on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule)
values('get_qc_stage_notification_counts_v1','{"page":"initial_qc","capability":"view","read":true}'),
 ('get_qc_notification_counts_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.qc_notification_installation(identity text primary key,hash text not null);
alter table greenloop_private.qc_notification_installation enable row level security;
revoke all on greenloop_private.qc_notification_installation from public,anon,authenticated;
insert into greenloop_private.qc_notification_installation
select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array['greenloop_private.qcn_counts()','public.get_qc_stage_notification_counts_v1()']) signature
on conflict(identity) do update set hash=excluded.hash;

create or replace function public.get_qc_notification_counts_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_issuance_version()='20261104-qc-inspection-issuance-1'
 and (select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.qc_notification_installation)
 and has_function_privilege('authenticated','public.get_qc_stage_notification_counts_v1()','EXECUTE')
 and not has_function_privilege('anon','public.get_qc_stage_notification_counts_v1()','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.qcn_counts()','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.qcn_counts()','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.qc_notification_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.qc_notification_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_qc_stage_notification_counts_v1'
  and rule='{"page":"initial_qc","capability":"view","read":true}'::jsonb)
 then '20261105-qc-notification-counts-1' end;
$$;
revoke all on function public.get_qc_notification_counts_version() from public;
grant execute on function public.get_qc_notification_counts_version() to anon,authenticated;
do $$begin
 if public.get_qc_notification_counts_version() is distinct from '20261105-qc-notification-counts-1' then
  raise exception 'Separate QC notification counts could not be verified. Nothing installed.';
 end if;
end;$$;
notify pgrst,'reload schema';
commit;
select public.get_qc_notification_counts_version() as installed_qc_notification_counts_version;
