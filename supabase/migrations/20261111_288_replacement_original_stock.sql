-- Replacement intake belongs to its original stock. Internal allocation receipts
-- remain permanent so old returns, one-to-one matches, capacities and audit do not change.
-- One outer statement also remains atomic in SQL clients that execute statements separately.
DO $sro_atomic$
BEGIN
 EXECUTE $sro_body$
set local statement_timeout='120s';
do $$begin
 if public.get_replacement_auto_match_version()is distinct from '20261111-replacement-auto-match-1'then raise exception 'Verify Replacement Auto Match before installing original-stock references.';end if;
 if to_regprocedure('public.get_replacement_original_stock_version()')is not null then if public.get_replacement_original_stock_version()is distinct from '20261111-replacement-original-stock-1'then raise exception 'Existing replacement original-stock integrity needs review.';end if;end if;
end;$$;
create temporary table sro_review(identity text primary key,before_hash text not null)on commit drop;
insert into sro_review select id,md5(pg_get_functiondef(to_regprocedure(id)))from unnest(array['greenloop_private.supplier_return_batch(uuid)','greenloop_private.supplier_return_intake_guard()','greenloop_private.simple_stock_return_model_intake_guard()','greenloop_private.receive_mobile_stock_imei(uuid,text,text,integer,text,smallint,text,text,boolean)','greenloop_private.cap_impl_d78999e342aebe309d9b22270fe6e18c(uuid,text,text,integer,text,smallint)','greenloop_private.src_receipt(uuid)','greenloop_private.cl_allocate_replacement(uuid)','greenloop_private.srp_rows()','greenloop_private.sbn_counts()'])id;
-- Never overwrite an unreviewed newer receiving or return implementation.
do $boundaries$declare r record;begin
 if to_regprocedure('public.get_replacement_original_stock_version()')is null then
  for r in select *from(values
('greenloop_private.supplier_return_batch(uuid)','d886eeca7f08cd464d41e53f7a8f2bf3'),
('greenloop_private.supplier_return_intake_guard()','4151d3bc910a0a7437ab4a034d4554b7'),
('greenloop_private.simple_stock_return_model_intake_guard()','736816cac812fb3e5c294376a9375402'),
('greenloop_private.receive_mobile_stock_imei(uuid,text,text,integer,text,smallint,text,text,boolean)','a91bb0c634edfe17497e2ec5563ae92c'),
('greenloop_private.cap_impl_d78999e342aebe309d9b22270fe6e18c(uuid,text,text,integer,text,smallint)','3fdd1dc25430042bb989fc914f2cdbfd'),
('greenloop_private.src_receipt(uuid)','e3c9b1c369c6c0cf3f5a9a854d13eff3'),
('greenloop_private.cl_allocate_replacement(uuid)','9622c0e60d82bab7482cbb647413886b'),
('greenloop_private.srp_rows()','9683bf9bf8a454ad9f6f9ab4f16071de'),
('greenloop_private.sbn_counts()','f439ea70e0687dcc89dec2f854a766d4')
  ,('greenloop_private.accounts_supplier_rows()','1841f95c932e33ebbc893cf18b706dd8')
  ,('greenloop_private.sga_report(jsonb,boolean,text)','2ea1e4043208f666709eac7dd249770d')
  )x(identity,expected)loop
   if md5(replace(replace(pg_get_functiondef(to_regprocedure(r.identity)),chr(13)||chr(10),chr(10)),chr(13),chr(10)))is distinct from r.expected then raise exception 'Receiving/return definition needs review before replacement repair: %',r.identity;end if;
  end loop;
 end if;
end;$boundaries$;
insert into sro_review values('greenloop_private.accounts_supplier_rows()',md5(pg_get_functiondef('greenloop_private.accounts_supplier_rows()'::regprocedure)));
insert into sro_review values('greenloop_private.sga_report(jsonb,boolean,text)',md5(pg_get_functiondef('greenloop_private.sga_report(jsonb,boolean,text)'::regprocedure)));
do $overview$declare f regprocedure;ddl text;old text:='select sum(planned_quantity)::integer from public.receiving_batches';begin
 select to_regprocedure(implementation)into strict f from greenloop_private.office_routines where to_regprocedure(identity)='public.get_overview_workflow_counts()'::regprocedure;
 ddl:=pg_get_functiondef(f);insert into sro_review values(f::text,md5(ddl));
 if strpos(ddl,'sro-original-purchase-count')=0 then
  if(length(ddl)-length(replace(ddl,old,'')))/length(old)<>1 then raise exception 'Overview stock-count boundary needs review.';end if;
  ddl:=replace(ddl,old,'select sum(planned_quantity)::integer from public.receiving_batches b where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id) /* sro-original-purchase-count */');execute ddl;
 end if;
end;$overview$;
create or replace function greenloop_private.sro_entered_count(p_batch uuid)returns integer language sql stable security definer set search_path=pg_catalog,public as $$
 select count(*)::integer from public.jobs j where j.deleted_at is null and(
  (j.receiving_batch_id=p_batch and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id))
  or exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id and l.replacement_batch_id=p_batch));
$$;
revoke all on function greenloop_private.sro_entered_count(uuid)from public,anon,authenticated;
CREATE OR REPLACE FUNCTION greenloop_private.supplier_return_batch(p_batch uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 select jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'supplier_id',s.id,'supplier_code',s.supplier_code,
  'supplier_name',case when public.get_my_partner_name_access() then s.company_name else null end,
  'received_quantity',b.planned_quantity,'entered_quantity',e.n,'unentered_reserved',r.reserved,'returned_without_imei',r.returned_unentered,
  'returned_quantity',r.returned_all,'held_imei_quantity',r.held_imei,'active_quantity',greatest(e.n-r.held_imei,0),
  'required_quantity',greatest(b.planned_quantity-r.returned_all,0),
  'remaining_quantity',greatest(b.planned_quantity-e.n-r.reserved-r.returned_unentered,0),
  'plan_lines',coalesce((select jsonb_agg(jsonb_build_object('plan_line_id',p.id,'model',p.model,'storage_gb',p.storage_gb,'color',p.color,
    'received_quantity',p.planned_quantity,'entered_quantity',pe.n,'reserved_quantity',pr.reserved,'returned_quantity',pr.returned,
    'remaining_quantity',greatest(p.planned_quantity-pe.n-pr.reserved-pr.returned,0)) order by p.created_at,p.id)
    from public.stock_batch_plan_lines p
    cross join lateral(select count(*)::integer n from public.jobs j join public.devices d on d.id=j.device_id where j.receiving_batch_id=b.id and j.deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id)
      and (p.model is null or lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g'))=lower(p.model))
      and (p.storage_gb is null or p.storage_gb=d.storage_gb) and (p.color is null or lower(regexp_replace(btrim(coalesce(d.color,'')),'\s+',' ','g'))=lower(p.color))) pe
    cross join lateral(select count(*) filter(where t.status in ('requested','approved'))::integer reserved,count(*) filter(where t.status='returned')::integer returned from public.supplier_returns t where t.plan_line_id=p.id and t.device_id is null) pr
    where p.receiving_batch_id=b.id),'[]'::jsonb))
 from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id
 cross join lateral(select greenloop_private.sro_entered_count(b.id) n) e
 cross join lateral(select count(*) filter(where t.device_id is null and t.status in ('requested','approved'))::integer reserved,
  count(*) filter(where t.device_id is null and t.status='returned')::integer returned_unentered,
  count(*) filter(where t.status='returned')::integer returned_all,
  count(*) filter(where t.device_id is not null and t.status in ('requested','approved','returned'))::integer held_imei
  from public.supplier_returns t where t.batch_id=b.id) r
 where b.id=p_batch and b.planned_quantity is not null;
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.supplier_return_intake_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare b public.receiving_batches%rowtype; p public.stock_batch_plan_lines%rowtype; d public.devices%rowtype; n integer; held integer;
begin
 if tg_op='UPDATE'and old.receiving_batch_id is distinct from new.receiving_batch_id and exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=new.id and l.replacement_device_id=new.device_id and l.replacement_batch_id=old.receiving_batch_id and l.root_batch_id=new.receiving_batch_id)then return new;end if;
 if new.receiving_batch_id is null or new.deleted_at is not null then return new; end if;
 if tg_op='UPDATE' and old.receiving_batch_id is not distinct from new.receiving_batch_id and old.deleted_at is null then return new; end if;
 select * into b from public.receiving_batches where id=new.receiving_batch_id for update;
 if b.planned_quantity is null then return new; end if;
 select greenloop_private.sro_entered_count(b.id)into n;
 select count(*) into held from public.supplier_returns where batch_id=b.id and device_id is null and status in ('requested','approved','returned');
 if n+held>=b.planned_quantity then raise exception 'This receipt has no unentered units available; Supplier Returns reserve part of its original quantity.' using errcode='22023'; end if;
 select * into d from public.devices where id=new.device_id;
 for p in select * from public.stock_batch_plan_lines where receiving_batch_id=b.id
  and (model is null or lower(model)=lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g')))
  and (storage_gb is null or storage_gb=d.storage_gb) and (color is null or lower(color)=lower(regexp_replace(btrim(coalesce(d.color,'')),'\s+',' ','g')))
  order by id for update loop
  select count(*) into n from public.jobs j join public.devices x on x.id=j.device_id where j.receiving_batch_id=b.id and j.deleted_at is null and j.id<>new.id and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id)
   and (p.model is null or lower(p.model)=lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g')))
   and (p.storage_gb is null or p.storage_gb=x.storage_gb) and (p.color is null or lower(p.color)=lower(regexp_replace(btrim(coalesce(x.color,'')),'\s+',' ','g')));
  select count(*) into held from public.supplier_returns where plan_line_id=p.id and device_id is null and status in ('requested','approved','returned');
  if n+held>=p.planned_quantity then raise exception 'This plan line has no unentered units available after Supplier Returns.' using errcode='22023'; end if;
 end loop;
 return new;
end; $function$;

CREATE OR REPLACE FUNCTION greenloop_private.simple_stock_return_model_intake_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.devices%rowtype; v_model text; v_capacity integer; v_entered integer; v_returned integer;
begin
 if tg_op='UPDATE'and old.receiving_batch_id is distinct from new.receiving_batch_id and exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=new.id and l.replacement_device_id=new.device_id and l.replacement_batch_id=old.receiving_batch_id and l.root_batch_id=new.receiving_batch_id)then return new;end if;
  if new.receiving_batch_id is null or new.deleted_at is not null then return new; end if;
  if tg_op='UPDATE' and old.receiving_batch_id is not distinct from new.receiving_batch_id and old.deleted_at is null then return new; end if;
  perform 1 from public.receiving_batches where id=new.receiving_batch_id for update;
  select * into d from public.devices where id=new.device_id;
  v_model:=lower(regexp_replace(btrim(coalesce(d.model,'')),'\s+',' ','g'));
  -- GB may be supplied independently of model. A GB-only returned unit
  -- consumes that receipt's GB pool without inventing its model.
  if d.storage_gb is not null and exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=new.receiving_batch_id)
    and not exists(select 1 from public.stock_batch_plan_lines where receiving_batch_id=new.receiving_batch_id and storage_gb is null) then
    select coalesce(sum(planned_quantity),0)::integer into v_capacity from public.stock_batch_plan_lines
      where receiving_batch_id=new.receiving_batch_id and storage_gb=d.storage_gb;
    select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
      where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id) and j.id<>new.id and x.storage_gb=d.storage_gb;
    select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
      where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
        and coalesce(nullif(r.source_snapshot->>'storage_gb','')::integer,p.storage_gb)=d.storage_gb;
    if v_entered+v_returned>=v_capacity then raise exception 'This GB has no unentered units remaining after Stock Returns.' using errcode='22023'; end if;
  end if;
  select sum(p.planned_quantity)::integer into v_capacity from public.stock_batch_plan_lines p
    where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model;
  if v_capacity is null then return new; end if;
  select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
    where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id) and j.id<>new.id
      and lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g'))=v_model;
  select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
    where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
      and lower(regexp_replace(btrim(coalesce(r.model,p.model,'')),'\s+',' ','g'))=v_model;
  if v_entered+v_returned>=v_capacity then
    raise exception 'This model has no unentered units remaining after Stock Returns.' using errcode='22023';
  end if;
  if d.storage_gb is not null and not exists(select 1 from public.stock_batch_plan_lines p
    where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model and p.storage_gb is null) then
    select coalesce(sum(p.planned_quantity),0)::integer into v_capacity from public.stock_batch_plan_lines p
      where p.receiving_batch_id=new.receiving_batch_id and lower(p.model)=v_model and p.storage_gb=d.storage_gb;
    select count(*)::integer into v_entered from public.jobs j join public.devices x on x.id=j.device_id
      where j.receiving_batch_id=new.receiving_batch_id and j.deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=j.id) and j.id<>new.id
        and lower(regexp_replace(btrim(coalesce(x.model,'')),'\s+',' ','g'))=v_model and x.storage_gb=d.storage_gb;
    select count(*)::integer into v_returned from public.supplier_returns r left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
      where r.batch_id=new.receiving_batch_id and r.device_id is null and r.archived_at is null and r.status in ('requested','approved','returned')
        and lower(regexp_replace(btrim(coalesce(r.model,p.model,'')),'\s+',' ','g'))=v_model
        and coalesce(nullif(r.source_snapshot->>'storage_gb','')::integer,p.storage_gb)=d.storage_gb;
    if v_entered+v_returned>=v_capacity then
      raise exception 'This model/GB has no unentered units remaining after Stock Returns.' using errcode='22023';
    end if;
  end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION greenloop_private.receive_mobile_stock_imei(p_batch_id uuid, p_imei_1 text, p_model text, p_storage_gb integer, p_color text, p_battery_health smallint, p_brand text, p_platform text, p_battery_health_unavailable boolean)
 RETURNS TABLE(device_id uuid, device_number text, job_id uuid, job_number text, existing_device boolean, entered_quantity integer, planned_quantity integer, remaining_quantity integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_imei text := nullif(btrim(p_imei_1), '');
  v_model text := nullif(regexp_replace(btrim(p_model), '\s+', ' ', 'g'), '');
  v_color text := nullif(regexp_replace(btrim(p_color), '\s+', ' ', 'g'), '');
  v_batch record;
  v_entered integer;
  v_receiving_location_id uuid;
  v_device_id uuid;
  v_device_number text;
  v_job_id uuid;
  v_job_number text;
  v_previous_location_id uuid;
  v_existing boolean := false;
  v_job_type public.job_type;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform public.greenloop_require_entry(array['imei_entry']::text[]);
  if not coalesce(public.has_page_edit_access('imei_entry'),false) then raise exception 'IMEI Entry edit permission is required.' using errcode='42501'; end if;
  if not public.has_role(array['super_admin', 'owner', 'manager', 'receiving', 'rma']::public.app_role_key[]) then
    raise exception 'You do not have permission to receive stock.' using errcode = '42501';
  end if;
  if v_imei is null or v_imei !~ '^[0-9]{15}$' then
    raise exception 'Scan a valid 15-digit IMEI.' using errcode = '22023';
  end if;
  if v_model is null then
    raise exception 'Model is required.' using errcode = '22023';
  end if;
  if p_storage_gb is null or p_storage_gb <= 0 then
    raise exception 'Storage (GB) is required.' using errcode = '22023';
  end if;
  if v_color is null then
    raise exception 'Color is required.' using errcode = '22023';
  end if;
  perform greenloop_private.validate_mobile_identity(p_brand,p_platform);
  perform greenloop_private.validate_mobile_battery(p_platform,p_battery_health,p_battery_health_unavailable,true);

  select batch.id, batch.batch_number, batch.receiving_source, batch.notes,
         batch.planned_quantity, batch.supplier_id
  into v_batch
  from public.receiving_batches batch
  where batch.id = p_batch_id and batch.planned_quantity is not null
  for update;
  if v_batch.id is null then
    raise exception 'The selected stock batch was not found.' using errcode = '22023';
  end if;

  select greenloop_private.sro_entered_count(v_batch.id)into v_entered;
  if v_entered + (select count(*) from public.supplier_returns r where r.batch_id=p_batch_id and r.device_id is null and r.status in ('requested','approved','returned')) >= v_batch.planned_quantity then
    raise exception 'This stock batch is already complete.' using errcode = '22023';
  end if;

  select location.id into v_receiving_location_id
  from public.locations location
  where location.location_code = 'RECEIVING' and location.is_active;
  if v_receiving_location_id is null then
    raise exception 'Receiving location is not configured.' using errcode = '22023';
  end if;

  select device.id, device.device_number, device.current_location_id
  into v_device_id, v_device_number, v_previous_location_id
  from public.devices device
  where (device.imei_1 = v_imei or device.imei_2 = v_imei)
    and device.deleted_at is null
  limit 1
  for update;

  v_existing := v_device_id is not null;
  if v_existing then
    update public.devices
    set model = v_model,
        brand = btrim(p_brand), device_platform = p_platform, battery_health_unavailable = coalesce(p_battery_health_unavailable,false),
        storage_gb = p_storage_gb,
        color = v_color,
        battery_health = p_battery_health,
        current_owner_type = 'company_owned',
        current_owner_customer_id = null,
        current_location_id = v_receiving_location_id,
        current_status = 'initial_qc_pending',
        notes = coalesce(v_batch.notes, notes)
    where id = v_device_id;
  else
    insert into public.devices as device (
      device_number, imei_1, model, storage_gb, color, battery_health, brand, device_platform, battery_health_unavailable,
      current_owner_type, current_location_id, current_status, notes, created_by
    )
    values (
      null, v_imei, v_model, p_storage_gb, v_color, p_battery_health, btrim(p_brand), p_platform, coalesce(p_battery_health_unavailable,false),
      'company_owned', v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
    )
    returning device.id, device.device_number into v_device_id, v_device_number;
  end if;

  v_job_type := case when lower(v_batch.receiving_source) = 'rma' then 'rma'::public.job_type else 'company_refurbishment'::public.job_type end;
  insert into public.jobs as job (
    job_number, device_id, job_type, ownership_type, supplier_id,
    receiving_source, purchase_cost, received_by, receiving_batch_id,
    current_location_id, current_status, notes, created_by
  )
  values (
    null, v_device_id, v_job_type, 'company_owned', v_batch.supplier_id,
    v_batch.receiving_source, 0, auth.uid(), v_batch.id,
    v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
  )
  returning job.id, job.job_number into v_job_id, v_job_number;

  insert into public.device_location_history (
    device_id, job_id, from_location_id, to_location_id, movement_reason, notes, moved_by
  )
  values (
    v_device_id, v_job_id, v_previous_location_id, v_receiving_location_id,
    case when v_existing then 'Stock batch IMEI received as new job' else 'Stock batch IMEI received' end,
    v_batch.notes, auth.uid()
  );

  insert into public.device_events (device_id, job_id, event_type, event_title, event_data, actor_id)
  values (
    v_device_id, v_job_id, 'stock_batch_imei_received', 'IMEI received into stock batch',
    jsonb_build_object('batch_number', v_batch.batch_number, 'stock_channel', v_batch.receiving_source, 'brand', btrim(p_brand), 'device_platform', p_platform, 'battery_health', p_battery_health, 'battery_health_unavailable', coalesce(p_battery_health_unavailable,false)), auth.uid()
  );

  v_entered := v_entered + 1;
  return query select v_device_id, v_device_number, v_job_id, v_job_number, v_existing,
    v_entered, v_batch.planned_quantity, (greenloop_private.supplier_return_batch(p_batch_id)->>'remaining_quantity')::integer;
end;
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.cap_impl_d78999e342aebe309d9b22270fe6e18c(p_batch_id uuid, p_imei_1 text, p_model text, p_storage_gb integer, p_color text, p_battery_health smallint)
 RETURNS TABLE(device_id uuid, device_number text, job_id uuid, job_number text, existing_device boolean, entered_quantity integer, planned_quantity integer, remaining_quantity integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_imei text := nullif(btrim(p_imei_1), '');
  v_model text := nullif(regexp_replace(btrim(p_model), '\s+', ' ', 'g'), '');
  v_color text := nullif(regexp_replace(btrim(p_color), '\s+', ' ', 'g'), '');
  v_batch record;
  v_entered integer;
  v_receiving_location_id uuid;
  v_device_id uuid;
  v_device_number text;
  v_job_id uuid;
  v_job_number text;
  v_previous_location_id uuid;
  v_existing boolean := false;
  v_job_type public.job_type;
begin
  if not coalesce(public.has_page_edit_access('imei_entry'),false) then raise exception 'IMEI Entry edit permission is required.' using errcode='42501'; end if;
  if not public.has_role(array['super_admin', 'owner', 'manager', 'receiving', 'rma']::public.app_role_key[]) then
    raise exception 'You do not have permission to receive stock.' using errcode = '42501';
  end if;
  if v_imei is null or v_imei !~ '^[0-9]{15}$' then
    raise exception 'Scan a valid 15-digit IMEI.' using errcode = '22023';
  end if;
  if v_model is null then
    raise exception 'Model is required.' using errcode = '22023';
  end if;
  if p_storage_gb is null or p_storage_gb <= 0 then
    raise exception 'Storage (GB) is required.' using errcode = '22023';
  end if;
  if v_color is null then
    raise exception 'Color is required.' using errcode = '22023';
  end if;
  if p_battery_health is null or p_battery_health not between 0 and 100 then
    raise exception 'Battery health must be between 0 and 100.' using errcode = '22023';
  end if;

  select batch.id, batch.batch_number, batch.receiving_source, batch.notes,
         batch.planned_quantity, batch.supplier_id
  into v_batch
  from public.receiving_batches batch
  where batch.id = p_batch_id and batch.planned_quantity is not null
  for update;
  if v_batch.id is null then
    raise exception 'The selected stock batch was not found.' using errcode = '22023';
  end if;

  select greenloop_private.sro_entered_count(v_batch.id)into v_entered;
  if v_entered + (select count(*) from public.supplier_returns r where r.batch_id=p_batch_id and r.device_id is null and r.status in ('requested','approved','returned')) >= v_batch.planned_quantity then
    raise exception 'This stock batch is already complete.' using errcode = '22023';
  end if;

  select location.id into v_receiving_location_id
  from public.locations location
  where location.location_code = 'RECEIVING' and location.is_active;
  if v_receiving_location_id is null then
    raise exception 'Receiving location is not configured.' using errcode = '22023';
  end if;

  select device.id, device.device_number, device.current_location_id
  into v_device_id, v_device_number, v_previous_location_id
  from public.devices device
  where (device.imei_1 = v_imei or device.imei_2 = v_imei)
    and device.deleted_at is null
  limit 1
  for update;

  v_existing := v_device_id is not null;
  if v_existing then
    update public.devices
    set model = v_model,
        storage_gb = p_storage_gb,
        color = v_color,
        battery_health = p_battery_health,
        current_owner_type = 'company_owned',
        current_owner_customer_id = null,
        current_location_id = v_receiving_location_id,
        current_status = 'initial_qc_pending',
        notes = coalesce(v_batch.notes, notes)
    where id = v_device_id;
  else
    insert into public.devices as device (
      device_number, imei_1, model, storage_gb, color, battery_health,
      current_owner_type, current_location_id, current_status, notes, created_by
    )
    values (
      null, v_imei, v_model, p_storage_gb, v_color, p_battery_health,
      'company_owned', v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
    )
    returning device.id, device.device_number into v_device_id, v_device_number;
  end if;

  v_job_type := case when lower(v_batch.receiving_source) = 'rma' then 'rma'::public.job_type else 'company_refurbishment'::public.job_type end;
  insert into public.jobs as job (
    job_number, device_id, job_type, ownership_type, supplier_id,
    receiving_source, purchase_cost, received_by, receiving_batch_id,
    current_location_id, current_status, notes, created_by
  )
  values (
    null, v_device_id, v_job_type, 'company_owned', v_batch.supplier_id,
    v_batch.receiving_source, 0, auth.uid(), v_batch.id,
    v_receiving_location_id, 'initial_qc_pending', v_batch.notes, auth.uid()
  )
  returning job.id, job.job_number into v_job_id, v_job_number;

  insert into public.device_location_history (
    device_id, job_id, from_location_id, to_location_id, movement_reason, notes, moved_by
  )
  values (
    v_device_id, v_job_id, v_previous_location_id, v_receiving_location_id,
    case when v_existing then 'Stock batch IMEI received as new job' else 'Stock batch IMEI received' end,
    v_batch.notes, auth.uid()
  );

  insert into public.device_events (device_id, job_id, event_type, event_title, event_data, actor_id)
  values (
    v_device_id, v_job_id, 'stock_batch_imei_received', 'IMEI received into stock batch',
    jsonb_build_object('batch_number', v_batch.batch_number, 'stock_channel', v_batch.receiving_source), auth.uid()
  );

  v_entered := v_entered + 1;
  return query select v_device_id, v_device_number, v_job_id, v_job_number, v_existing,
    v_entered, v_batch.planned_quantity, (greenloop_private.supplier_return_batch(p_batch_id)->>'remaining_quantity')::integer;
end;
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.src_receipt(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare b public.receiving_batches%rowtype;r record;entered bigint;reserved bigint;planned bigint;basis jsonb;
begin
 select *into b from public.receiving_batches where id=p_batch_id;
 if not found or b.planned_quantity is null then raise exception 'Select a stock receipt with a recorded received quantity.'using errcode='22023';end if;
 select *into r from greenloop_private.sc_receipts()where batch_id=b.id;
 select count(*)into entered from public.jobs where receiving_batch_id=b.id and deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=public.jobs.id);
 select count(*)into reserved from public.supplier_returns where batch_id=b.id and device_id is null and status in('requested','approved','returned');
 select coalesce(sum(planned_quantity),0)into planned from public.stock_batch_plan_lines where receiving_batch_id=b.id;
 basis:=jsonb_build_object('receipt',to_jsonb(b),'entered',entered,'reserved',reserved,'plan_quantity',planned,
  'return_state',coalesce((select jsonb_agg(to_jsonb(x)order by x.id)from public.supplier_returns x where x.batch_id=b.id),'[]'),
  'replacement_state',coalesce((select jsonb_agg(to_jsonb(x)order by x.replacement_batch_id)from greenloop_private.srp_receipts x where x.original_batch_id=b.id or x.replacement_batch_id=b.id),'[]'));
 return jsonb_build_object('batch_id',b.id,'supplier_id',b.supplier_id,'supplier_code',r.supplier_code,'supplier_name',r.supplier_name,
  'batch_number',b.batch_number,'invoice_number',b.invoice_number,'received_at',b.received_at,'quantity',b.planned_quantity,
  'entered',entered,'reserved',reserved,'planned',planned,'minimum_quantity',greatest(entered+reserved,planned,coalesce(r.returned_quantity,0)),
  'returned',r.returned_quantity,'replacement_received',r.replacement_quantity,'balance',r.balance_quantity,'parent_batch_id',r.parent_batch_id,
  'pending_imei',greatest(0,b.planned_quantity-entered-reserved),'snapshot',md5(basis::text));
end;$function$;

CREATE OR REPLACE FUNCTION greenloop_private.cl_allocate_replacement(p_job uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare j public.jobs%rowtype;a record;parent greenloop_private.srp_phone_links%rowtype;k text;begin
 select *into j from public.jobs where id=p_job;
 if j.id is null or not exists(select 1 from greenloop_private.srp_receipts where replacement_batch_id=j.receiving_batch_id)or exists(select 1 from greenloop_private.srp_phone_links where replacement_job_id=j.id)then return;end if;
 perform pg_advisory_xact_lock(hashtext('replacement-phone:'||j.receiving_batch_id::text));
 select r.id,r.batch_id,r.device_id into a from greenloop_private.srp_receipts p
 join greenloop_private.srp_allocations x on x.receipt_id=p.id
 join public.supplier_returns r on r.id=x.return_id
 where p.replacement_batch_id=j.receiving_batch_id and not exists(select 1 from greenloop_private.srp_phone_links l where l.return_id=r.id)
 order by r.requested_at,r.return_number,r.id limit 1;
 if a.id is null then raise exception 'No unassigned return slot remains for this replacement receipt.'using errcode='23514';end if;
 k:=case when a.device_id is null then 'return:'||a.id::text else 'phone:'||a.batch_id::text||':'||a.device_id::text end;
 select *into parent from greenloop_private.srp_phone_links where replacement_device_id=a.device_id;
 insert into greenloop_private.srp_phone_links(return_id,replacement_batch_id,replacement_job_id,replacement_device_id,return_record_key,root_record_key,root_batch_id)
 values(a.id,j.receiving_batch_id,j.id,j.device_id,k,coalesce(parent.root_record_key,k),coalesce(parent.root_batch_id,a.batch_id));
end;$function$;

CREATE OR REPLACE FUNCTION greenloop_private.srp_rows()
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 select g||jsonb_build_object('replacement_received',a.received,'replacement_pending',a.pending,'other_settled',a.other_settled,
  'status',case when a.pending>0 and a.received>0 then 'Partially received'when a.pending>0 then 'Awaiting replacement'when a.received>0 then 'Replacement received'else 'Already settled'end,
  'receipts',coalesce(h.receipts,'[]'::jsonb))
 from jsonb_array_elements(public.list_active_stock_returns(null,null))g
 cross join lateral(select count(*)filter(where al.return_id is not null)::integer received,
  count(*)filter(where al.return_id is null and r.settled_at is null and r.settlement_type is null)::integer pending,
  count(*)filter(where al.return_id is null and(r.settled_at is not null or r.settlement_type is not null))::integer other_settled
  from jsonb_array_elements_text(g->'return_ids')i join public.supplier_returns r on r.id=i.value::uuid
  left join greenloop_private.srp_allocations al on al.return_id=r.id
  where r.archived_at is null and r.status='returned')a
 left join lateral(select jsonb_agg(jsonb_build_object('receipt_id',p.id,'batch_id',p.replacement_batch_id,'batch_number',p.response->>'batch_number',
  'invoice_number',p.response->>'invoice_number','quantity',p.quantity,'received_at',p.received_at,'received_by',coalesce(u.full_name,u.login_username,'Staff'),
  'receipt_available',b.id is not null,'notes',p.command->>'notes',
  'phones',coalesce((select jsonb_agg(v order by v->>'imei')from(select distinct on(d.id)jsonb_build_object('imei',d.imei_1,'model',d.model,'gb',d.storage_gb,'color',d.color,'stage',j.current_status)v
   from public.jobs j join public.devices d on d.id=j.device_id where exists(select 1 from greenloop_private.srp_phone_links l join greenloop_private.srp_allocations a on a.return_id=l.return_id where l.replacement_job_id=j.id and a.receipt_id=p.id) and j.deleted_at is null and d.deleted_at is null order by d.id,j.created_at desc,j.id desc)x),'[]'::jsonb)
  )order by p.received_at desc,p.id)receipts from greenloop_private.srp_receipts p left join public.receiving_batches b on b.id=p.replacement_batch_id
  left join public.user_profiles u on u.id=p.actor_id where p.group_id=(g->>'group_id')::uuid)h on true;
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.sbn_counts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
-- greenloop-shared-ready-count-276
declare result jsonb:='{}';qc jsonb;n bigint;
begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())then raise exception 'Active staff access required.'using errcode='42501';end if;
 if greenloop_private.sbn_can('stock_received')then
  select coalesce(sum(planned_quantity),0)into n from public.receiving_batches b where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id);
  result:=result||jsonb_build_object('stock_received',n);
 end if;
 if greenloop_private.sbn_can('imei_entry')then
  -- Use the same eligible receipts and return-adjusted balance as the IMEI Entry selector.
  select coalesce(sum(remaining_quantity),0)into n from public.get_open_stock_entry_batches_with_lines();
  result:=result||jsonb_build_object('imei_entry',n);
 end if;
 if greenloop_private.sbn_can('initial_qc')then
  qc:=greenloop_private.qcn_counts();result:=result||qc;
 end if;
 if greenloop_private.sbn_can('qc_issuance')then
 select count(*)into n from greenloop_private.qcis_rows(null);result:=result||jsonb_build_object('qc_issuance',n);
 elsif not greenloop_private.sbn_can('initial_qc')then result:=result-'qc_issuance';end if;
 if greenloop_private.sbn_can('lab_glass')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department in('laboratory','glass')and s.step_status='in_progress'and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress','parts_pending');
  result:=result||jsonb_build_object('lab_glass',n);
 end if;
 if greenloop_private.sbn_can('parts')then
  select count(distinct imei)into n from(
   select d.imei_1 imei from greenloop_private.parts_flow_orders o join greenloop_private.parts_flow_requests m on m.order_id=o.id join public.job_part_requests p on p.id=m.request_id join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null
   where o.completed_at is null and o.cycle=greenloop_private.pf_cycle(o.job_id)and j.current_status in('laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress')and p.status<>'cancelled'and p.quantity_requested>p.quantity_issued
   union select imei from greenloop_private.pp_returns()where status='pending')pending;
  result:=result||jsonb_build_object('parts',n);
 end if;
 if greenloop_private.sbn_can('final_qc')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='final_qc'and s.step_status='in_progress'and j.current_status in('final_qc_pending','qc_failed');
  result:=result||jsonb_build_object('final_qc',n);
 end if;
 if greenloop_private.sbn_can('frame_department')then
  select count(distinct d.id)into n from public.job_work_order_steps s join public.job_work_orders w on w.id=s.work_order_id join public.jobs j on j.id=w.job_id and j.deleted_at is null join public.devices d on d.id=j.device_id and d.deleted_at is null
  where s.department='frame'and s.step_status='in_progress'and j.current_status in('frame_pending','frame_in_progress');
  result:=result||jsonb_build_object('frame',n);
 end if;
 if greenloop_private.sbn_can('ready_stock')then
  n:=greenloop_private.drc_ready_count();
  result:=result||jsonb_build_object('ready_stock',n);
 end if;
 if greenloop_private.sbn_can('accounts')then
  select count(*)into n from greenloop_private.box_workflow w join public.export_boxes b on b.id=w.box_id where w.state='accounts';
  result:=result||jsonb_build_object('accounts',n);
 end if;
 if greenloop_private.sbn_can('export_boxes')then
  select count(*)into n from public.export_boxes b left join greenloop_private.box_workflow w on w.box_id=b.id
  where coalesce(w.state,case when b.box_status='open'then 'draft'else 'legacy'end)in('draft','recheck')and exists(select 1 from public.export_box_items i where i.box_id=b.id);
  result:=result||jsonb_build_object('box_entry',n);
 end if;
 if greenloop_private.sbn_can('stock_exported')then
  select count(distinct i.device_id)into n from public.export_box_items i join greenloop_private.box_workflow w on w.box_id=i.box_id and w.state='exported'join public.jobs j on j.id=i.job_id and j.deleted_at is null join public.devices d on d.id=i.device_id and d.deleted_at is null where j.current_status='shipped';
  result:=result||jsonb_build_object('stock_exported',n);
 end if;
 if greenloop_private.sbn_can('ready_stock_journey')then
  select count(distinct d.id)into n from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null where j.deleted_at is null;
  result:=result||jsonb_build_object('stock_journey',n);
 end if;
 if greenloop_private.sbn_can('supplier_returns')then
  select count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))into n from public.supplier_returns where archived_at is null and status in('requested','approved');
  result:=result||jsonb_build_object('supplier_returns',n);
 end if;
 return result;
end;$function$;

-- Original records, returns, allocations and all workflow stages remain intact.
-- Only the replacement job's stock ownership changes; every move is audited.
create table if not exists greenloop_private.sro_rehomes(
 job_id uuid primary key,device_id uuid not null,intake_batch_id uuid not null,original_batch_id uuid not null,
 before_job jsonb not null,after_job jsonb not null,recorded_at timestamptz not null default now());
alter table greenloop_private.sro_rehomes enable row level security;
revoke all on greenloop_private.sro_rehomes from public,anon,authenticated;
drop trigger if exists sro_rehomes_immutable on greenloop_private.sro_rehomes;
create trigger sro_rehomes_immutable before update or delete on greenloop_private.sro_rehomes for each row execute function greenloop_private.srp_immutable();
CREATE OR REPLACE FUNCTION greenloop_private.accounts_supplier_rows()
 RETURNS TABLE(supplier_id uuid, supplier_code text, supplier_name text, batch_id uuid, batch_number text, invoice_number text, received_at timestamp with time zone, model text, storage_gb integer, color text, received bigint, in_company bigint, ready bigint, in_process bigint, exported bigint, returned bigint, awaiting_imei bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 with entered as materialized (
  select j.id,j.receiving_batch_id batch_id,coalesce(j.supplier_id,b.supplier_id) supplier_id,j.received_at,j.current_status::text status,
   d.model,d.storage_gb,d.color,matched.id plan_id,
   case when j.current_status::text='returned_to_supplier' then 'returned'
    when w.state in ('exported','legacy') or (w.box_id is null and j.current_status::text='shipped') then 'exported'
    when w.state in ('draft','accounts') then 'process'
    when j.current_status::text in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
     and exists(select 1 from public.final_qc_inspections f where f.job_id=j.id and f.result='pass') then 'ready'
    else 'process' end bucket
  from public.jobs j join public.devices d on d.id=j.device_id left join public.receiving_batches b on b.id=j.receiving_batch_id
  left join lateral(select x.* from public.stock_batch_plan_lines x where x.receiving_batch_id=j.receiving_batch_id
   and (x.model is null or lower(btrim(x.model))=lower(btrim(d.model))) and (x.storage_gb is null or x.storage_gb=d.storage_gb)
   and (x.color is null or lower(btrim(x.color))=lower(btrim(d.color)))
   order by (x.model is not null)::integer+(x.storage_gb is not null)::integer+(x.color is not null)::integer desc,x.created_at,x.id limit 1) matched on true
  left join public.export_box_items i on i.job_id=j.id left join greenloop_private.box_workflow w on w.box_id=i.box_id
  where j.deleted_at is null and d.deleted_at is null
 ), batch_totals as materialized (
  select b.*,greatest(coalesce(b.planned_quantity,0)-greenloop_private.sro_entered_count(b.id)
   -(select count(*) from public.supplier_returns r where r.batch_id=b.id and r.device_id is null and r.archived_at is null and r.status='returned'),0)::bigint remaining
  from public.receiving_batches b where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id)
 ), plan_capacity as (
  select p.*,greatest(p.planned_quantity-(select count(*) from entered e where e.plan_id=p.id and not exists(select 1 from greenloop_private.srp_phone_links l where l.replacement_job_id=e.id))
   -(select count(*) from public.supplier_returns r where r.plan_line_id=p.id and r.device_id is null and r.archived_at is null and r.status='returned'),0)::bigint capacity
  from public.stock_batch_plan_lines p
 ), plan_remaining as (
  select p.*,least(capacity,greatest(b.remaining-coalesce(sum(capacity) over(partition by p.receiving_batch_id order by p.created_at,p.id rows between unbounded preceding and 1 preceding),0),0))::bigint quantity
  from plan_capacity p join batch_totals b on b.id=p.receiving_batch_id
 ), units as (
  select e.supplier_id,e.batch_id,e.received_at,e.model,e.storage_gb,e.color,e.bucket,1::bigint quantity from entered e
  union all select b.supplier_id,b.id,b.received_at,p.model,p.storage_gb,p.color,'unentered',p.quantity from plan_remaining p join batch_totals b on b.id=p.receiving_batch_id where p.quantity>0
  union all select b.supplier_id,b.id,b.received_at,b.planned_model,null::integer,null::text,'unentered',b.remaining-coalesce((select sum(p.quantity) from plan_remaining p where p.receiving_batch_id=b.id),0)::bigint
   from batch_totals b where b.remaining>coalesce((select sum(p.quantity) from plan_remaining p where p.receiving_batch_id=b.id),0)
  union all select b.supplier_id,b.id,b.received_at,p.model,p.storage_gb,p.color,'returned',1::bigint
   from public.supplier_returns r join public.receiving_batches b on b.id=r.batch_id left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
   where r.device_id is null and r.archived_at is null and r.status='returned'
 )
 select s.id,s.supplier_code,case when public.get_my_partner_name_access() then s.company_name end,b.id,b.batch_number,b.invoice_number,coalesce(b.received_at,min(u.received_at)),
  coalesce(nullif(btrim(u.model),''),'Not entered'),u.storage_gb,coalesce(nullif(btrim(u.color),''),'Not recorded'),sum(u.quantity)::bigint,
  coalesce(sum(u.quantity) filter(where bucket in ('ready','process','unentered')),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='ready'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket in ('process','unentered')),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='exported'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='returned'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='unentered'),0)::bigint
 from units u left join public.receiving_batches b on b.id=u.batch_id left join public.suppliers s on s.id=u.supplier_id
 group by s.id,s.supplier_code,s.company_name,b.id,b.batch_number,b.invoice_number,b.received_at,coalesce(nullif(btrim(u.model),''),'Not entered'),u.storage_gb,coalesce(nullif(btrim(u.color),''),'Not recorded');
$function$;

CREATE OR REPLACE FUNCTION greenloop_private.sga_report(f jsonb, download boolean, expected text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);catalogue jsonb;stocks jsonb;rows jsonb;totals jsonb;other jsonb;selected boolean;result jsonb;snapshot text;
begin
 selected:=exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null);
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity stock_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id))
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by received_at desc,batch_id)from b),'[]'))into catalogue;
 select coalesce(jsonb_agg(b order by b->>'batch_number'),'[]')into stocks from jsonb_array_elements(catalogue->'batches')b where selected and(nullif(f->>'supplier_id','')is null or b->>'supplier_id'=f->>'supplier_id')and(nullif(f->>'batch_id','')is null or b->>'batch_id'=f->>'batch_id')and(nullif(f->>'invoice_number','')is null or b->>'invoice_number'=f->>'invoice_number');
 if selected and jsonb_array_length(stocks)=0 then raise exception 'No stock matches this supplier, batch and invoice. Refresh the selection.'using errcode='22023';end if;
 if selected then
  with p as materialized(select *from greenloop_private.sga_rows(f)),groups as(
   select p.model,count(*)qty,count(*)filter(where not qc_pending and grade='A')a,count(*)filter(where not qc_pending and grade='B')b,count(*)filter(where not qc_pending and grade='D')d,
    count(*)filter(where not qc_pending and grade not in('A','B','D'))other,count(*)filter(where qc_pending)pending,count(*)filter(where glass)glass,count(*)filter(where polish)polish,count(*)filter(where returned)returned
   from p group by p.model
  )select coalesce((select jsonb_agg(to_jsonb(g)order by model)from groups g),'[]'),jsonb_build_object('qty',count(*),'a',count(*)filter(where not qc_pending and grade='A'),'b',count(*)filter(where not qc_pending and grade='B'),'d',count(*)filter(where not qc_pending and grade='D'),'other',count(*)filter(where not qc_pending and grade not in('A','B','D')),'pending',count(*)filter(where qc_pending),'glass',count(*)filter(where glass),'polish',count(*)filter(where polish),'returned',count(*)filter(where returned)),
   coalesce((select jsonb_agg(to_jsonb(x)order by grade)from(select grade,count(*)qty from p where not qc_pending and grade not in('A','B','D')group by grade)x),'[]')into rows,totals,other from p;
 else rows:='[]';totals:='{"qty":0,"a":0,"b":0,"d":0,"other":0,"pending":0,"glass":0,"polish":0,"returned":0}';other:='[]';end if;
 totals:=totals||jsonb_build_object('stock_quantity',coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0),'unentered',greatest(0,coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0)-(totals->>'qty')::bigint));
 result:=jsonb_build_object('receipt_summary',greenloop_private.sc_summary(array(select(s->>'batch_id')::uuid from jsonb_array_elements(stocks)s)),'selected',selected,'filters',f,'stocks',stocks,'rows',rows,'totals',totals,'other_grades',other,'names_allowed',names);
 snapshot:=md5(result::text);
 if download and(expected is null or expected is distinct from snapshot)then raise exception 'The stock analysis changed. Refresh it before creating the PDF.'using errcode='40001';end if;
 return result||jsonb_build_object('catalogue',catalogue,'snapshot',snapshot,'generated_at',now());
end;$function$;

create or replace function greenloop_private.sro_rehome(p_job uuid)returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.jobs%rowtype;l greenloop_private.srp_phone_links%rowtype;b public.receiving_batches%rowtype;updated public.jobs%rowtype;
begin
 select *into l from greenloop_private.srp_phone_links where replacement_job_id=p_job;
 if l.return_id is null then return;end if;
 select *into j from public.jobs where id=p_job for update;
 if j.id is null or j.deleted_at is not null or j.receiving_batch_id=l.root_batch_id then return;end if;
 if j.receiving_batch_id is distinct from l.replacement_batch_id or j.device_id is distinct from l.replacement_device_id then raise exception 'Replacement stock ownership differs. Review it before installation.'using errcode='23514';end if;
 select *into b from public.receiving_batches where id=l.root_batch_id;
 if b.id is null or b.supplier_id is distinct from j.supplier_id or not exists(select 1 from greenloop_private.sc_receipts()r where r.batch_id=b.id and l.replacement_batch_id=any(r.descendant_ids))then raise exception 'Original replacement stock could not be verified.'using errcode='23514';end if;
 -- Do not reopen, release or alter a held/returned phone or a saved export box.
 if exists(select 1 from public.supplier_returns r where r.device_id=j.device_id and r.archived_at is null and r.status in('requested','approved','returned'))or exists(select 1 from public.export_box_items i where i.job_id=j.id)then raise exception 'A replacement already has a supplier return or a box assignment. Original-stock repair needs review; nothing was changed.'using errcode='55000';end if;
 update public.jobs set receiving_batch_id=b.id where id=j.id and receiving_batch_id=l.replacement_batch_id returning *into updated;
 if updated.id is null then raise exception 'Replacement stock changed during repair.'using errcode='40001';end if;
 insert into greenloop_private.sro_rehomes(job_id,device_id,intake_batch_id,original_batch_id,before_job,after_job)values(j.id,j.device_id,l.replacement_batch_id,b.id,to_jsonb(j),to_jsonb(updated));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(j.device_id,j.id,'replacement_original_stock','Replacement linked to original stock',jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'supplier_code',(select supplier_code from public.suppliers where id=b.supplier_id),'receipt_quantity',b.planned_quantity,'replacement_intake_id',l.replacement_batch_id,'return_id',l.return_id),auth.uid());
end;$$;
create or replace function greenloop_private.sro_arrival()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.sro_rehome(new.id);return new;end;$$;
revoke all on function greenloop_private.sro_rehome(uuid),greenloop_private.sro_arrival()from public,anon,authenticated;
drop trigger if exists zzz_sro_original_stock on public.jobs;
create trigger zzz_sro_original_stock after insert on public.jobs for each row execute function greenloop_private.sro_arrival();
create or replace function greenloop_private.srma_plan(p_supplier uuid,p_batch uuid,p_phones jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;v jsonb;c jsonb;choices jsonb;rows jsonb:='[]';used uuid[]:='{}';imeis text[]:='{}';imei text;m text;col text;gb integer;why text;n integer:=0;ok boolean:=true;
begin
 perform greenloop_private.srp_access('replacement_entry');
 if jsonb_typeof(p_phones)is distinct from 'array'or jsonb_array_length(p_phones)not between 1 and 1000 then raise exception 'Add 1 to 1000 replacement phones.'using errcode='22023';end if;
 select *into b from public.receiving_batches where id=p_batch and supplier_id=p_supplier;
 if b.id is null or b.planned_quantity is null or not exists(select 1 from public.suppliers where id=p_supplier and deleted_at is null and is_active)then raise exception 'Select a supplier and its original stock.'using errcode='22023';end if;
 select coalesce(jsonb_agg(x),'[]')into choices from greenloop_private.srma_candidates(b.id)x;
 for v in select value from jsonb_array_elements(p_phones)loop
  n:=n+1;c:=null;why:=null;imei:=btrim(v->>'imei');m:=btrim(v->>'model');col:=coalesce(btrim(v->>'color'),'');gb:=null;
  if jsonb_typeof(v)is distinct from 'object'or exists(select 1 from jsonb_object_keys(v)k where k<>all(array['imei','model','storage_gb','color']))then raise exception 'Use supported replacement fields.'using errcode='22023';end if;
  if imei is null or imei!~'^[0-9]{15}$'then why:='Enter a complete 15-digit new IMEI.';
  elsif imei=any(imeis)then why:='Duplicate new IMEI in this list.';
  elsif exists(select 1 from public.devices where imei_1=imei or imei_2=imei)or exists(select 1 from public.supplier_returns where imei_1=imei and archived_at is null and status in('requested','approved','returned'))then why:='This IMEI already belongs to a saved or returned phone.';
  elsif exists(select 1 from greenloop_private.srma_pairs where new_imei=imei)then why:='This IMEI is already reserved for a replacement receipt.';
  elsif nullif(m,'')is null or length(m)>120 or length(col)>120 or coalesce(v->>'storage_gb','')!~'^[0-9]{1,5}$'then why:='Enter Model and GB to match a returned phone. Color is optional.';
  else
   gb:=(v->>'storage_gb')::integer;
   if gb not between 1 and 16384 then why:='Choose valid storage.';
   else
    select x into c from jsonb_array_elements(choices)x where not((x->>'return_id')::uuid=any(used))and greenloop_private.srma_model(x->>'model')=greenloop_private.srma_model(m)
     and (x->>'storage_gb')::integer=gb
     order by (x->>'returned_at')::timestamptz,(x->>'return_id')::uuid limit 1;
    if c is null then why:='No unmatched returned phone in this batch has the same Model and GB. Missing return Model or GB cannot be assumed.';end if;
   end if;
  end if;
  if imei is not null then imeis:=array_append(imeis,imei);end if;
  if why is null then used:=array_append(used,(c->>'return_id')::uuid);else ok:=false;end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('line',n,'imei',imei,'model',m,'storage_gb',gb,'color',col,'matched',why is null,'reason',coalesce(why,'Matched oldest pending return'),
   'return_id',c->'return_id','group_id',c->'group_id','old_imei',c->'old_imei','return_reference',c->'return_reference','batch_number',b.batch_number,'received_quantity',b.planned_quantity));
 end loop;
 return jsonb_build_object('rows',rows,'all_matched',ok,'snapshot',md5(jsonb_build_object('supplier',p_supplier,'batch',p_batch,'rows',rows)::text));
end;$$;
create or replace function greenloop_private.srma_intake()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare p greenloop_private.srma_pairs%rowtype;d public.devices%rowtype;r public.supplier_returns%rowtype;parent greenloop_private.srp_phone_links%rowtype;k text;
begin
 select *into d from public.devices where id=new.device_id;
 select *into p from greenloop_private.srma_pairs where new_imei in(d.imei_1,d.imei_2);
 if p.new_imei is null then
  if exists(select 1 from greenloop_private.srma_pairs where replacement_batch_id=new.receiving_batch_id)then raise exception 'This matched replacement receipt only accepts its reserved new IMEIs.'using errcode='22023';end if;
  return new;
 end if;
 if new.receiving_batch_id is distinct from p.replacement_batch_id or d.imei_1 is distinct from p.new_imei then raise exception 'This IMEI is reserved for its matched replacement receipt. Use that receipt and IMEI 1.'using errcode='22023';end if;
 if greenloop_private.srma_model(d.model)<>greenloop_private.srma_model(p.model)or d.storage_gb is distinct from p.storage_gb then raise exception 'Replacement Model and GB must match the reviewed pairing. Color may differ.'using errcode='22023';end if;
 select *into r from public.supplier_returns where id=p.return_id;
 if r.id is null or exists(select 1 from greenloop_private.srp_phone_links where return_id=p.return_id)then raise exception 'This returned phone already has a replacement or its source is unavailable.'using errcode='23514';end if;
 k:=case when r.device_id is null then 'return:'||r.id::text else 'phone:'||r.batch_id::text||':'||r.device_id::text end;
 select *into parent from greenloop_private.srp_phone_links where replacement_device_id=r.device_id;
 insert into greenloop_private.srp_phone_links(return_id,replacement_batch_id,replacement_job_id,replacement_device_id,return_record_key,root_record_key,root_batch_id)
 values(r.id,p.replacement_batch_id,new.id,d.id,k,coalesce(parent.root_record_key,k),coalesce(parent.root_batch_id,r.batch_id));
 return new;
end;$$;
create or replace function greenloop_private.srma_save(p_supplier uuid,p_batch uuid,p_phones jsonb,p_snapshot text,p_request uuid,p_notes text)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare prior greenloop_private.srma_commands%rowtype;cmd jsonb;plan jsonb;b public.receiving_batches%rowtype;g jsonb;x jsonb;grp record;r record;
 bid uuid;receipt uuid;batchno text;invno text;channel uuid;channel_name text;v_notes text:=nullif(btrim(p_notes),'');output jsonb:='[]';actor_name text;started boolean:=false;
begin
 perform greenloop_private.srp_access('replacement_entry');
 if p_request is null or p_snapshot is null or length(coalesce(v_notes,''))>2000 then raise exception 'Preview matching phones before saving.'using errcode='22023';end if;
 cmd:=jsonb_build_object('supplier',p_supplier,'batch',p_batch,'phones',p_phones,'snapshot',p_snapshot,'notes',v_notes);
 perform pg_advisory_xact_lock(hashtextextended('srma-command:'||auth.uid()::text||p_request::text,0));
 select *into prior from greenloop_private.srma_commands where actor=auth.uid()and request_id=p_request;
 if found then if prior.command<>cmd then raise exception 'Retry key belongs to different replacement details.'using errcode='22023';end if;return prior.response;end if;
 if jsonb_typeof(p_phones)is distinct from 'array'or jsonb_array_length(p_phones)not between 1 and 1000 then raise exception 'Add 1 to 1000 replacement phones.'using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_phones)order by value->>'imei'loop
  if coalesce(x->>'imei','')!~'^[0-9]{15}$'then raise exception 'Enter complete new IMEIs.'using errcode='22023';end if;
  perform greenloop_private.lock_cable_identity_v1(x->>'imei',null,null);
 end loop;
 select *into b from public.receiving_batches where id=p_batch and supplier_id=p_supplier for update;
 if b.id is null then raise exception 'Choose the original stock.'using errcode='22023';end if;
 perform 1 from public.supplier_returns where batch_id=b.id order by id for update;
 plan:=greenloop_private.srma_plan(p_supplier,p_batch,p_phones);
 if not(plan->>'all_matched')::boolean or plan->>'snapshot'is distinct from p_snapshot then raise exception 'Replacement matches changed or contain errors. Check matches again. Nothing was saved.'using errcode='40001';end if;
 select c.id,c.channel_name into channel,channel_name from public.stock_channels c where c.is_active and(c.id=b.stock_channel_id or b.stock_channel_id is null and lower(c.channel_name)='company stock')order by c.id limit 1;
 if channel is null then raise exception 'Original stock channel is inactive.'using errcode='22023';end if;
 perform greenloop_private.begin_capability('receive_matched_replacements_v1',cmd);started:=true;
 select coalesce(full_name,login_username,'Staff')into actor_name from public.user_profiles where id=auth.uid();
 for grp in select (v->>'group_id')::uuid id,count(*)::integer qty from jsonb_array_elements(plan->'rows')v group by v->>'group_id'order by v->>'group_id'loop
  select v into g from jsonb_array_elements(public.list_active_stock_returns(null,null))v where v->>'group_id'=grp.id::text;
  if g is null then raise exception 'A returned group changed. Refresh matches.'using errcode='40001';end if;
  receipt:=gen_random_uuid();batchno:='REPL-'||receipt::text; -- sro-internal-replacement: permanent intake ledger, not a new purchase batch
  invno:='REPL-'||receipt::text;
  insert into public.receiving_batches(batch_number,invoice_number,receiving_source,notes,created_by,stock_channel_id,planned_model,planned_quantity,supplier_id)
   values(batchno,invno,channel_name,'Matched replacements for '||(g->>'return_reference')||' / '||b.batch_number,auth.uid(),channel,'Stock received',grp.qty,p_supplier)returning id into bid;
  x:=jsonb_build_object('receipt_id',receipt,'batch_id',bid,'original_batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'receipt_quantity',b.planned_quantity,'quantity',grp.qty,'return_reference',g->>'return_reference');
  insert into greenloop_private.srp_receipts(id,actor_id,idempotency_key,command,response,group_id,original_batch_id,replacement_batch_id,supplier_id,quantity,original_snapshot)
   values(receipt,auth.uid(),gen_random_uuid(),jsonb_build_object('notes',v_notes,'auto_match_request',p_request),x,grp.id,b.id,bid,p_supplier,grp.qty,g);
  for r in select v from jsonb_array_elements(plan->'rows')v where v->>'group_id'=grp.id::text order by (v->>'line')::integer loop
   insert into greenloop_private.srp_allocations(return_id,receipt_id,original_imei,return_number)select id,receipt,imei_1,return_number from public.supplier_returns where id=(r.v->>'return_id')::uuid;
   insert into greenloop_private.srma_pairs(new_imei,return_id,receipt_id,replacement_batch_id,original_imei,model,storage_gb,color)
    values(r.v->>'imei',(r.v->>'return_id')::uuid,receipt,bid,r.v->>'old_imei',r.v->>'model',(r.v->>'storage_gb')::integer,r.v->>'color');
   insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),(r.v->>'return_id')::uuid)on conflict do nothing;
   update public.supplier_returns set settlement_type='replacement',settlement_reference=batchno,settlement_notes=v_notes,settled_by=auth.uid(),settled_at=now(),updated_at=now()where id=(r.v->>'return_id')::uuid;
   insert into public.supplier_return_events(return_id,action,from_status,to_status,actor_id,actor_name,notes,event_data)
    values((r.v->>'return_id')::uuid,'settlement','returned','returned',auth.uid(),coalesce(actor_name,'Staff'),v_notes,jsonb_build_object('settlement_type','replacement','replacement_batch_id',bid,'replacement_imei',r.v->>'imei','financial_posting',false));
   delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id=(r.v->>'return_id')::uuid;
  end loop;
  output:=output||jsonb_build_array(x);
 end loop;
 x:=jsonb_build_object('receipts',output,'quantity',jsonb_array_length(p_phones),'pairs',plan->'rows');
 insert into greenloop_private.srma_commands(actor,request_id,command,response)values(auth.uid(),p_request,cmd,x);
 perform greenloop_private.end_capability();started:=false;return x;
exception when others then if started then perform greenloop_private.end_capability();end if;raise;
end;$$;


do $reviewed$declare t record;r record;c record;begin
 for c in select *from(values('identity','hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   for r in select *from sro_review loop
    execute format($q$update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,' ','')=replace($1,' ','') and %I=$2$q$,t.name,c.hashcol,c.idcol,c.hashcol)using r.identity,r.before_hash;
   end loop;
  end loop;
 end loop;
 for r in select *from sro_review loop
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 end loop;
end;$reviewed$;
-- Repair all already-entered, verified replacement links in the same transaction.
do $$declare r record;begin for r in select replacement_job_id from greenloop_private.srp_phone_links order by linked_at,replacement_job_id loop perform greenloop_private.sro_rehome(r.replacement_job_id);end loop;end;$$;

-- Reseal only the reviewed allocator. All other hashes, triggers, permission and
-- Office boundaries are checked by their existing version function unchanged.
update greenloop_private.srma_installation set hash=md5(pg_get_functiondef('greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)'::regprocedure))
 where identity='greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)';
update greenloop_private.srma_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity)))where identity in('greenloop_private.srma_plan(uuid,uuid,jsonb)','greenloop_private.srma_intake()');
update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef('greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)'::regprocedure))
 where identity='public.receive_matched_replacements_v1(uuid,uuid,jsonb,text,uuid,text)'and implementation='greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)';
update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))where identity='public.preview_matched_replacements_v1(uuid,uuid,jsonb)'and implementation='greenloop_private.srma_plan(uuid,uuid,jsonb)';
create table if not exists greenloop_private.sro_installation(identity text primary key,hash text not null);
alter table greenloop_private.sro_installation enable row level security;
revoke all on greenloop_private.sro_installation from public,anon,authenticated;
create or replace function public.get_replacement_original_stock_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_replacement_auto_match_version()='20261111-replacement-auto-match-1'
 and(select count(*)=19 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))))from greenloop_private.sro_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.sro_installation'::regclass and relrowsecurity)
 and not has_table_privilege('authenticated','greenloop_private.sro_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.sro_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_trigger where tgrelid='public.jobs'::regclass and tgname='zzz_sro_original_stock'and tgenabled='O'and tgfoid='greenloop_private.sro_arrival()'::regprocedure)
 and exists(select 1 from pg_class where oid='greenloop_private.sro_rehomes'::regclass and relrowsecurity)
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.sro_rehomes'::regclass and tgname='sro_rehomes_immutable'and tgenabled='O'and tgfoid='greenloop_private.srp_immutable()'::regprocedure)
 and not has_table_privilege('authenticated','greenloop_private.sro_rehomes','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.sro_rehomes','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261111-replacement-original-stock-1'else null end;$$;
revoke all on function public.get_replacement_original_stock_version()from public;
grant execute on function public.get_replacement_original_stock_version()to anon,authenticated;
insert into greenloop_private.sro_installation select id,md5(pg_get_functiondef(to_regprocedure(id)))from unnest(array['greenloop_private.sga_report(jsonb,boolean,text)','greenloop_private.accounts_supplier_rows()','greenloop_private.sro_entered_count(uuid)','greenloop_private.supplier_return_batch(uuid)','greenloop_private.supplier_return_intake_guard()','greenloop_private.simple_stock_return_model_intake_guard()','greenloop_private.receive_mobile_stock_imei(uuid,text,text,integer,text,smallint,text,text,boolean)','greenloop_private.cap_impl_d78999e342aebe309d9b22270fe6e18c(uuid,text,text,integer,text,smallint)','greenloop_private.src_receipt(uuid)','greenloop_private.cl_allocate_replacement(uuid)','greenloop_private.srp_rows()','greenloop_private.sbn_counts()','greenloop_private.sro_rehome(uuid)','greenloop_private.sro_arrival()','greenloop_private.srma_plan(uuid,uuid,jsonb)','greenloop_private.srma_intake()','greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)','public.get_replacement_original_stock_version()'])id on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.sro_installation select implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines where to_regprocedure(identity)='public.get_overview_workflow_counts()'::regprocedure on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_replacement_original_stock_version()is distinct from '20261111-replacement-original-stock-1'then raise exception 'Original stock installation not verified. Rolled back.';end if;end;$$;
$sro_body$;
END;
$sro_atomic$;
select public.get_replacement_original_stock_version()as installed_replacement_original_stock_version;
