begin;
set local lock_timeout='5s';

-- One classifier for the company eSIM report and the Ready Stock subset.
create or replace function greenloop_private.esim_stock_class(
  p_brand text,p_platform text,p_model text,p_region text
) returns text language sql immutable set search_path=pg_catalog as $class$
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
  ), normalized as (
    select
    lower(p_brand) = 'apple' or p_platform::text = 'ios' as apple,
    lower(regexp_replace(regexp_replace(regexp_replace(coalesce(p_model,''), '\mA[0-9]{4}\M', '', 'gi'),
      '^[[:space:]]*iphone', '', 'i'), '[^a-zA-Z0-9]+', '', 'g')) as model_key,
    upper(substring(coalesce(p_region,'') from '(?i)\m[A-Z]{1,3}/A\M')) as sales_code,
    lower(btrim(coalesce(p_region,''))) as region,
    upper(substring(coalesce(p_model,'') from '(?i)\mA[0-9]{4}\M')) as model_a,
    upper(substring(coalesce(p_region,'') from '(?i)\mA[0-9]{4}\M')) as region_a
  )
  select
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
    end
  from normalized n
  left join apple_variants by_name on by_name.model = n.model_key
  left join apple_variants direct
    on coalesce(n.model_a,n.region_a) = any(direct.esim_only || direct.with_tray)
$class$;
revoke all on function greenloop_private.esim_stock_class(text,text,text,text) from public,anon,authenticated;

do $share$
declare original text; revised text;
begin
  if public.get_esim_stock_version() is distinct from '20261125-esim-stock-1' then
    raise exception 'Install the verified eSIM Stock report first.';
  end if;
  original := pg_get_functiondef('public.get_esim_stock_v1(uuid,uuid,text,text,integer)'::regprocedure);
  if position('greenloop_private.esim_stock_class(' in original)>0 then return; end if;
  revised := regexp_replace(original,$catalog$(?s)with apple_variants[(].*?[)], latest_jobs as materialized [(]$catalog$,
    'with latest_jobs as materialized (');
  if revised=original then raise exception 'The installed eSIM Stock catalog differs.'; end if;
  revised := regexp_replace(revised,$classifier$(?s)[)], normalized as [(].*?[)], receipts as materialized [(]$classifier$,$shared$
  ), classified as (
    select coalesce(nullif(btrim(c.model),''),'Model not recorded') display_model,
      c.storage_gb,nullif(btrim(c.color),'') color,c.receiving_batch_id,
      greenloop_private.esim_stock_class(c.brand,c.device_platform::text,c.model,c.specification_region) sim_class
    from company_phones c
  ), receipts as materialized ($shared$);
  if position('greenloop_private.esim_stock_class(' in revised)=0 then
    raise exception 'The installed eSIM Stock classifier differs.';
  end if;
  execute revised;
end;
$share$;

create or replace function public.get_ready_stock_esim_v1(
  p_view text default 'cards',p_group jsonb default null,p_offset integer default 0,
  p_show_color boolean default true
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $report$
declare result jsonb;
begin
  perform greenloop_private.pf_cap('ready_stock','view');
  if not coalesce(public.has_role(array[
    'super_admin','owner','manager','production','final_qc','shop_staff'
  ]::public.app_role_key[]),false) then
    raise exception 'Ready Stock view permission is required.' using errcode='42501';
  end if;
  if p_view is null or p_view not in ('cards','groups') or p_show_color is null
    or p_offset is null or p_offset<0 or mod(p_offset,50)<>0
    or (p_view='cards' and (p_group is not null or p_offset<>0)) then
    raise exception 'Choose a valid Ready Stock eSIM report page.' using errcode='22023';
  end if;
  if p_group is not null then
    if jsonb_typeof(p_group)<>'array' or jsonb_array_length(p_group)<>6 then
      raise exception 'Choose a valid Ready Stock eSIM group.' using errcode='22023';
    end if;
  end if;

  with ready as materialized (
    select r.job_id,r.device_id,r.final_grade,r.passed_at occurred_at,
      coalesce(nullif(btrim(d.model),''),'Unknown model') model,d.storage_gb,d.color,d.imei_1 imei,
      greenloop_private.esim_stock_class(d.brand,d.device_platform::text,d.model,d.specification_region)
        in ('esim_only_by_a_number','esim_only_by_model','likely_esim_only_by_region') esim
    from greenloop_private.rsbe_current(null,null) r
    join public.devices d on d.id=r.device_id
  ), cards as (
    select concat_ws(' ',model,case when storage_gb is not null then storage_gb::text || ' GB' end) model,
      final_grade,count(*) quantity
    from ready where p_view='cards'
    group by ready.model,storage_gb,final_grade
  ), receipts as materialized (
    select batch_id,batch_number,invoice_number,received_quantity,
      supplier_id,supplier_code,supplier_name,descendant_ids
    from greenloop_private.sc_receipts()
    where p_view='groups' and parent_batch_id is null
  ), base as materialized (
    select r.device_id,r.imei,r.model,r.storage_gb,r.color actual_color,
      case when p_show_color then r.color end color,r.final_grade,r.occurred_at,
      b.batch_number,b.invoice_number,b.received_quantity planned_quantity,b.supplier_code,b.supplier_name,
      jsonb_build_array(r.model,r.storage_gb,case when p_show_color then r.color end,r.final_grade,b.batch_id,b.supplier_id) group_key
    from ready r
    join public.jobs j on j.id=r.job_id
    left join lateral (
      select b.* from receipts b where j.receiving_batch_id=any(b.descendant_ids)
      order by (j.receiving_batch_id=b.batch_id) desc,b.batch_id
      limit 1
    ) b on true
    where p_view='groups' and r.esim
  ), groups as materialized (
    select group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,
      planned_quantity,supplier_code,supplier_name,count(*) quantity
    from base where p_group is null
    group by group_key,model,storage_gb,color,final_grade,batch_number,invoice_number,
      planned_quantity,supplier_code,supplier_name
  ), group_page as (
    select * from groups order by model,storage_gb,color,final_grade,batch_number,group_key
    limit 50 offset p_offset
  ), phone_page as (
    select * from base where group_key=p_group
    order by imei,device_id limit 50 offset p_offset
  )
  select case when p_view='cards' then jsonb_build_object(
    'esim_count',(select count(*) from ready where esim),
    'rows',coalesce((select jsonb_agg(to_jsonb(c) order by model,final_grade) from cards c),'[]'::jsonb)
  ) else jsonb_build_object(
    'mode','current','show_color',p_show_color,'view',case when p_group is null then 'groups' else 'phones' end,
    'offset',p_offset,'limit',50,'phone_total',(select count(*) from base),
    'total',case when p_group is null then (select count(*) from groups)
      else (select count(*) from base where group_key=p_group) end,
    'rows',coalesce(case when p_group is null then (
      select jsonb_agg(to_jsonb(p) order by model,storage_gb,color,final_grade,batch_number,group_key) from group_page p
    ) else (
      select jsonb_agg(jsonb_build_object(
        'imei',p.imei,'model',p.model,'storage_gb',p.storage_gb,'color',p.actual_color,'final_grade',p.final_grade,
        'batch_number',p.batch_number,'invoice_number',p.invoice_number,'planned_quantity',p.planned_quantity,
        'supplier_code',p.supplier_code,'supplier_name',p.supplier_name,'occurred_at',p.occurred_at
      ) order by p.imei,p.device_id) from phone_page p
    ) end,'[]'::jsonb)
  ) end into result;
  return result;
end;
$report$;
revoke all on function public.get_ready_stock_esim_v1(text,jsonb,integer,boolean) from public,anon,authenticated;
grant execute on function public.get_ready_stock_esim_v1(text,jsonb,integer,boolean) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_ready_stock_esim_v1','{"page":"ready_stock","capability":"view","read":true}'),
  ('get_ready_stock_esim_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create or replace function public.get_ready_stock_esim_version()
returns text language sql stable security definer set search_path=pg_catalog as $version$
  select case when
    public.get_esim_stock_version()='20261125-esim-stock-1'
    and not has_function_privilege('anon','public.get_ready_stock_esim_v1(text,jsonb,integer,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.get_ready_stock_esim_v1(text,jsonb,integer,boolean)','EXECUTE')
    and not has_function_privilege('authenticated','greenloop_private.esim_stock_class(text,text,text,text)','EXECUTE')
    and position('greenloop_private.esim_stock_class(' in
      pg_get_functiondef('public.get_esim_stock_v1(uuid,uuid,text,text,integer)'::regprocedure))>0
    and position('greenloop_private.rsbe_current(' in
      pg_get_functiondef('public.get_ready_stock_esim_v1(text,jsonb,integer,boolean)'::regprocedure))>0
  then '20261125-ready-stock-esim-1' end;
$version$;
revoke all on function public.get_ready_stock_esim_version() from public,anon,authenticated;
grant execute on function public.get_ready_stock_esim_version() to anon,authenticated;
do $verify$
begin
  if public.get_ready_stock_esim_version() is distinct from '20261125-ready-stock-esim-1' then
    raise exception 'Ready Stock eSIM installation failed verification.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_ready_stock_esim_version() as installed_ready_stock_esim_version;
