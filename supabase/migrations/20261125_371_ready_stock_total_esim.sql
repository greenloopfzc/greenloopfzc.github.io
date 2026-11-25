-- Same live stock and detail grouping as Total Ready Stock, with an eSIM subset.
begin;
set local lock_timeout='5s';

do $check$ begin
  if to_regprocedure('public.get_ready_stock_esim_version()') is null then
    raise exception 'Install Ready Stock eSIM first.';
  end if;
  if public.get_ready_stock_esim_version() is distinct from '20261125-ready-stock-esim-1' then
    raise exception 'The existing Ready Stock eSIM update could not be verified.';
  end if;
end; $check$;

create or replace function public.get_ready_stock_total_esim_v1(
  p_view text,p_group jsonb default null,p_offset integer default 0,
  p_show_color boolean default false,p_expected_snapshot text default null
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $report$
declare
  show_partner_names boolean;
  result jsonb;
begin
  perform greenloop_private.require_office_network();
  perform greenloop_private.pf_cap('ready_stock','view');
  if greenloop_private.damage_tv_only(auth.uid()) or not coalesce(public.has_role(array[
    'super_admin','owner','manager','production','final_qc','shop_staff'
  ]::public.app_role_key[]),false) then
    raise exception 'Ready Stock view permission is required.' using errcode='42501';
  end if;
  if p_view is null or p_view not in ('summary','esim_phones') or p_show_color is null
    or p_offset is null or p_offset<0 or mod(p_offset,50)<>0
    or (p_view='summary' and (p_group is not null or p_expected_snapshot is not null))
    or (p_view='esim_phones' and (p_expected_snapshot is null or p_expected_snapshot!~'^[a-f0-9]{32}$')) then
    raise exception 'Choose a valid Total Ready Stock page.' using errcode='22023';
  end if;
  if p_group is not null then
    if jsonb_typeof(p_group)<>'array' or jsonb_array_length(p_group)<>6 then
      raise exception 'Choose a valid Ready Stock group.' using errcode='22023';
    end if;
  end if;
  show_partner_names:=coalesce(public.get_my_partner_name_access(),false);

  with facts as materialized (
    select r.device_id,r.passed_at occurred_at,d.imei_1 imei,d.color actual_color,
      coalesce(nullif(btrim(d.model),''),'Unknown model') model,d.storage_gb,
      case when p_show_color then d.color end color,r.final_grade,
      b.id batch_id,b.batch_number,b.invoice_number,b.planned_quantity,
      s.id supplier_id,s.supplier_code,case when show_partner_names then s.company_name end supplier_name,
      greenloop_private.esim_stock_class(d.brand,d.device_platform::text,d.model,d.specification_region)
        in ('esim_only_by_a_number','esim_only_by_model','likely_esim_only_by_region') esim
    from greenloop_private.rsbe_current(null,null) r
    join public.devices d on d.id=r.device_id
    join public.jobs j on j.id=r.job_id
    left join public.receiving_batches b on b.id=j.receiving_batch_id
    left join public.suppliers s on s.id=coalesce(j.supplier_id,b.supplier_id)
  ), stock as materialized (
    select *,jsonb_build_array(model,storage_gb,color,final_grade,batch_id,supplier_id) group_key
    from facts
  ), selected_esim as materialized (
    select * from stock where esim and (p_group is null or group_key=p_group)
  ), matching as (
    select count(*) quantity,md5(coalesce(string_agg(device_id::text||':'||imei,',' order by device_id),'')) snapshot
    from selected_esim
  ), groups as materialized (
    select group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,
      planned_quantity,supplier_code,supplier_name,count(*) quantity,
      count(*) filter(where esim) esim_quantity,
      md5(coalesce(string_agg(device_id::text||':'||imei,',' order by device_id) filter(where esim),'')) esim_snapshot
    from stock where p_view='summary'
    group by group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,planned_quantity,supplier_code,supplier_name
  ), group_page as (
    select * from groups order by model,storage_gb,color,final_grade,batch_number,group_key
    limit 50 offset p_offset
  ), phone_page as (
    select * from selected_esim where p_view='esim_phones' order by imei,device_id limit 50 offset p_offset
  )
  select jsonb_build_object(
    'mode','current','view',case when p_view='summary' then 'groups' else 'phones' end,
    'show_color',p_show_color,'offset',p_offset,'limit',50,
    'phone_total',(select count(*) from stock),
    'total',case when p_view='summary' then (select count(*) from groups) else matching.quantity end,
    'esim_total',matching.quantity,'esim_snapshot',matching.snapshot,
    'rows',coalesce(case when p_view='summary' then (
      select jsonb_agg(to_jsonb(g) order by model,storage_gb,color,final_grade,batch_number,group_key) from group_page g
    ) else (
      select jsonb_agg(jsonb_build_object('imei',imei,'model',model,'storage_gb',storage_gb,
        'color',actual_color,'final_grade',final_grade,'batch_number',batch_number,
        'invoice_number',invoice_number,'planned_quantity',planned_quantity,'supplier_code',supplier_code,
        'supplier_name',supplier_name,'occurred_at',occurred_at) order by imei,device_id) from phone_page
    ) end,'[]'::jsonb)
  ) into result from matching;

  if p_view='esim_phones' and result->>'esim_snapshot' is distinct from p_expected_snapshot then
    raise exception 'e-Sim stock changed. Return to the summary and select the updated quantity.' using errcode='40001';
  end if;
  return result;
end;
$report$;

revoke all on function public.get_ready_stock_total_esim_v1(text,jsonb,integer,boolean,text) from public,anon;
grant execute on function public.get_ready_stock_total_esim_v1(text,jsonb,integer,boolean,text) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_ready_stock_total_esim_v1','{"page":"ready_stock","capability":"view","read":true}'),
  ('get_ready_stock_total_esim_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create or replace function public.get_ready_stock_total_esim_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when public.get_ready_stock_esim_version()='20261125-ready-stock-esim-1'
    and not has_function_privilege('anon','public.get_ready_stock_total_esim_v1(text,jsonb,integer,boolean,text)','EXECUTE')
    and has_function_privilege('authenticated','public.get_ready_stock_total_esim_v1(text,jsonb,integer,boolean,text)','EXECUTE')
    and exists(select 1 from pg_proc
      where oid=to_regprocedure('public.get_ready_stock_total_esim_v1(text,jsonb,integer,boolean,text)')
        and prosecdef and provolatile='s' and strpos(prosrc,'greenloop_private.rsbe_current(')>0
        and strpos(prosrc,'greenloop_private.esim_stock_class(')>0)
    then '20261125-ready-stock-total-esim-1' end;
$version$;
revoke all on function public.get_ready_stock_total_esim_version() from public,anon,authenticated;
grant execute on function public.get_ready_stock_total_esim_version() to anon,authenticated;

do $verify$ begin
  if public.get_ready_stock_total_esim_version() is distinct from '20261125-ready-stock-total-esim-1' then
    raise exception 'Total Ready Stock e-Sim update could not be verified.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_ready_stock_total_esim_version() as installed_ready_stock_total_esim_version;
