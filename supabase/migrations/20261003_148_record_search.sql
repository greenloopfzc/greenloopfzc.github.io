-- Additive, read-only suggestions and receipt details. Existing workflows are unchanged.
begin;
create schema if not exists greenloop_private;

create or replace function greenloop_private.require_record_search_access()
returns void language plpgsql stable set search_path=pg_catalog,public as $guard$
begin
 if auth.uid() is null or not coalesce(public.is_active_staff(),false) or not coalesce(
   (select p.access_level in ('view','edit') from public.user_page_permissions p where p.user_id=auth.uid() and p.page_key='imei_search'),
   public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then
  raise exception 'IMEI Search permission is required.' using errcode='42501';
 end if;
end;
$guard$;
revoke all on function greenloop_private.require_record_search_access() from public,anon,authenticated;

create or replace function greenloop_private.record_search_candidates(p_names boolean)
returns table(kind text,id uuid,payload jsonb,match_values text[],direct_values text[])
language sql stable set search_path=pg_catalog,public as $candidates$
 with device_rows as (
  select d.id,d.device_number,d.imei_1,d.imei_2,d.serial_number,d.brand,d.model,d.storage_gb,d.color,
   d.specification_region,d.current_status::text status,j.job_number,b.invoice_number,b.batch_number,
   s.supplier_code,case when p_names then s.company_name end supplier_name
  from public.devices d
  left join lateral (select j.* from public.jobs j where j.device_id=d.id and j.deleted_at is null order by j.created_at desc,j.id limit 1) j on true
  left join public.receiving_batches b on b.id=j.receiving_batch_id
  left join public.suppliers s on s.id=coalesce(j.supplier_id,b.supplier_id)
  where d.deleted_at is null
 ), device_candidates as (
  select 'device'::text kind,d.id,
   to_jsonb(d)||jsonb_build_object('kind','device','identifier',coalesce(nullif(d.device_number,''),nullif(d.imei_1,''),nullif(d.serial_number,'')),'region',d.specification_region) payload,
   array[d.device_number,d.imei_1,d.imei_2,d.serial_number,d.brand,d.model,d.storage_gb::text,d.color,d.specification_region,d.status,d.job_number,d.invoice_number,d.batch_number,d.supplier_code,d.supplier_name] match_values,
   array[d.device_number,d.imei_1,d.imei_2,d.serial_number,d.brand,d.model,d.storage_gb::text,d.color,d.specification_region,d.status,d.job_number,d.supplier_code,d.supplier_name] direct_values
  from device_rows d
 ), receipt_candidates as (
  select 'receipt'::text kind,b.id,
   jsonb_build_object('kind','receipt','id',b.id,'identifier',coalesce(nullif(b.invoice_number,''),b.batch_number),'invoice_number',b.invoice_number,'batch_number',b.batch_number,'supplier_code',s.supplier_code,'supplier_name',case when p_names then s.company_name end,'received_at',b.received_at,'planned_quantity',b.planned_quantity) payload,
   array[b.invoice_number,b.batch_number,s.supplier_code,case when p_names then s.company_name end] match_values,
   array[b.invoice_number,b.batch_number,s.supplier_code,case when p_names then s.company_name end] direct_values
  from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id
  where to_jsonb(b)->>'deleted_at' is null
 ) select * from device_candidates union all select * from receipt_candidates;
$candidates$;
revoke all on function greenloop_private.record_search_candidates(boolean) from public,anon,authenticated;

create or replace function public.search_greenloop_records_v1(p_query text,p_offset integer default 0,p_limit integer default 12)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $search$
declare v_query text:=lower(btrim(coalesce(p_query,''))); v_offset integer:=greatest(0,coalesce(p_offset,0)); v_limit integer:=least(50,greatest(1,coalesce(p_limit,12))); v_result jsonb; v_names boolean;
begin
 perform greenloop_private.require_record_search_access();
 if length(v_query)>120 then raise exception 'Search text must be 120 characters or fewer.' using errcode='22023'; end if;
 if v_query='' then return jsonb_build_object('items','[]'::jsonb,'has_more',false,'next_offset',null,'exact_match',false); end if;
 v_names:=coalesce(public.get_my_partner_name_access(),false);
 with candidates as materialized (
  select c.*,exists(select 1 from unnest(c.direct_values) value where lower(value)=v_query) is_exact,
   exists(select 1 from unnest(c.match_values) value where strpos(lower(value),v_query)=1) is_prefix
  from greenloop_private.record_search_candidates(v_names) c
  where exists(select 1 from unnest(c.match_values) value where strpos(lower(value),v_query)>0)
 ), mode as (select coalesce(bool_or(is_exact),false) exact_match from candidates),
 selected as (select c.* from candidates c cross join mode m where not m.exact_match or c.is_exact
  order by c.is_prefix desc,lower(c.payload->>'identifier'),c.kind,c.id offset v_offset limit v_limit+1),
 numbered as (select s.*,row_number() over(order by s.is_prefix desc,lower(s.payload->>'identifier'),s.kind,s.id) rn from selected s)
 select jsonb_build_object('items',coalesce((select jsonb_agg(n.payload order by n.rn) from numbered n where n.rn<=v_limit),'[]'::jsonb),
  'has_more',(select count(*)>v_limit from numbered),'next_offset',case when (select count(*)>v_limit from numbered) then v_offset+v_limit end,'exact_match',m.exact_match)
 into v_result from mode m;
 return v_result;
end;
$search$;
revoke all on function public.search_greenloop_records_v1(text,integer,integer) from public,anon;
grant execute on function public.search_greenloop_records_v1(text,integer,integer) to authenticated;

create or replace function public.get_search_receipt_v1(p_receipt_id uuid,p_offset integer default 0,p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $receipt$
declare v_offset integer:=greatest(0,coalesce(p_offset,0)); v_limit integer:=least(50,greatest(1,coalesce(p_limit,25))); v_receipt jsonb; v_result jsonb; v_names boolean;
begin
 perform greenloop_private.require_record_search_access();
 v_names:=coalesce(public.get_my_partner_name_access(),false);
 select jsonb_build_object('id',b.id,'invoice_number',b.invoice_number,'batch_number',b.batch_number,'received_at',b.received_at,
  'received_by',p.full_name,'supplier_code',s.supplier_code,'supplier_name',case when v_names then s.company_name end,
  'planned_quantity',b.planned_quantity,'entered_quantity',(select count(distinct j.device_id) from public.jobs j join public.devices d on d.id=j.device_id where j.receiving_batch_id=b.id and j.deleted_at is null and d.deleted_at is null),'stock_channel',c.channel_name)
 into v_receipt from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id left join public.stock_channels c on c.id=b.stock_channel_id left join public.user_profiles p on p.id=b.created_by
 where b.id=p_receipt_id and to_jsonb(b)->>'deleted_at' is null;
 if v_receipt is null then return jsonb_build_object('found',false,'items','[]'::jsonb,'has_more',false,'next_offset',null); end if;
 with selected as (
  select c.* from greenloop_private.record_search_candidates(v_names) c where c.kind='device'
   and exists(select 1 from public.jobs j where j.device_id=c.id and j.receiving_batch_id=p_receipt_id and j.deleted_at is null)
  order by lower(c.payload->>'identifier'),c.id offset v_offset limit v_limit+1
 ), numbered as (select s.*,row_number() over(order by lower(s.payload->>'identifier'),s.id) rn from selected s)
 select jsonb_build_object('found',true,'receipt',v_receipt,
  'items',coalesce((select jsonb_agg(n.payload||jsonb_build_object('invoice_number',v_receipt->'invoice_number','batch_number',v_receipt->'batch_number','supplier_code',v_receipt->'supplier_code','supplier_name',v_receipt->'supplier_name') order by n.rn) from numbered n where n.rn<=v_limit),'[]'::jsonb),
  'has_more',(select count(*)>v_limit from numbered),'next_offset',case when (select count(*)>v_limit from numbered) then v_offset+v_limit end)
 into v_result;
 return v_result;
end;
$receipt$;
revoke all on function public.get_search_receipt_v1(uuid,integer,integer) from public,anon;
grant execute on function public.get_search_receipt_v1(uuid,integer,integer) to authenticated;

create table if not exists greenloop_private.record_search_installation(function_identity text primary key,definition_hash text not null);
revoke all on greenloop_private.record_search_installation from public,anon,authenticated;
insert into greenloop_private.record_search_installation
select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.oid in
 ('greenloop_private.require_record_search_access()'::regprocedure,'greenloop_private.record_search_candidates(boolean)'::regprocedure,'public.search_greenloop_records_v1(text,integer,integer)'::regprocedure,'public.get_search_receipt_v1(uuid,integer,integer)'::regprocedure)
on conflict(function_identity) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_greenloop_record_search_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when (select count(*) from greenloop_private.record_search_installation i where to_regprocedure(i.function_identity) is not null and md5(pg_get_functiondef(to_regprocedure(i.function_identity)))=i.definition_hash)=4
 and not has_function_privilege('anon','public.search_greenloop_records_v1(text,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','public.get_search_receipt_v1(uuid,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.search_greenloop_records_v1(text,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_search_receipt_v1(uuid,integer,integer)','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.require_record_search_access()','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.require_record_search_access()','EXECUTE')
 and not has_function_privilege('anon','greenloop_private.record_search_candidates(boolean)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.record_search_candidates(boolean)','EXECUTE')
 then '20261003-navigation-search-1' end;
$version$;
revoke all on function public.get_greenloop_record_search_version() from public;
grant execute on function public.get_greenloop_record_search_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_greenloop_record_search_version() as installed_record_search_version;
