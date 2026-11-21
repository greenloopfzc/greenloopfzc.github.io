-- Audited supplier name correction by supplier identity, including suppliers without receipts.
begin;

do $$
declare
  signature regprocedure:='public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid)'::regprocedure;
  source text;
begin
  if public.get_supplier_name_correction_version() is distinct from '20261120-supplier-name-correction-1' then
    raise exception 'Verify the Supplier Name Correction update first.';
  end if;
  -- A direct audit entry has no receipt. The legacy retry path must reject one.
  source:=pg_get_functiondef(signature);
  if position('saved.receipt_id<>p_batch_id' in source)>0 then
    execute replace(source,'saved.receipt_id<>p_batch_id','saved.receipt_id is distinct from p_batch_id');
    update greenloop_private.supplier_name_installation
    set hash=md5(pg_get_functiondef(signature)) where to_regprocedure(identity)=signature;
  elsif position('saved.receipt_id is distinct from p_batch_id' in source)=0 then
    raise exception 'The legacy supplier correction retry check did not verify.';
  end if;
end
$$;

alter table greenloop_private.supplier_name_audit alter column receipt_id drop not null;

create or replace function greenloop_private.rsn_supplier_context(p_supplier_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $context$
declare
  supplier public.suppliers%rowtype;
  linked_receipts bigint;
  receipt_snapshot text;
begin
  select s.* into supplier from public.suppliers s where s.id=p_supplier_id;
  if not found then
    raise exception 'Select a saved supplier.' using errcode='22023';
  end if;

  select count(*),md5(coalesce(string_agg(b.id::text,',' order by b.id),''))
  into linked_receipts,receipt_snapshot from public.receiving_batches b where b.supplier_id=p_supplier_id;
  return jsonb_build_object('supplier_id',supplier.id,'supplier_code',supplier.supplier_code,
    'supplier_name',supplier.company_name,'can_rename',supplier.deleted_at is null and supplier.is_active,
    'receipt_count',linked_receipts,'snapshot',md5(jsonb_build_array('supplier-name',supplier.id,
      supplier.supplier_code,supplier.company_name,supplier.is_active,supplier.deleted_at,receipt_snapshot)::text));
end
$context$;
revoke all on function greenloop_private.rsn_supplier_context(uuid) from public,anon,authenticated;

create or replace function public.get_supplier_name_correction_v1(
  p_supplier_id uuid, p_new_name text default null, p_offset integer default 0, p_history_snapshot text default null
) returns jsonb language plpgsql stable security definer set search_path=pg_catalog, public as $read$
declare
  ctx jsonb;
  supplier uuid;
  reviewed_name text;
  history jsonb;
  history_total bigint;
  history_version text;
  may_edit boolean;
begin
  may_edit:=greenloop_private.rsn_require(p_new_name is not null);
  if p_offset is null or p_offset<0 or p_offset%50<>0 then
    raise exception 'Choose a valid 50-record history page.' using errcode='22023';
  end if;
  ctx:=greenloop_private.rsn_supplier_context(p_supplier_id);
  supplier:=(ctx->>'supplier_id')::uuid;
  if p_new_name is not null then
    if not (ctx->>'can_rename')::boolean then
      raise exception 'This supplier is archived.' using errcode='22023';
    end if;
    reviewed_name:=greenloop_private.rsn_new_name(supplier,ctx->>'supplier_name',p_new_name);
  end if;
  select count(*),md5(coalesce(jsonb_agg(request_id order by changed_at desc,request_id desc),'[]')::text)
  into history_total,history_version from greenloop_private.supplier_name_audit where supplier_id=supplier;
  if (p_offset>0 and p_history_snapshot is null)
     or (p_history_snapshot is not null and p_history_snapshot<>history_version) then
    raise exception 'Supplier name history changed. Reload this supplier before paging.' using errcode='40001';
  end if;
  select coalesce(jsonb_agg(to_jsonb(h) order by changed_at desc,request_id desc),'[]')
  into history from (
    select request_id,old_name,new_name,reason,actor_name,changed_at
    from greenloop_private.supplier_name_audit where supplier_id=supplier
    order by changed_at desc,request_id desc offset p_offset limit 50
  ) h;
  return ctx||jsonb_build_object('new_name',reviewed_name,'may_edit',may_edit,'history',history,'history_total',history_total,
    'history_snapshot',history_version,'offset',p_offset);
end
$read$;

create or replace function public.correct_supplier_name_v1(
  p_supplier_id uuid, p_snapshot text, p_new_name text, p_reason text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=pg_catalog, public as $save$
declare
  ctx jsonb;
  clean_reason text := btrim(p_reason);
  clean_name text := btrim(regexp_replace(p_new_name,'[[:space:]]+',' ','g'));
  saved greenloop_private.supplier_name_audit%rowtype;
  current_name text;
begin
  perform greenloop_private.rsn_require(true);
  if p_supplier_id is null or p_request_id is null
     or p_snapshot is null or p_snapshot !~ '^[a-f0-9]{32}$'
     or clean_reason is null or length(clean_reason) not between 5 and 2000
     or clean_name is null or length(clean_name) not between 1 and 200 then
    raise exception 'Review the new supplier name and enter a reason from 5 to 2000 characters.' using errcode='22023';
  end if;

  -- Serialize audited name edits and code allocation before checking current names.
  perform pg_advisory_xact_lock(hashtext('greenloop_supplier_code'));
  select * into saved from greenloop_private.supplier_name_audit where request_id=p_request_id;
  if found then
    if saved.actor is distinct from auth.uid() or saved.receipt_id is not null
       or saved.supplier_id<>p_supplier_id or saved.expected_snapshot<>p_snapshot
       or saved.new_name<>clean_name or saved.reason<>clean_reason then
      raise exception 'This save reference belongs to a different supplier name correction.' using errcode='22023';
    end if;
  else
    perform 1 from public.suppliers where id=p_supplier_id for update;
    ctx:=greenloop_private.rsn_supplier_context(p_supplier_id);
    if ctx->>'snapshot' is distinct from p_snapshot or ctx->>'supplier_id' is distinct from p_supplier_id::text
       or not (ctx->>'can_rename')::boolean then
      raise exception 'The supplier or its linked receipts changed after review. Review the name again.' using errcode='40001';
    end if;
    clean_name:=greenloop_private.rsn_new_name(p_supplier_id,ctx->>'supplier_name',clean_name);
    update public.suppliers set company_name=clean_name where id=p_supplier_id;
    insert into greenloop_private.supplier_name_audit(
      request_id,supplier_id,supplier_code,receipt_id,expected_snapshot,old_name,new_name,reason,actor,actor_name
    ) values (
      p_request_id,p_supplier_id,ctx->>'supplier_code',null,p_snapshot,ctx->>'supplier_name',clean_name,clean_reason,
      auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Not recorded')
    ) returning * into saved;
  end if;

  select s.company_name into current_name from public.suppliers s where s.id=saved.supplier_id;
  return jsonb_build_object('saved',true,'request_id',saved.request_id,'supplier_id',saved.supplier_id,
    'applied_name',saved.new_name,'current_name',current_name);
end
$save$;
revoke all on function public.get_supplier_name_correction_v1(uuid,text,integer,text),
  public.correct_supplier_name_v1(uuid,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.get_supplier_name_correction_v1(uuid,text,integer,text),
  public.correct_supplier_name_v1(uuid,text,text,text,uuid) to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
  ('get_supplier_name_correction_v1','{"page":"reports","capability":"report_receipt_correction","read":true}'),
  ('correct_supplier_name_v1','{"page":"reports","capability":"receipt_supplier_name_correction"}'),
  ('get_direct_supplier_name_correction_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.direct_supplier_name_installation(identity text primary key,hash text not null);
alter table greenloop_private.direct_supplier_name_installation enable row level security;
revoke all on table greenloop_private.direct_supplier_name_installation from public,anon,authenticated;

create or replace function public.get_direct_supplier_name_correction_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $$
  select case when public.get_supplier_name_correction_version()='20261120-supplier-name-correction-1'
    and public.get_page_capabilities_version()='20261016-page-capabilities-1'
    and (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.direct_supplier_name_installation)
    and exists(select 1 from pg_attribute where
      attrelid='greenloop_private.supplier_name_audit'::regclass and attname='receipt_id' and not attnotnull)
    and not has_function_privilege('authenticated','greenloop_private.rsn_supplier_context(uuid)','EXECUTE')
    and not has_function_privilege('anon','greenloop_private.rsn_supplier_context(uuid)','EXECUTE')
    and has_function_privilege('authenticated','public.get_supplier_name_correction_v1(uuid,text,integer,text)','EXECUTE')
    and not has_function_privilege('anon','public.get_supplier_name_correction_v1(uuid,text,integer,text)','EXECUTE')
    and has_function_privilege('authenticated','public.correct_supplier_name_v1(uuid,text,text,text,uuid)','EXECUTE')
    and not has_function_privilege('anon','public.correct_supplier_name_v1(uuid,text,text,text,uuid)','EXECUTE')
  then '20261121-direct-supplier-name-correction-1' end;
$$;
revoke all on function public.get_direct_supplier_name_correction_version() from public;
grant execute on function public.get_direct_supplier_name_correction_version() to anon,authenticated;

insert into greenloop_private.direct_supplier_name_installation
select signature,md5(pg_get_functiondef(signature::regprocedure))
from unnest(array['greenloop_private.rsn_supplier_context(uuid)','public.get_supplier_name_correction_v1(uuid,text,integer,text)',
  'public.correct_supplier_name_v1(uuid,text,text,text,uuid)','public.get_direct_supplier_name_correction_version()']) signature
on conflict(identity) do update set hash=excluded.hash;

do $$
begin
  if public.get_direct_supplier_name_correction_version() is distinct from '20261121-direct-supplier-name-correction-1' then
    raise exception 'Direct supplier name correction verification failed.';
  end if;
end
$$;
notify pgrst,'reload schema';
commit;
select public.get_direct_supplier_name_correction_version() as installed_direct_supplier_name_correction_version;
