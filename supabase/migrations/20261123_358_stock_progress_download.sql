-- Export the same stock-progress totals and model/GB rows shown in Reports.
begin;
set local lock_timeout='5s';

do $install$
declare
  source_oid regprocedure:=to_regprocedure('public.get_company_stock_progress_v1(uuid,uuid,text,integer)');
  ddl text;
  edit record;
begin
  if to_regprocedure('public.get_company_stock_progress_download_version()') is not null then
    if public.get_company_stock_progress_download_version() is distinct from '20261123-stock-progress-download-1' then
      raise exception 'Existing Stock Progress downloads could not be verified.';
    end if;
    return;
  end if;
  if source_oid is null or public.get_company_stock_progress_version() is distinct from '20261120-company-stock-progress-1' then
    raise exception 'Install the verified Stock Progress report first.';
  end if;
  ddl:=replace(pg_get_functiondef(source_oid),chr(13),'');
  if strpos(ddl,'count(*) filter (where ready) ready_total')=0 then
    raise exception 'Install the verified Ready Stock until export update first.';
  end if;
  for edit in select * from (values
    ('FUNCTION public.get_company_stock_progress_v1(', 'FUNCTION public.get_company_stock_progress_v2('),
    ('p_offset integer DEFAULT 0)', 'p_offset integer DEFAULT 0, p_export boolean DEFAULT false, p_expected text DEFAULT NULL::text)'),
    ('declare result jsonb;', 'declare result jsonb; rows_digest text; scope_snapshot text;'),
    ($old$  with latest_jobs as materialized ($old$,
     $new$  if p_export is null or (p_export and (p_offset<>0 or p_expected is null or p_expected!~'^[0-9a-f]{32}$')) then
    raise exception 'Choose a valid Stock Progress download selection.' using errcode='22023';
  end if;
  if p_export then
    perform greenloop_private.pf_cap('reports','stock_progress_download');
  end if;
  with latest_jobs as materialized ($new$),
    ($old$  ), page as (
    select * from grouped order by lower(model), storage_gb nulls last, model
    offset p_offset limit 50
  )$old$,
     $new$  ), page as (
    select * from grouped order by lower(model), storage_gb nulls last, model
    offset p_offset limit (case when p_export then null else 50 end)
  )$new$),
    ($old$    'offset', p_offset, 'row_count', (select count(*) from grouped),$old$,
     $new$    'offset', p_offset, 'row_count', (select count(*) from grouped),
    'filters', jsonb_build_object('supplier',p_supplier_id,'batch',p_batch_id,'invoice',p_invoice),
    'export',p_export,$new$),
    ($old$  ) into result;
  return result;$old$,
     $new$  ), (select md5(coalesce(string_agg(md5(to_jsonb(g)::text),'' order by lower(model),storage_gb nulls last,model),''))
      from grouped g) into result,rows_digest;
  scope_snapshot:=md5(jsonb_build_array(result->'filters',(
    select coalesce(jsonb_agg(r.value order by r.ordinality),'[]'::jsonb)
    from jsonb_array_elements(result->'receipts') with ordinality r(value,ordinality)
    where (p_supplier_id is null or r.value->>'supplier_id'=p_supplier_id::text)
      and (p_batch_id is null or r.value->>'batch_id'=p_batch_id::text)
      and (p_invoice is null or r.value->>'invoice_number'=p_invoice)
  ),rows_digest)::text);
  if p_export and scope_snapshot is distinct from p_expected then
    raise exception 'Stock Progress changed. Refresh the table and download again.' using errcode='40001';
  end if;
  return result||jsonb_build_object('snapshot',scope_snapshot);$new$)
  ) changes(before_text,after_text) loop
    edit.before_text:=replace(edit.before_text,chr(13),'');
    edit.after_text:=replace(edit.after_text,chr(13),'');
    if cardinality(string_to_array(ddl,edit.before_text)) is distinct from 2 then
      raise exception 'Stock Progress source differs at %',left(edit.before_text,70);
    end if;
    ddl:=replace(ddl,edit.before_text,edit.after_text);
  end loop;
  execute ddl;
end;
$install$;

revoke all on function public.get_company_stock_progress_v2(uuid,uuid,text,integer,boolean,text) from public,anon,authenticated;
grant execute on function public.get_company_stock_progress_v2(uuid,uuid,text,integer,boolean,text) to authenticated;

do $access$
begin
  if not exists (select 1 from greenloop_private.page_capability_catalog
    where page_key='reports' and capabilities @> '[{"key":"stock_progress_download"}]') then
    update greenloop_private.page_capability_catalog
    set capabilities=capabilities||'[{"key":"stock_progress_download","label":"Stock Progress: Download PDF and Excel","write":false}]'
    where page_key='reports';
    update greenloop_private.user_page_capabilities u
    set capabilities=jsonb_set(u.capabilities,'{reports}',(u.capabilities->'reports')||'["stock_progress_download"]')
    where u.capabilities->'reports'?'report_supplier_progress'
      and exists (select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
        where ur.user_id=u.user_id and r.role_key::text in ('owner','super_admin'));
  end if;
end;
$access$;

update greenloop_private.report_access_sections
set config=jsonb_set(config,'{actions}',(config->'actions')||'["stock_progress_download"]'::jsonb)
where report_key='supplier_progress' and not (config->'actions'?'stock_progress_download');
insert into greenloop_private.report_access_dependencies(capability,required_views)
values ('stock_progress_download','"report_supplier_progress"') on conflict(capability) do nothing;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_company_stock_progress_v2','{"page":"reports","capability":"report_supplier_progress","read":true}'),
  ('get_company_stock_progress_download_version','{"read":true}')
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

create table if not exists greenloop_private.stock_progress_download_installation (identity text primary key,hash text not null);
alter table greenloop_private.stock_progress_download_installation enable row level security;
revoke all on greenloop_private.stock_progress_download_installation from public,anon,authenticated;
insert into greenloop_private.stock_progress_download_installation
select identity,md5(pg_get_functiondef(identity::regprocedure))
from (values ('public.get_company_stock_progress_v2(uuid,uuid,text,integer,boolean,text)')) signatures(identity)
on conflict(identity) do nothing;

create or replace function public.get_company_stock_progress_download_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when exists (
    select 1 from greenloop_private.stock_progress_download_installation
    where identity='public.get_company_stock_progress_v2(uuid,uuid,text,integer,boolean,text)'
      and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and has_function_privilege('authenticated',identity,'EXECUTE')
      and not has_function_privilege('anon',identity,'EXECUTE')
  ) and exists (select 1 from greenloop_private.report_access_sections
    where report_key='supplier_progress' and config->'actions'?'stock_progress_download')
  and exists (select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_company_stock_progress_v2'
    and rule='{"page":"reports","capability":"report_supplier_progress","read":true}'::jsonb)
  then '20261123-stock-progress-download-1' end;
$version$;
revoke all on function public.get_company_stock_progress_download_version() from public;
grant execute on function public.get_company_stock_progress_download_version() to anon,authenticated;

do $verify$
begin
  if public.get_company_stock_progress_download_version() is distinct from '20261123-stock-progress-download-1' then
    raise exception 'Stock Progress downloads could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_company_stock_progress_download_version() as installed_stock_progress_download_version;