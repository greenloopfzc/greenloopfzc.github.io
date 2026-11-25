-- Report the eSIM-only variants in current company stock.
begin;
set local lock_timeout = '5s';

do $permissions$
begin
  if not exists (
    select 1 from greenloop_private.page_capability_catalog
    where page_key = 'reports' and capabilities @> '[{"key":"report_esim_stock"}]'
  ) then
    insert into greenloop_private.user_page_capabilities(user_id,capabilities)
    select id,greenloop_private.user_capabilities(id) from public.user_profiles
    on conflict(user_id) do nothing;
    update greenloop_private.page_capability_catalog
    set capabilities = capabilities || '[
      {"key":"report_esim_stock","label":"View eSIM Stock","write":false},
      {"key":"report_esim_stock_search","label":"Filter eSIM Stock","write":false}
    ]'::jsonb where page_key = 'reports';
    update greenloop_private.user_page_capabilities a
    set capabilities = jsonb_set(a.capabilities,'{reports}',(a.capabilities->'reports') ||
      '["report_esim_stock","report_esim_stock_search"]'::jsonb)
    where a.capabilities->'reports' ? 'view' and exists (
      select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
      where ur.user_id = a.user_id and r.role_key::text in ('owner','super_admin')
    );
  end if;
end;
$permissions$;

insert into greenloop_private.report_access_sections(report_key,config)
values ('esim_stock','{"label":"eSIM Stock","view":"report_esim_stock",
  "actions":["report_esim_stock_search"],"search":"report_esim_stock_search"}')
on conflict(report_key) do nothing;
insert into greenloop_private.report_access_dependencies(capability,required_views)
values ('report_esim_stock_search','"report_esim_stock"') on conflict(capability) do nothing;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_esim_stock_v1','{"page":"reports","capability":"report_esim_stock","read":true}'),
  ('get_esim_stock_version','{"read":true}')
on conflict(rpc_name) do nothing;
update greenloop_private.page_capability_installation set hash = case identity
  when 'catalog' then (select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)
  when 'rules' then (select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
  end where identity in ('catalog','rules');
update greenloop_private.report_access_config_seal set
  sections_hash = (select md5(jsonb_agg(to_jsonb(s) order by report_key)::text) from greenloop_private.report_access_sections s),
  dependencies_hash = (select md5(jsonb_agg(to_jsonb(d) order by capability)::text) from greenloop_private.report_access_dependencies d)
where singleton;


-- SIM classification is based on saved inventory fields.
-- References: https://support.apple.com/en-us/108044 and https://support.apple.com/en-us/118569
create or replace function public.get_esim_stock_v1(
  p_supplier_id uuid default null, p_batch_id uuid default null, p_invoice text default null,
  p_view text default 'esim', p_offset integer default 0
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public
as $report$
declare result jsonb;
begin
  perform greenloop_private.rp_require('esim_stock');
  if p_supplier_id is not null or p_batch_id is not null or p_invoice is not null then
    perform greenloop_private.rp_require('esim_stock','search');
  end if;
  if p_view is null or p_view not in ('esim','check') or length(p_invoice)>200
    or p_offset is null or p_offset<0 or mod(p_offset,50)<>0 then
    raise exception 'Choose valid eSIM Stock filters and a report page.' using errcode='22023';
  end if;

  with apple_variants(model, esim_only, with_tray, region_rule) as (
  values
    ('14',         array['A2649'],         array['A2881','A2882','A2883','A2884'], 'us_only'),
    ('14plus',     array['A2632'],         array['A2885','A2886','A2887','A2888'], 'us_only'),
    ('14pro',      array['A2650'],         array['A2889','A2890','A2891','A2892'], 'us_only'),
    ('14promax',   array['A2651'],         array['A2893','A2894','A2895','A2896'], 'us_only'),
    ('15',         array['A2846'],         array['A3089','A3090','A3092'], 'us_only'),
    ('15plus',     array['A2847'],         array['A3093','A3094','A3096'], 'us_only'),
    ('15pro',      array['A2848'],         array['A3101','A3102','A3104'], 'us_only'),
    ('15promax',   array['A2849'],         array['A3105','A3106','A3108'], 'us_only'),
    ('16',         array['A3081'],         array['A3286','A3287','A3288'], 'us_only'),
    ('16plus',     array['A3082'],         array['A3289','A3290','A3291'], 'us_only'),
    ('16pro',      array['A3083'],         array['A3292','A3293','A3294'], 'us_only'),
    ('16promax',   array['A3084'],         array['A3295','A3296','A3297'], 'us_only'),
    ('16e',        array['A3212'],         array['A3408','A3409','A3410'], 'us_only'),
    ('17',         array['A3258','A3519'], array['A3520','A3521'], 'multi_region'),
    ('17pro',      array['A3256','A3522'], array['A3523','A3524'], 'multi_region'),
    ('17promax',   array['A3257','A3525'], array['A3526','A3527'], 'multi_region'),
    ('17e',        array['A3575'],         array['A3634','A3635'], 'multi_region'),
    ('air',        array['A3260','A3516','A3517','A3518'], array[]::text[], 'all'),
    ('18pro',      array['A3472','A3713'], array['A3714','A3715'], 'multi_region'),
    ('18promax',   array['A3473','A3716'], array['A3717','A3718'], 'multi_region')
), latest_jobs as materialized (
  select distinct on (j.device_id) j.id, j.device_id, j.ownership_type, j.current_status, j.receiving_batch_id
  from public.jobs j
  where j.deleted_at is null
  order by j.device_id, j.received_at desc nulls last, j.created_at desc, j.id
), company_phones as (
  -- Same company custody as Stock Progress, including boxes awaiting export.
  select d.brand, d.device_platform, d.model, d.storage_gb, d.color, d.specification_region, j.receiving_batch_id
  from latest_jobs j
  join public.devices d on d.id = j.device_id and d.deleted_at is null
  where j.ownership_type = 'company_owned' and nullif(btrim(d.imei_1), '') is not null
    and j.current_status::text not in (
      'shipped','returned_to_customer','returned_to_supplier','shop_stock','scrap','rma_completed','cancelled','closed'
    )
    and not exists (
      select 1 from greenloop_private.chaman_lines c
      where c.device_id = j.device_id and c.voided_at is null and c.phase <> 'company'
    )
    and not exists (
      select 1 from public.export_box_items i
      join greenloop_private.box_workflow w on w.box_id = i.box_id and w.state = 'exported'
      where i.job_id = j.id
    )
    and not exists (
      select 1 from public.supplier_returns r
      where (r.job_id = j.id or (r.job_id is null and r.device_id = j.device_id))
        and r.archived_at is null and r.status = 'returned'
    )
), normalized as (
  select coalesce(nullif(btrim(model), ''), 'Model not recorded') as display_model, storage_gb, nullif(btrim(color),'') as color, receiving_batch_id,
    lower(brand) = 'apple' or device_platform::text = 'ios' as apple,
    lower(regexp_replace(regexp_replace(regexp_replace(coalesce(model,''), '\mA[0-9]{4}\M', '', 'gi'),
      '^[[:space:]]*iphone', '', 'i'), '[^a-zA-Z0-9]+', '', 'g')) as model_key,
    upper(substring(coalesce(specification_region,'') from '(?i)\m[A-Z]{1,3}/A\M')) as sales_code,
    lower(btrim(coalesce(specification_region,''))) as region,
    upper(substring(coalesce(model,'') from '(?i)\mA[0-9]{4}\M')) as model_a,
    upper(substring(coalesce(specification_region,'') from '(?i)\mA[0-9]{4}\M')) as region_a
  from company_phones
), classified as (
  select n.display_model, n.storage_gb, n.color, n.receiving_batch_id,
    case
      when n.apple is not true
        or (n.model_a is not null and n.region_a is not null and n.model_a <> n.region_a)
        then 'needs_variant_check'
      when direct.model is not null and n.model_key <> '' and direct.model <> n.model_key
        then 'needs_variant_check'
      when coalesce(n.model_a,n.region_a) = any(direct.esim_only) then 'esim_only_by_a_number'
      when coalesce(n.model_a,n.region_a) = any(direct.with_tray) then 'physical_sim_variant'
      when by_name.region_rule = 'all' then 'esim_only_by_model'
      when n.model_key ~ '^(se.*|x|xr|xs|xsmax|[4-8](s|plus|splus)?|1[0123](mini|pro|promax)?)$'
        then 'physical_sim_variant'
      when n.model_a is not null or n.region_a is not null then 'needs_variant_check'
      when by_name.region_rule in ('us_only','multi_region')
        and (n.sales_code = 'LL/A' or n.region in ('united states','usa','us','puerto rico'))
        then 'likely_esim_only_by_region'
      when by_name.region_rule = 'multi_region' and
        (n.sales_code in ('C/A','VC/A','CL/A','J/A')
         or n.region in ('canada','japan','mexico','guam','united arab emirates','uae','saudi arabia',
                         'bahrain','kuwait','oman','qatar','u.s. virgin islands'))
        then 'likely_esim_only_by_region'
      when by_name.region_rule = 'us_only' and
        (n.sales_code in ('C/A','VC/A','CL/A','CH/A','ZP/A','J/A','KH/A','VN/A','TA/A','ZA/A','AB/A','X/A','B/A','ZD/A')
         or n.region in ('united arab emirates','uae','canada','japan','south korea','mainland china','hong kong','macau'))
        then 'physical_sim_variant'
      when by_name.region_rule = 'multi_region' and
        (n.sales_code in ('CH/A','ZP/A','KH/A','VN/A','TA/A','ZA/A','X/A','B/A','ZD/A')
         or n.region in ('south korea','mainland china','hong kong','macau'))
        then 'physical_sim_variant'
      else 'needs_variant_check'
    end as sim_class
  from normalized n
  left join apple_variants by_name on by_name.model = n.model_key
  left join apple_variants direct
    on coalesce(n.model_a,n.region_a) = any(direct.esim_only || direct.with_tray)
  ), receipts as materialized (
    select r.batch_id,r.supplier_id,
      regexp_replace(r.supplier_code, '-\([0-9]+\)$', '') supplier_code,
      r.supplier_name,r.batch_number,r.invoice_number,r.received_quantity receipt_quantity,r.descendant_ids
    from greenloop_private.sc_receipts() r where r.parent_batch_id is null
  ), eligible as materialized (
    select c.display_model,c.storage_gb,c.color,c.sim_class,r.batch_id,r.supplier_id,r.invoice_number
    from classified c
    left join lateral (
      select batch_id,supplier_id,invoice_number from receipts r
      where c.receiving_batch_id=any(r.descendant_ids)
      order by (r.batch_id=c.receiving_batch_id) desc,r.batch_id
      limit 1
    ) r on true
    where c.sim_class<>'physical_sim_variant'
  ), filtered as materialized (
    select * from eligible e
    where (p_supplier_id is null or e.supplier_id=p_supplier_id)
      and (p_batch_id is null or e.batch_id=p_batch_id)
      and (p_invoice is null or e.invoice_number=p_invoice)
  ), counts as (
    select count(*) filter (where sim_class in ('esim_only_by_a_number','esim_only_by_model')) by_model,
      count(*) filter (where sim_class='likely_esim_only_by_region') by_region,
      count(*) filter (where sim_class='needs_variant_check') needs_check
    from filtered
  ), groups as materialized (
    select min(regexp_replace(f.display_model,'^iphone[[:space:]]+','','i')) model,
      f.storage_gb,min(f.color) color,f.batch_id,f.sim_class,count(*) quantity
    from filtered f
    where (f.sim_class='needs_variant_check') = (p_view='check')
    group by lower(regexp_replace(regexp_replace(f.display_model,'^iphone[[:space:]]+','','i'),'[[:space:]]+','','g')),
      f.storage_gb,lower(f.color),f.batch_id,f.sim_class
  ), page as (
    select g.* from groups g
    order by lower(model), storage_gb nulls last, lower(color) nulls last, batch_id nulls last, sim_class
    limit 50 offset p_offset
  )
  select jsonb_build_object(
    'version','20261125-esim-stock-1','view',p_view,'offset',p_offset,'checked_at',statement_timestamp(),
    'filters',jsonb_build_object('supplier',p_supplier_id,'batch',p_batch_id,'invoice',p_invoice),
    'counts',(select to_jsonb(c) from counts c),
    'row_count',(select count(*) from groups),
    'rows',coalesce((select jsonb_agg(to_jsonb(p) order by lower(model),storage_gb nulls last,
      lower(color) nulls last,batch_id nulls last,sim_class) from page p),'[]'::jsonb),
    'receipts',coalesce((select jsonb_agg(to_jsonb(r)-'descendant_ids' order by r.batch_number,r.batch_id)
      from receipts r where exists(select 1 from eligible e where e.batch_id=r.batch_id)),'[]'::jsonb)
  ) into result;
  return result;
end;
$report$;

revoke all on function public.get_esim_stock_v1(uuid,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.get_esim_stock_v1(uuid,uuid,text,text,integer) to authenticated;

create or replace function public.get_esim_stock_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when
    not has_function_privilege('anon','public.get_esim_stock_v1(uuid,uuid,text,text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.get_esim_stock_v1(uuid,uuid,text,text,integer)','EXECUTE')
    and exists (select 1 from greenloop_private.report_access_sections
      where report_key='esim_stock' and config->>'view'='report_esim_stock')
    and exists (select 1 from greenloop_private.capability_rpc_rules
      where rpc_name='get_esim_stock_v1' and rule->>'capability'='report_esim_stock')
  then '20261125-esim-stock-1' end;
$version$;
revoke all on function public.get_esim_stock_version() from public,anon,authenticated;
grant execute on function public.get_esim_stock_version() to anon,authenticated;
do $verify$
begin
  if public.get_esim_stock_version() is distinct from '20261125-esim-stock-1' then
    raise exception 'eSIM Stock report installation failed verification.';
  end if;
end;
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_esim_stock_version() as installed_esim_stock_version;
