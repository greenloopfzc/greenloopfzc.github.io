-- Label only unattributed B-DEPT pass activity as B-Dept in the Technician Work Report.
begin;
set local lock_timeout='5s';

do $install$
declare
  source_oid regprocedure:=to_regprocedure('public.get_technician_work_report_v3(date,date,integer,boolean,text,text,boolean,boolean,text)');
  ddl text;
  change record;
begin
  if to_regprocedure('public.get_technician_work_bdept_version()') is not null then
    if public.get_technician_work_bdept_version() is distinct from '20261123-technician-work-bdept-1' then
      raise exception 'Existing Technician Work B-Dept label could not be verified.';
    end if;
    return;
  end if;
  if source_oid is null
      or public.get_technician_work_matrix_version() is distinct from '20261123-technician-work-matrix-1' then
    raise exception 'Install the verified Technician Work Report matrix first.';
  end if;

  ddl:=replace(pg_get_functiondef(source_oid),chr(13),'');
  for change in select * from (values
    ('FUNCTION public.get_technician_work_report_v3(', 'FUNCTION public.get_technician_work_report_v4('),
    ($old$select 'job',b.job_id,b.work_order_step_id,b.reviewed_at,null,0$old$,
     $new$select 'frame_job',b.job_id,b.work_order_step_id,b.reviewed_at,null,0$new$),
    ($old$    select a.job_id,a.kind,a.quantity,
      coalesce(p.employee_id::text,'legacy:'||greenloop_private.ed_key(p.employee_name),'unrecorded') employee_key,
      coalesce(r.full_name,p.employee_name,'Technician not recorded') employee_name,$old$,
     $new$    select a.job_id,case when a.kind='frame_job' then 'job' else a.kind end kind,a.quantity,
      case when label.unnamed_bdept then 'unrecorded:b_dept'
        else coalesce(p.employee_id::text,'legacy:'||greenloop_private.ed_key(p.employee_name),'unrecorded') end employee_key,
      case when label.unnamed_bdept then 'B-Dept'
        else coalesce(r.full_name,p.employee_name,'Technician not recorded') end employee_name,$new$),
    ($old$    left join public.technician_roster r on r.id=p.employee_id
  ), employees as ($old$,
     $new$    left join public.technician_roster r on r.id=p.employee_id
    cross join lateral (
      select a.kind='frame_job' and p.employee_id is null and p.employee_name is null unnamed_bdept
    ) label
  ), employees as ($new$)
  ) edits(before_text,after_text) loop
    change.before_text:=replace(change.before_text,chr(13),'');
    change.after_text:=replace(change.after_text,chr(13),'');
    if cardinality(string_to_array(ddl,change.before_text)) is distinct from 2 then
      raise exception 'Technician Work B-Dept label source differs at %',left(change.before_text,80);
    end if;
    ddl:=replace(ddl,change.before_text,change.after_text);
  end loop;
  execute ddl;
end;
$install$;

revoke all on function public.get_technician_work_report_v4(date,date,integer,boolean,text,text,boolean,boolean,text)
from public,anon,authenticated;
grant execute on function public.get_technician_work_report_v4(date,date,integer,boolean,text,text,boolean,boolean,text)
to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_technician_work_report_v4','{"page":"reports","capability":"report_technician_work","read":true}'),
  ('get_technician_work_bdept_version','{"read":true}')
on conflict(rpc_name) do nothing;

update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.technician_work_bdept_installation (identity text primary key, hash text not null);
alter table greenloop_private.technician_work_bdept_installation enable row level security;
revoke all on greenloop_private.technician_work_bdept_installation from public,anon,authenticated;
insert into greenloop_private.technician_work_bdept_installation
select identity,md5(pg_get_functiondef(identity::regprocedure))
from (values ('public.get_technician_work_report_v4(date,date,integer,boolean,text,text,boolean,boolean,text)')) s(identity)
on conflict(identity) do nothing;

create or replace function public.get_technician_work_bdept_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
    select 1 from greenloop_private.technician_work_bdept_installation
    where identity='public.get_technician_work_report_v4(date,date,integer,boolean,text,text,boolean,boolean,text)'
      and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and has_function_privilege('authenticated',identity,'EXECUTE')
      and not has_function_privilege('anon',identity,'EXECUTE')
  ) and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_technician_work_report_v4'
    and rule='{"page":"reports","capability":"report_technician_work","read":true}'::jsonb)
  then '20261123-technician-work-bdept-1' end;
$version$;
revoke all on function public.get_technician_work_bdept_version() from public;
grant execute on function public.get_technician_work_bdept_version() to anon,authenticated;

do $verify$
begin
  if public.get_technician_work_bdept_version() is distinct from '20261123-technician-work-bdept-1' then
    raise exception 'Technician Work B-Dept label could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_technician_work_bdept_version() as installed_technician_work_bdept_version;