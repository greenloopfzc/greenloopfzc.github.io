-- Reuse the verified technician work source and page the summary by completed jobs.
begin;
set local lock_timeout='5s';

do $summary$
declare
  source_oid regprocedure:='public.get_technician_work_report_v1(date,date,integer)'::regprocedure;
  ddl text:=pg_get_functiondef(source_oid);
  change record;
begin
  if to_regprocedure('public.get_technician_work_summary_version()') is not null then
    if public.get_technician_work_summary_version() is distinct from '20261123-technician-work-summary-1' then
      raise exception 'Existing Technician Work Summary could not be verified.';
    end if;
    return;
  end if;
  if not exists (
    select 1 from greenloop_private.technician_work_report_installation
    where to_regprocedure(identity)=source_oid and hash=md5(ddl)
  ) then raise exception 'The existing Technician Work Report definition differs.';end if;

  ddl:=replace(ddl,chr(13),'');
  for change in select * from (values
    ('FUNCTION public.get_technician_work_report_v1(', 'FUNCTION public.get_technician_work_report_v2('),
    ('p_offset integer DEFAULT 0)', 'p_offset integer DEFAULT 0, p_include_zero boolean DEFAULT false)'),
    ('or p_offset is null or', 'or p_include_zero is null or p_offset is null or'),
    ('), page as (', '), matching as ('),
    ($old$order by lower(e.name),e.employee_key offset p_offset limit 50$old$,
     $new$where p_include_zero or c.quantity>0 or b.parts is not null or b.services is not null
  ), page as (
    select * from matching order by completed_jobs desc,lower(name),employee_key offset p_offset limit 50$new$),
    ($old$'total',(select count(*) from employees),$old$,
     $new$'total',(select count(*) from matching),'include_zero',p_include_zero,$new$),
    ('order by lower(p.name),p.employee_key', 'order by p.completed_jobs desc,lower(p.name),p.employee_key')
  ) edits(before_text,after_text) loop
    if cardinality(string_to_array(ddl,change.before_text)) is distinct from 2 then
      raise exception 'Technician Work Summary source differs at %',left(change.before_text,80);
    end if;
    ddl:=replace(ddl,change.before_text,change.after_text);
  end loop;
  execute ddl;
end;
$summary$;
revoke all on function public.get_technician_work_report_v2(date,date,integer,boolean) from public,anon,authenticated;
grant execute on function public.get_technician_work_report_v2(date,date,integer,boolean) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_technician_work_report_v2','{"page":"reports","capability":"report_technician_work","read":true}'),
  ('get_technician_work_summary_version','{"read":true}')
on conflict(rpc_name) do nothing;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.technician_work_summary_installation (
  identity text primary key,
  hash text not null
);
alter table greenloop_private.technician_work_summary_installation enable row level security;
revoke all on greenloop_private.technician_work_summary_installation from public,anon,authenticated;
insert into greenloop_private.technician_work_summary_installation
select identity,md5(pg_get_functiondef(identity::regprocedure))
from (values('public.get_technician_work_report_v2(date,date,integer,boolean)')) s(identity)
on conflict(identity) do nothing;

create or replace function public.get_technician_work_summary_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
    select 1 from greenloop_private.technician_work_summary_installation
    where identity='public.get_technician_work_report_v2(date,date,integer,boolean)'
      and hash=md5(pg_get_functiondef(identity::regprocedure))
  ) and has_function_privilege('authenticated','public.get_technician_work_report_v2(date,date,integer,boolean)','EXECUTE')
    and not has_function_privilege('anon','public.get_technician_work_report_v2(date,date,integer,boolean)','EXECUTE')
    and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_technician_work_report_v2'
         and rule='{"page":"reports","capability":"report_technician_work","read":true}'::jsonb)
  then '20261123-technician-work-summary-1' end;
$version$;
revoke all on function public.get_technician_work_summary_version() from public;
grant execute on function public.get_technician_work_summary_version() to anon,authenticated;
do $verify$
begin
  if public.get_technician_work_summary_version() is distinct from '20261123-technician-work-summary-1' then
    raise exception 'Technician Work Summary could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_technician_work_summary_version() as installed_technician_work_summary_version;
