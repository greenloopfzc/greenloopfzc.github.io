-- Read phone snapshots across pending Accounts boxes or Stock Exported boxes.
begin;
set local lock_timeout = '5s';

create or replace function public.get_box_data_table_v1(
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

  with dated_boxes as materialized (
    select box.id, box.box_number, workflow.state,
      case when p_page = 'stock_exported'
        then coalesce(workflow.verified_at, workflow.saved_at, box.closed_at, box.opened_at)
        else coalesce(workflow.saved_at, box.closed_at, box.opened_at)
      end as box_date
    from public.export_boxes box
    join greenloop_private.box_workflow workflow on workflow.box_id = box.id
    where (p_page = 'accounts' and workflow.state = 'accounts')
       or (p_page = 'stock_exported' and workflow.state in ('exported','legacy'))
  ), matched as materialized (
    select item.id, item.box_id, item.serial_no, box.box_date
    from dated_boxes box
    join public.export_box_items item on item.box_id = box.id
    where (p_from is null or box.box_date >= (p_from::timestamp at time zone 'Asia/Dubai'))
      and (p_to is null or box.box_date < ((p_to + 1)::timestamp at time zone 'Asia/Dubai'))
      and (search_text = '' or concat_ws(' ', box.box_number, item.imei,
        item.model, item.storage_gb::text || ' GB', item.color, item.final_grade)
        ilike search_pattern escape '!')
  ), page_items as (
    select * from matched
    order by box_date desc nulls last, box_id desc, serial_no, id
    offset p_offset limit p_limit
  )
  select jsonb_build_object(
    'scope', p_page, 'offset', p_offset,
    'total', (select count(*) from matched),
    'box_count', (select count(distinct box_id) from matched),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item_id', item.id, 'box_number', box.box_number, 'box_date', page.box_date,
        'state', box.state, 'imei', item.imei, 'model', item.model,
        'storage_gb', item.storage_gb, 'color', item.color, 'final_grade', item.final_grade
      ) order by page.box_date desc nulls last, page.box_id desc, page.serial_no, page.id)
      from page_items page
      join public.export_box_items item on item.id = page.id
      join dated_boxes box on box.id = page.box_id
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$report$;
revoke all on function public.get_box_data_table_v1(text,date,date,text,integer,integer) from public, anon, authenticated;
grant execute on function public.get_box_data_table_v1(text,date,date,text,integer,integer) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule)
values ('get_box_data_table_v1','{"dynamic":"filter_source","parameter":"p_page","accounts":{"page":"accounts","capability":"view","read":true},"stock_exported":{"page":"stock_exported","capability":"view","read":true}}')
on conflict (rpc_name) do update set rule = excluded.rule;

create or replace function public.get_box_data_tables_version()
returns text language sql stable security definer set search_path = pg_catalog, public as $version$
  select case when exists (
    select 1 from pg_proc where oid = to_regprocedure('public.get_box_data_table_v1(text,date,date,text,integer,integer)')
      and prosecdef and provolatile = 's'
      and strpos(prosrc, 'workflow.state in (''exported'',''legacy'')') > 0
      and strpos(prosrc, 'limit p_limit') > 0
  ) and has_function_privilege('authenticated','public.get_box_data_table_v1(text,date,date,text,integer,integer)','EXECUTE')
    and not has_function_privilege('anon','public.get_box_data_table_v1(text,date,date,text,integer,integer)','EXECUTE')
    then '20261126-box-data-tables-1' end;
$version$;
revoke all on function public.get_box_data_tables_version() from public, anon, authenticated;
grant execute on function public.get_box_data_tables_version() to anon, authenticated;

do $verify$
begin
  if public.get_box_data_tables_version() is distinct from '20261126-box-data-tables-1' then
    raise exception 'Box Data Tables could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_box_data_tables_version() as installed_box_data_tables_version;
