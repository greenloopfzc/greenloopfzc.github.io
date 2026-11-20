-- Correct the name of the supplier linked to a receipt, with a permanent audit.
do $install$
begin
execute $ddl$
create table if not exists greenloop_private.supplier_name_audit(
  request_id uuid primary key,
  supplier_id uuid not null,
  supplier_code text not null,
  receipt_id uuid not null,
  expected_snapshot text not null,
  old_name text,
  new_name text not null,
  reason text not null,
  actor uuid not null,
  actor_name text not null,
  changed_at timestamptz not null default clock_timestamp()
);
create index if not exists supplier_name_audit_history
  on greenloop_private.supplier_name_audit(supplier_id, changed_at desc, request_id desc);
alter table greenloop_private.supplier_name_audit enable row level security;
revoke all on greenloop_private.supplier_name_audit from public, anon, authenticated;
create or replace function greenloop_private.rsn_immutable() returns trigger
language plpgsql set search_path=pg_catalog as $immutable$
begin
  raise exception 'Supplier name correction history is permanent.' using errcode='55000';
end
$immutable$;
drop trigger if exists supplier_name_audit_immutable on greenloop_private.supplier_name_audit;
create trigger supplier_name_audit_immutable before update or delete or truncate
on greenloop_private.supplier_name_audit for each statement execute function greenloop_private.rsn_immutable();
revoke all on function greenloop_private.rsn_immutable() from public, anon, authenticated;

create or replace function greenloop_private.rsn_require(p_edit boolean) returns boolean
language plpgsql stable security definer set search_path=pg_catalog, public as $permissions$
declare may_edit boolean;
begin
  perform greenloop_private.src_require(false);
  if not coalesce(public.get_my_partner_name_access(),false) then
    raise exception 'Supplier Names view permission is required.' using errcode='42501';
  end if;
  may_edit:=coalesce(public.get_my_partner_name_access_level(),'none') = 'edit'
    and coalesce(public.has_page_capability_v1('reports','receipt_supplier_name_correction'),false)
    and exists (
      select 1 from public.user_page_permissions
      where user_id=auth.uid() and page_key='reports' and access_level='edit'
    );
  if p_edit and not may_edit then
    raise exception 'Supplier Names Entry permission and Supplier Name Correction access are required.' using errcode='42501';
  end if;
  return may_edit;
end
$permissions$;
revoke all on function greenloop_private.rsn_require(boolean) from public, anon, authenticated;

create or replace function greenloop_private.rsn_context(p_batch uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog, public as $context$
declare
  current_row record;
  linked_receipts bigint;
begin
  select s.id, s.supplier_code, s.company_name, s.is_active, s.deleted_at, b.batch_number
  into current_row
  from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id where b.id=p_batch;
  if not found then
    raise exception 'Select a receipt with a saved supplier.' using errcode='22023';
  end if;

  select count(*) into linked_receipts from public.receiving_batches where supplier_id=current_row.id;
  return jsonb_build_object(
    'batch_id',p_batch,'batch_number',current_row.batch_number,'supplier_id',current_row.id,
    'supplier_code',current_row.supplier_code,'supplier_name',current_row.company_name,
    'can_rename',current_row.deleted_at is null and current_row.is_active,
    'receipt_count',linked_receipts,
    'snapshot',md5(jsonb_build_array(p_batch,current_row.id,current_row.supplier_code,current_row.company_name,
      current_row.is_active,current_row.deleted_at,linked_receipts)::text)
  );
end
$context$;
revoke all on function greenloop_private.rsn_context(uuid) from public, anon, authenticated;

create or replace function greenloop_private.rsn_new_name(p_supplier uuid,p_old text,p_new text) returns text
language plpgsql stable security definer set search_path=pg_catalog, public as $name$
declare cleaned text := btrim(regexp_replace(p_new,'[[:space:]]+',' ','g'));
begin
  if cleaned is null or length(cleaned) not between 1 and 200 then
    raise exception 'Enter a supplier name from 1 to 200 characters.' using errcode='22023';
  end if;
  if cleaned is not distinct from p_old then
    raise exception 'Enter a name different from the current supplier name.' using errcode='22023';
  end if;
  if exists (
    select 1 from public.suppliers s where s.id<>p_supplier
      and lower(btrim(regexp_replace(s.company_name,'[[:space:]]+',' ','g')))=lower(cleaned)
  ) then
    raise exception 'That name already belongs to another supplier. Use Change Stock Supplier to relink a receipt.' using errcode='23505';
  end if;
  return cleaned;
end
$name$;
revoke all on function greenloop_private.rsn_new_name(uuid,text,text) from public, anon, authenticated;

create or replace function public.get_stock_receipt_supplier_name_v1(
  p_batch_id uuid, p_new_name text default null, p_offset integer default 0, p_history_snapshot text default null
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
  ctx:=greenloop_private.rsn_context(p_batch_id);
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
    raise exception 'Supplier name history changed. Reload this receipt before paging.' using errcode='40001';
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

create or replace function public.correct_stock_receipt_supplier_name_v1(
  p_batch_id uuid, p_supplier_id uuid, p_snapshot text, p_new_name text, p_reason text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=pg_catalog, public as $save$
declare
  ctx jsonb;
  clean_reason text := btrim(p_reason);
  clean_name text := btrim(regexp_replace(p_new_name,'[[:space:]]+',' ','g'));
  saved greenloop_private.supplier_name_audit%rowtype;
  current_name text;
begin
  perform greenloop_private.rsn_require(true);
  if p_batch_id is null or p_supplier_id is null or p_request_id is null
     or p_snapshot is null or p_snapshot !~ '^[a-f0-9]{32}$'
     or clean_reason is null or length(clean_reason) not between 5 and 2000
     or clean_name is null or length(clean_name) not between 1 and 200 then
    raise exception 'Review the new supplier name and enter a reason from 5 to 2000 characters.' using errcode='22023';
  end if;

  -- Serialize audited name edits and code allocation before checking current names.
  perform pg_advisory_xact_lock(hashtext('greenloop_supplier_code'));
  select * into saved from greenloop_private.supplier_name_audit where request_id=p_request_id;
  if found then
    if saved.actor is distinct from auth.uid() or saved.receipt_id<>p_batch_id
       or saved.supplier_id<>p_supplier_id or saved.expected_snapshot<>p_snapshot
       or saved.new_name<>clean_name or saved.reason<>clean_reason then
      raise exception 'This save reference belongs to a different supplier name correction.' using errcode='22023';
    end if;
  else
    perform 1 from public.receiving_batches where id=p_batch_id for share;
    perform 1 from public.suppliers where id=p_supplier_id for update;
    ctx:=greenloop_private.rsn_context(p_batch_id);
    if ctx->>'snapshot' is distinct from p_snapshot or ctx->>'supplier_id' is distinct from p_supplier_id::text
       or not (ctx->>'can_rename')::boolean then
      raise exception 'The receipt or supplier changed after review. Reload and review the name again.' using errcode='40001';
    end if;
    clean_name:=greenloop_private.rsn_new_name(p_supplier_id,ctx->>'supplier_name',clean_name);
    update public.suppliers set company_name=clean_name where id=p_supplier_id;
    insert into greenloop_private.supplier_name_audit(
      request_id,supplier_id,supplier_code,receipt_id,expected_snapshot,old_name,new_name,reason,actor,actor_name
    ) values (
      p_request_id,p_supplier_id,ctx->>'supplier_code',p_batch_id,p_snapshot,ctx->>'supplier_name',clean_name,clean_reason,
      auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Not recorded')
    ) returning * into saved;
  end if;

  select s.company_name into current_name from public.suppliers s where s.id=saved.supplier_id;
  return jsonb_build_object('saved',true,'request_id',saved.request_id,'supplier_id',saved.supplier_id,
    'applied_name',saved.new_name,'current_name',current_name);
end
$save$;
revoke all on function public.get_stock_receipt_supplier_name_v1(uuid,text,integer,text),
  public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid) from public, anon;
grant execute on function public.get_stock_receipt_supplier_name_v1(uuid,text,integer,text),
  public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid) to authenticated;

update greenloop_private.page_capability_catalog
set capabilities=capabilities||'[{"key":"receipt_supplier_name_correction","label":"Edit supplier name (all linked receipts, audited)","write":true}]'::jsonb
where page_key='reports' and not(capabilities@>'[{"key":"receipt_supplier_name_correction"}]');
update greenloop_private.report_access_sections
set config=jsonb_set(config,'{actions}',(config->'actions')||'["receipt_supplier_name_correction"]')
where report_key='stock_receipt_correction' and not(config->'actions'?'receipt_supplier_name_correction');
insert into greenloop_private.report_access_dependencies values('receipt_supplier_name_correction','"report_receipt_correction"')
on conflict(capability) do update set required_views=excluded.required_views;
update greenloop_private.user_page_capabilities uc
set capabilities=jsonb_set(capabilities,'{reports}',(capabilities->'reports')||'["receipt_supplier_name_correction"]')
where capabilities->'reports'?'report_receipt_correction' and not(capabilities->'reports'?'receipt_supplier_name_correction')
  and exists (
    select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
    where ur.user_id=uc.user_id and r.role_key::text in ('owner','super_admin')
  );

insert into greenloop_private.capability_rpc_rules values
  ('get_stock_receipt_supplier_name_v1','{"page":"reports","capability":"report_receipt_correction","read":true}'),
  ('correct_stock_receipt_supplier_name_v1','{"page":"reports","capability":"receipt_supplier_name_correction"}'),
  ('get_supplier_name_correction_version','{"read":true}')
on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by page_key)::text) from greenloop_private.page_capability_catalog r)
where identity='catalog';
update greenloop_private.page_capability_installation
set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
where identity='rules';

create table if not exists greenloop_private.supplier_name_installation(identity text primary key,hash text not null);
alter table greenloop_private.supplier_name_installation enable row level security;
revoke all on greenloop_private.supplier_name_installation from public, anon, authenticated;
create or replace function public.get_supplier_name_correction_version() returns text
language sql stable security definer set search_path=pg_catalog, public as $version$
  select case when (
    select count(*)=7 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
    from greenloop_private.supplier_name_installation
  ) and exists (
    select 1 from pg_trigger where tgrelid='greenloop_private.supplier_name_audit'::regclass
    and tgname='supplier_name_audit_immutable' and tgenabled='O'
    and tgfoid='greenloop_private.rsn_immutable()'::regprocedure
  ) and not has_table_privilege('authenticated','greenloop_private.supplier_name_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  and not has_table_privilege('anon','greenloop_private.supplier_name_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
  and has_function_privilege('authenticated','public.get_stock_receipt_supplier_name_v1(uuid,text,integer,text)','EXECUTE')
  and not has_function_privilege('anon','public.get_stock_receipt_supplier_name_v1(uuid,text,integer,text)','EXECUTE')
  and not has_function_privilege('authenticated','greenloop_private.rsn_context(uuid)','EXECUTE')
  and not has_function_privilege('anon','greenloop_private.rsn_context(uuid)','EXECUTE')
  and has_function_privilege('authenticated','public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid)','EXECUTE')
  and exists(select 1 from greenloop_private.report_access_sections
    where report_key='stock_receipt_correction' and config->'actions'?'receipt_supplier_name_correction')
  and exists(select 1 from greenloop_private.report_access_dependencies
    where capability='receipt_supplier_name_correction' and required_views='"report_receipt_correction"')
  and public.get_receipt_supplier_correction_version()='20261119-receipt-supplier-correction-1'
  then '20261120-supplier-name-correction-1' end;
$version$;
revoke all on function public.get_supplier_name_correction_version() from public;
grant execute on function public.get_supplier_name_correction_version() to anon, authenticated;

insert into greenloop_private.supplier_name_installation
select s,md5(pg_get_functiondef(s::regprocedure))
from unnest(array['greenloop_private.rsn_immutable()','greenloop_private.rsn_require(boolean)',
  'greenloop_private.rsn_context(uuid)','greenloop_private.rsn_new_name(uuid,text,text)',
  'public.get_stock_receipt_supplier_name_v1(uuid,text,integer,text)',
  'public.correct_stock_receipt_supplier_name_v1(uuid,uuid,text,text,text,uuid)',
  'public.get_supplier_name_correction_version()']) s
on conflict(identity) do update set hash=excluded.hash;

do $verify$
begin
  if public.get_supplier_name_correction_version() is distinct from '20261120-supplier-name-correction-1' then
    raise exception 'Supplier Name Correction verification failed.';
  end if;
end
$verify$;
notify pgrst,'reload schema';
$ddl$;
end
$install$;
select public.get_supplier_name_correction_version() as installed_supplier_name_correction_version;
