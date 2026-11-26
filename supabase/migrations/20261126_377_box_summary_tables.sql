-- Summarise the saved contents of each box by phone specification.
begin;
set local lock_timeout = '5s';

create or replace function public.get_box_data_table_v2(
  p_page text, p_from date default null, p_to date default null,
  p_search text default '', p_offset integer default 0, p_limit integer default 50
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public as $report$
declare
  search_text text := btrim(coalesce(p_search, ''));
  search_pattern text;
  result jsonb;
begin
  perform greenloop_private.require_office_network();
  if p_page is null or p_page not in ('accounts','stock_exported')
    or auth.uid() is null or not coalesce(public.is_active_staff(),false)
    or greenloop_private.damage_tv_only(auth.uid())
    or not coalesce(public.has_page_capability_v1(p_page,'view'),false) then
    raise exception 'Box page view permission required.' using errcode = '42501';
  end if;
  if (p_from is not null or p_to is not null or search_text <> '')
    and not coalesce(public.has_page_capability_v1(p_page,'search'),false) then
    raise exception 'Box page Search permission required.' using errcode = '42501';
  end if;
  if p_from > p_to
    or (p_from is not null and (p_from < date '1900-01-01' or p_from >= date '9999-12-31'))
    or (p_to is not null and (p_to < date '1900-01-01' or p_to >= date '9999-12-31'))
    or length(search_text) > 120 or p_offset is null or p_offset < 0
    or p_limit is null or p_limit not between 1 and 50 then
    raise exception 'Choose valid dates, search text and page.' using errcode = '22023';
  end if;
  search_pattern := '%' || replace(replace(replace(search_text, '!', '!!'), '%', '!%'), '_', '!_') || '%';

  with dated_boxes as (
    select box.id, box.box_number, workflow.state,
      case when p_page = 'stock_exported'
        then coalesce(workflow.verified_at, workflow.saved_at, box.closed_at, box.opened_at)
        else coalesce(workflow.saved_at, box.closed_at, box.opened_at)
      end as box_date
    from public.export_boxes box
    join greenloop_private.box_workflow workflow on workflow.box_id = box.id
    where (p_page = 'accounts' and workflow.state = 'accounts')
       or (p_page = 'stock_exported' and workflow.state in ('exported','legacy'))
  ), grouped as materialized (
    select box.id as box_id, box.box_number, box.state, box.box_date,
      min(nullif(btrim(item.model), '')) as model, item.storage_gb,
      min(nullif(btrim(item.color), '')) as color,
      upper(nullif(btrim(item.final_grade), '')) as final_grade, count(*) as quantity
    from dated_boxes box
    join public.export_box_items item on item.box_id = box.id
    where (p_from is null or box.box_date >= (p_from::timestamp at time zone 'Asia/Dubai'))
      and (p_to is null or box.box_date < ((p_to + 1)::timestamp at time zone 'Asia/Dubai'))
      and (search_text = '' or concat_ws(' ', box.box_number, btrim(item.model),
        item.storage_gb::text || ' GB', btrim(item.color), btrim(item.final_grade))
        ilike search_pattern escape '!')
    group by box.id, box.box_number, box.state, box.box_date,
      lower(nullif(btrim(item.model), '')), item.storage_gb, lower(nullif(btrim(item.color), '')),
      upper(nullif(btrim(item.final_grade), ''))
  ), page_groups as (
    select * from grouped
    order by box_date desc nulls last, box_number desc, box_id, model, storage_gb, color, final_grade
    offset p_offset limit p_limit
  )
  select jsonb_build_object(
    'scope', p_page, 'offset', p_offset, 'group_count', count(*),
    'phone_count', coalesce(sum(quantity), 0), 'box_count', count(distinct box_id),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(g) - 'box_id'
        order by g.box_date desc nulls last, g.box_number desc, g.box_id, g.model, g.storage_gb, g.color, g.final_grade)
      from page_groups g
    ), '[]'::jsonb)
  ) into result from grouped;
  return result;
end;
$report$;
revoke all on function public.get_box_data_table_v2(text,date,date,text,integer,integer) from public, anon, authenticated;
grant execute on function public.get_box_data_table_v2(text,date,date,text,integer,integer) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule)
values ('get_box_data_table_v2','{"dynamic":"filter_source","parameter":"p_page","accounts":{"page":"accounts","capability":"view","read":true},"stock_exported":{"page":"stock_exported","capability":"view","read":true}}')
on conflict (rpc_name) do update set rule = excluded.rule;

create or replace function public.get_box_summary_tables_version()
returns text language sql stable security definer set search_path = pg_catalog, public as $version$
  select case when exists (
    select 1 from pg_proc where oid = to_regprocedure('public.get_box_data_table_v2(text,date,date,text,integer,integer)')
      and prosecdef and provolatile = 's'
      and strpos(prosrc, 'count(*) as quantity') > 0 and strpos(prosrc, 'item.imei') = 0
  ) and has_function_privilege('authenticated','public.get_box_data_table_v2(text,date,date,text,integer,integer)','EXECUTE')
    and not has_function_privilege('anon','public.get_box_data_table_v2(text,date,date,text,integer,integer)','EXECUTE')
    then '20261126-box-summary-tables-1' end;
$version$;
revoke all on function public.get_box_summary_tables_version() from public, anon, authenticated;
grant execute on function public.get_box_summary_tables_version() to anon, authenticated;

do $verify$
begin
  if public.get_box_summary_tables_version() is distinct from '20261126-box-summary-tables-1' then
    raise exception 'Box Summary Tables could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_box_summary_tables_version() as installed_box_summary_tables_version;
