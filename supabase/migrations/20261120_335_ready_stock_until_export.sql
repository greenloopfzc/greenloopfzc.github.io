-- Count QC-approved stock until its box is exported.
begin;

create or replace function greenloop_private.rsbe_current(p_from date, p_to date)
returns table(job_id uuid, device_id uuid, final_grade text, passed_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public
as $ready$
  select distinct on (d.id) j.id, d.id,
    coalesce(nullif(btrim(pass.final_grade), ''), 'Unspecified'), pass.inspected_at
  from public.jobs j
  join public.devices d on d.id = j.device_id and d.deleted_at is null
  cross join lateral (
    select q.final_grade, q.inspected_at from greenloop_private.qdr_ready_outcomes q
    where q.job_id = j.id and q.result = 'pass'
      and (p_from is null or timezone('Asia/Dubai', q.inspected_at)::date between p_from and p_to)
    order by q.inspected_at desc
    limit 1
  ) pass
  where j.deleted_at is null
    and (
      j.current_status in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
      or (
        j.current_status in ('box_entry','accounts_pending')
        and exists (
          select 1 from public.export_box_items i
          join greenloop_private.box_workflow w on w.box_id = i.box_id
          where i.job_id = j.id and i.device_id = d.id and w.state in ('draft','accounts','recheck')
        )
      )
    )
    and not exists (
      select 1 from public.export_box_items i
      join greenloop_private.box_workflow w on w.box_id = i.box_id
      where i.job_id = j.id and i.device_id = d.id and w.state in ('exported','legacy')
    )
    and not exists (
      select 1 from greenloop_private.chaman_lines c
      where c.device_id = d.id and c.voided_at is null and c.phase <> 'company'
    )
    and not exists (
      select 1 from public.supplier_returns r
      where (r.job_id = j.id or (r.job_id is null and r.device_id = j.device_id))
        and r.archived_at is null and r.status in ('requested','approved','returned')
    )
  order by d.id, pass.inspected_at desc, j.id;
$ready$;
revoke all on function greenloop_private.rsbe_current(date,date) from public, anon, authenticated;

create table if not exists greenloop_private.ready_box_export_installation(identity text primary key, hash text not null);
alter table greenloop_private.ready_box_export_installation enable row level security;
revoke all on greenloop_private.ready_box_export_installation from public, anon, authenticated;

do $patch$
declare
  target record;
  impl regprocedure;
  original text;
  revised text;
  body_hash text;
  seal record;
  ready_rows text := $select$
    select j.id job_id, j.job_type,
      concat_ws(' ', coalesce(nullif(btrim(d.model), ''), 'Unknown model'),
        case when d.storage_gb is not null then d.storage_gb::text || ' GB' end) model_label,
      r.final_grade, r.passed_at latest_passed_at
    from greenloop_private.rsbe_current(p_date_from,p_date_to) r
    join public.jobs j on j.id = r.job_id
    join public.devices d on d.id = r.device_id
  $select$;
begin
  for target in select * from (values
    ('public.get_ready_stock_final_grade_table(date,date)', true, '5e283707fe42256453452e50509a5192', 'with eligible as [(].+?\n  [)], totals as', 'with eligible as (' || ready_rows || '), totals as'),
    ('public.get_ready_stock_imeis_v1(jsonb,date,date,integer,integer)', true, 'da737d71c1fd0e93daa3a2c94848f2b1', 'with eligible as materialized[(].+?\n [)],selected as', 'with eligible as materialized(' || ready_rows || '),selected as'),
    ('greenloop_private.rsg_facts(text,date,jsonb,date,date)', false, '2bf18b993a5f93f20479c51f1d7a6fec', $re$current_phones as[(].+?\n [)],daily as$re$, $facts$current_phones as (
      select r.job_id, r.device_id, r.passed_at occurred_at, null::text box_number, r.final_grade
      from greenloop_private.rsbe_current(p_from,p_to) r
      join public.devices d on d.id = r.device_id
      where p_mode = 'current'
        and (p_groups is null or exists (
          select 1 from jsonb_array_elements(p_groups) g
          where btrim(concat_ws(' ', coalesce(nullif(btrim(d.model), ''), 'Unknown model'),
            case when d.storage_gb is not null then d.storage_gb::text || ' GB' end)) = g->>'m'
            and lower(regexp_replace(r.final_grade, '[[:space:]]+', ' ', 'g')) = g->>'g'
        ))
    ),daily as$facts$),
    ('greenloop_private.drc_ready_count()', false, '0239f31d54c3ea58db6662bdaa5356b7',
      $re$select count[(].+?f.result='pass'[)];$re$,
      'select count(*) from greenloop_private.rsbe_current(null,null);'),
    ('public.get_company_stock_progress_v1(uuid,uuid,text,integer)', false, '905ee315e4b4c4c290b7511f45629d16',
      $re$select s.model, s.storage_gb,.+?\n    from stock s$re$,
      $progress$select s.model, s.storage_gb, ready.job_id is not null ready,
      case
        when s.current_status::text in ('return_pending', 'supplier_return_requested')
          or exists (
            select 1 from public.supplier_returns r
            where (r.job_id = s.job_id or (r.job_id is null and r.device_id = s.device_id))
              and r.archived_at is null and r.status in ('requested', 'approved')
          ) then 'return_pending'
        when s.current_status = 'parts_pending' then 'parts'
        when s.current_status = 'box_entry' then 'box_entry'
        when s.current_status = 'accounts_pending' then 'accounts'
        when stage.name = 'ready_stock' and ready.job_id is null then 'other'
        when stage.name in ('initial_qc', 'issuance', 'lab_glass', 'final_qc', 'b_dept', 'ready_stock')
          then stage.name
        else 'other'
      end stage
    from stock s
    left join greenloop_private.rsbe_current(null,null) ready on ready.job_id = s.job_id$progress$)
  ) as t(identity, wrapped, baseline, pattern, replacement) loop
    if target.wrapped then
      select to_regprocedure(implementation) into strict impl
      from greenloop_private.office_routines
      where to_regprocedure(identity) = to_regprocedure(target.identity);
    else
      impl := to_regprocedure(target.identity);
    end if;
    if impl is null then
      raise exception 'Ready Stock reader missing: %', target.identity;
    end if;

    select replace(pg_get_functiondef(p.oid), chr(13), ''),md5(replace(p.prosrc,chr(13),''))
    into strict original,body_hash from pg_proc p where p.oid = impl;
    if position('greenloop_private.rsbe_current(' in original) = 0 then
      if body_hash is distinct from target.baseline then
        raise exception 'Ready Stock reader version differs: %', target.identity;
      end if;
      revised := regexp_replace(original, target.pattern, target.replacement);
      if target.identity = 'public.get_company_stock_progress_v1(uuid,uuid,text,integer)' then
        revised := replace(revised,
          'count(*) filter (where stage = ''ready_stock'') ready_stock,',
          'count(*) filter (where stage = ''ready_stock'') ready_stock, count(*) filter (where ready) ready_total,');
        revised := replace(revised, 'coalesce(sum(ready_stock),0) ready_stock,',
          'coalesce(sum(ready_stock),0) ready_stock, coalesce(sum(ready_total),0) ready_total,');
        revised := replace(revised, 'and w.state = ''exported''', 'and w.state in (''exported'',''legacy'')');
      end if;
      if position('greenloop_private.rsbe_current(' in revised) = 0 then
        raise exception 'Ready Stock reader could not be updated: %', target.identity;
      end if;
      execute revised;
    elsif not exists (
      select 1 from greenloop_private.ready_box_export_installation
      where identity = impl::text and hash = md5(pg_get_functiondef(impl))
    ) then
      raise exception 'Updated Ready Stock reader failed verification: %', target.identity;
    end if;

    update greenloop_private.office_routines set original_hash = md5(pg_get_functiondef(impl))
      where to_regprocedure(implementation) = impl;
    update greenloop_private.capability_routines set original_hash = md5(pg_get_functiondef(impl))
      where to_regprocedure(implementation) = impl;
    -- Retain earlier integrity checks for the exact routines revised by this upgrade.
    for seal in
      select h.table_name, h.column_name hash_col, i.column_name id_col
      from information_schema.columns h join information_schema.columns i using (table_schema,table_name)
      where h.table_schema = 'greenloop_private' and h.table_name like '%installation'
        and h.column_name in ('hash','definition_hash')
        and i.column_name in ('identity','object_identity','function_identity')
    loop
      execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef($1)) where to_regprocedure(%I)=$1',
        seal.table_name, seal.hash_col, seal.id_col) using impl;
    end loop;
    insert into greenloop_private.ready_box_export_installation values (impl::text,md5(pg_get_functiondef(impl)))
      on conflict(identity) do update set hash = excluded.hash;
  end loop;
end
$patch$;

create or replace function public.get_ready_stock_until_export_version() returns text
language sql stable security definer set search_path = pg_catalog, public
as $version$
  select case when (
    select count(*) = 7 and bool_and(coalesce(hash = md5(pg_get_functiondef(to_regprocedure(identity))),false))
    from greenloop_private.ready_box_export_installation
  )
  and not has_function_privilege('anon','greenloop_private.rsbe_current(date,date)','EXECUTE')
  and not has_function_privilege('authenticated','greenloop_private.rsbe_current(date,date)','EXECUTE')
  and (
    select count(*) = 2 and bool_and(
      coalesce(wrapped_hash = md5(pg_get_functiondef(to_regprocedure(identity))),false)
      and coalesce(original_hash = md5(pg_get_functiondef(to_regprocedure(implementation))),false)
      and position('greenloop_private.require_office_network()' in pg_get_functiondef(to_regprocedure(identity))) > 0
    )
    from greenloop_private.office_routines
    where to_regprocedure(identity) in ('public.get_ready_stock_final_grade_table(date,date)'::regprocedure,
      'public.get_ready_stock_imeis_v1(jsonb,date,date,integer,integer)'::regprocedure)
  )
  and public.get_dashboard_ready_counts_version()='20261110-dashboard-ready-counts-1'
  and public.get_ready_stock_models_version()='20261113-ready-stock-models-1'
  and public.get_company_stock_progress_version()='20261120-company-stock-progress-1'
  then '20261120-ready-stock-until-export-1' end;
$version$;
revoke all on function public.get_ready_stock_until_export_version() from public;
grant execute on function public.get_ready_stock_until_export_version() to anon, authenticated;
insert into greenloop_private.ready_box_export_installation
select id,md5(pg_get_functiondef(id::regprocedure))
from unnest(array['greenloop_private.rsbe_current(date,date)','public.get_ready_stock_until_export_version()']) id
on conflict(identity) do update set hash = excluded.hash;

do $verify$
begin
  if public.get_ready_stock_until_export_version() is distinct from '20261120-ready-stock-until-export-1' then
    raise exception 'Ready Stock until export verification failed.';
  end if;
end
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_ready_stock_until_export_version() as installed_ready_stock_until_export_version;
