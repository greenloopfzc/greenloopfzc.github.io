-- Extend the installed technician work reader with item columns, global sorting and full exports.
begin;
set local lock_timeout='5s';

do $install$
declare
  source_oid regprocedure:=to_regprocedure('public.get_technician_work_report_v2(date,date,integer,boolean)');
  ddl text;
  change record;
begin
  if to_regprocedure('public.get_technician_work_matrix_version()') is not null then
    if public.get_technician_work_matrix_version() is distinct from '20261123-technician-work-matrix-1' then
      raise exception 'Existing Technician Work update could not be verified.';
    end if;
    return;
  end if;
  if source_oid is null or public.get_technician_work_summary_version() is distinct from '20261123-technician-work-summary-1' then
    raise exception 'Install the verified Technician Work Summary first.';
  end if;

  ddl:=replace(pg_get_functiondef(source_oid),chr(13),'');
  for change in select * from (values
    ('FUNCTION public.get_technician_work_report_v2(', 'FUNCTION public.get_technician_work_report_v3(',2),
    ('p_include_zero boolean DEFAULT false)', $new$p_include_zero boolean DEFAULT false,
      p_sort text DEFAULT 'jobs', p_item text DEFAULT NULL::text, p_desc boolean DEFAULT true,
      p_export boolean DEFAULT false, p_expected text DEFAULT NULL::text)$new$,2),
    ($old$  from_at:=from_day::timestamp at time zone 'Asia/Dubai';$old$,
     $new$  if p_sort is null or p_sort not in ('name','jobs','part','service')
     or p_desc is null or p_export is null
     or (p_sort in ('part','service'))<>(nullif(p_item,'') is not null)
     or (p_export and (p_offset<>0 or p_expected is null or p_expected!~'^[0-9a-f]{32}$')) then
    raise exception 'Choose a valid report sort and export selection.' using errcode='22023';
  end if;
  if p_sort<>'jobs' or not p_desc then
    perform greenloop_private.rp_require('technician_work','sort');
  end if;
  if p_export then
    perform greenloop_private.rp_require('technician_work','download');
  end if;
  from_at:=from_day::timestamp at time zone 'Asia/Dubai';$new$,2),
    ($old$select employee_key,kind,min(item) item,sum(quantity)::bigint quantity$old$,
     $new$select employee_key,kind,greenloop_private.pp_key(item) item_key,min(item) item,sum(quantity)::bigint quantity$new$,2),
    ($old$jsonb_build_object('name',item,'quantity',quantity)$old$,
     $new$jsonb_build_object('key',item_key,'quantity',quantity)$new$, 3),
    ($old$    where p_include_zero or c.quantity>0 or b.parts is not null or b.services is not null
  ), page as (
    select * from matching order by completed_jobs desc,lower(name),employee_key offset p_offset limit 50
  )$old$,
     $new$    where p_include_zero or c.quantity>0 or b.parts is not null or b.services is not null
  ), catalogue as (
    select kind,item_key,min(item) label from items group by kind,item_key
  ), columns as (
    select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'key',item_key,'label',label)
      order by kind,lower(label),label,item_key),'[]'::jsonb) as value from catalogue
  ), ranked as materialized (
    select m.*, row_number() over (order by
      case when p_sort='name' and p_desc then lower(m.name) end desc,
      case when p_sort='jobs' and p_desc then m.completed_jobs end desc,
      case when p_sort in ('part','service') and p_desc then coalesce(i.quantity,0) end desc,
      case when p_sort='jobs' and not p_desc then m.completed_jobs end,
      case when p_sort in ('part','service') and not p_desc then coalesce(i.quantity,0) end,
      lower(m.name),m.employee_key) position
    from matching m
    left join items i on i.employee_key=m.employee_key and i.kind=p_sort and i.item_key=p_item
  ), scope as (
    select count(*) total,md5(jsonb_build_array(from_day,to_day,p_sort,p_item,p_desc,p_include_zero,
      (select value from columns),string_agg(md5(to_jsonb(r)::text),'' order by position))::text) snapshot
    from ranked r
  ), page as (
    select * from ranked
    where p_export or (position>p_offset and position<=p_offset::bigint+50)
  )$new$,2),
    ($old$'total',(select count(*) from matching),'include_zero',p_include_zero,$old$,
     $new$'total',(select total from scope),'snapshot',(select snapshot from scope),
    'columns',(select value from columns),'include_zero',p_include_zero,
    'sort',p_sort,'item',p_item,'desc',p_desc,'export',p_export,$new$,2),
    ($old$jsonb_agg(to_jsonb(p) order by p.completed_jobs desc,lower(p.name),p.employee_key)$old$,
     $new$jsonb_agg(to_jsonb(p)-'position' order by position)$new$,2),
    ($old$  return result;$old$,
     $new$  if p_export and result->>'snapshot' is distinct from p_expected then
    raise exception 'The technician work report changed. Refresh it and download again.' using errcode='40001';
  end if;
  return result;$new$,2)
  ) edits(before_text,after_text,expected) loop
    change.before_text:=replace(change.before_text,chr(13),'');
    change.after_text:=replace(change.after_text,chr(13),'');
    if cardinality(string_to_array(ddl,change.before_text)) is distinct from change.expected then
      raise exception 'Technician Work source differs at %',left(change.before_text,80);
    end if;
    ddl:=replace(ddl,change.before_text,change.after_text);
  end loop;
  execute ddl;
end;
$install$;

revoke all on function public.get_technician_work_report_v3(date,date,integer,boolean,text,text,boolean,boolean,text) from public,anon,authenticated;
grant execute on function public.get_technician_work_report_v3(date,date,integer,boolean,text,text,boolean,boolean,text) to authenticated;

do $access$
begin
  if not exists (select 1 from greenloop_private.page_capability_catalog
    where page_key='reports' and capabilities @> '[{"key":"report_technician_work_download"}]') then
    update greenloop_private.page_capability_catalog set capabilities=capabilities||'[
      {"key":"report_technician_work_sort","label":"Technician Work Report: Sort table headings","write":false},
      {"key":"report_technician_work_download","label":"Technician Work Report: PDF View / Download and Excel","write":false}]'
    where page_key='reports';
    update greenloop_private.user_page_capabilities u
    set capabilities=jsonb_set(u.capabilities,'{reports}',(u.capabilities->'reports')||
      '["report_technician_work_sort","report_technician_work_download"]'::jsonb)
    where u.capabilities->'reports'?'report_technician_work'
      and exists (select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
        where ur.user_id=u.user_id and r.role_key::text in ('owner','super_admin'));
  end if;
end;
$access$;

update greenloop_private.report_access_sections set config=config||'{
  "actions":["report_technician_work_search","report_technician_work_sort","report_technician_work_download"],
  "sort":"report_technician_work_sort","download":"report_technician_work_download"}'::jsonb
where report_key='technician_work';

insert into greenloop_private.report_access_dependencies(capability,required_views) values
  ('report_technician_work_sort','"report_technician_work"'),
  ('report_technician_work_download','"report_technician_work"')
on conflict(capability) do nothing;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_technician_work_report_v3','{"page":"reports","capability":"report_technician_work","read":true}'),
  ('get_technician_work_matrix_version','{"read":true}')
on conflict(rpc_name) do nothing;

update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
where identity='catalog';
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';
update greenloop_private.report_access_config_seal
set sections_hash=(select md5(jsonb_agg(to_jsonb(s) order by report_key)::text) from greenloop_private.report_access_sections s),
    dependencies_hash=(select md5(jsonb_agg(to_jsonb(d) order by capability)::text) from greenloop_private.report_access_dependencies d)
where singleton;

create table if not exists greenloop_private.technician_work_matrix_installation (identity text primary key, hash text not null);
alter table greenloop_private.technician_work_matrix_installation enable row level security;
revoke all on greenloop_private.technician_work_matrix_installation from public,anon,authenticated;
insert into greenloop_private.technician_work_matrix_installation
select identity,md5(pg_get_functiondef(identity::regprocedure))
from (values ('public.get_technician_work_report_v3(date,date,integer,boolean,text,text,boolean,boolean,text)')) s(identity)
on conflict(identity) do nothing;

create or replace function public.get_technician_work_matrix_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
    select 1 from greenloop_private.technician_work_matrix_installation
    where identity='public.get_technician_work_report_v3(date,date,integer,boolean,text,text,boolean,boolean,text)'
      and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and has_function_privilege('authenticated',identity,'EXECUTE')
      and not has_function_privilege('anon',identity,'EXECUTE')
  ) and exists (select 1 from greenloop_private.report_access_sections where report_key='technician_work'
    and config->>'sort'='report_technician_work_sort' and config->>'download'='report_technician_work_download')
  and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_technician_work_report_v3'
    and rule='{"page":"reports","capability":"report_technician_work","read":true}'::jsonb)
  then '20261123-technician-work-matrix-1' end;
$version$;
revoke all on function public.get_technician_work_matrix_version() from public;
grant execute on function public.get_technician_work_matrix_version() to anon,authenticated;

do $verify$
begin
  if public.get_technician_work_matrix_version() is distinct from '20261123-technician-work-matrix-1' then
    raise exception 'Technician Work update could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_technician_work_matrix_version() as installed_technician_work_matrix_version;