-- Correct a receipt's mistaken received quantity; preserve every IMEI and return/replacement record.
-- One atomic statement: no session temporary-table dependency in the SQL Editor.
do $src_install$begin
do $$begin
 if public.get_issuance_access_version()is distinct from '20261109-issuance-access-1'
 or public.get_report_section_access_version()is distinct from '20261104-report-permissions-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Reports, Issuance and office permissions are required.';end if;
 if to_regprocedure('public.get_stock_receipt_correction_version()')is not null then
  if public.get_stock_receipt_correction_version()is distinct from '20261109-stock-receipt-correction-1'then raise exception 'Existing receipt correction integrity differs.';end if;
 end if;
end;$$;
create table if not exists greenloop_private.receipt_quantity_audit(
 request_id uuid primary key,batch_id uuid not null,actor uuid not null,created_at timestamptz not null default clock_timestamp(),
 old_quantity integer not null,new_quantity integer not null check(new_quantity>0),reason text not null,
 expected_snapshot text not null,before_receipt jsonb not null,transaction_id bigint not null,
 check(old_quantity<>new_quantity),check(length(btrim(reason))between 5 and 2000));
create index if not exists receipt_quantity_audit_batch_idx on greenloop_private.receipt_quantity_audit(batch_id,created_at desc,request_id);
alter table greenloop_private.receipt_quantity_audit enable row level security;
revoke all on greenloop_private.receipt_quantity_audit from public,anon,authenticated;
create or replace function greenloop_private.src_audit_guard()returns trigger language plpgsql set search_path=pg_catalog,public as $$begin raise exception 'Receipt correction history is permanent.'using errcode='55000';end;$$;
drop trigger if exists receipt_quantity_audit_immutable on greenloop_private.receipt_quantity_audit;
create trigger receipt_quantity_audit_immutable before update or delete or truncate on greenloop_private.receipt_quantity_audit for each statement execute function greenloop_private.src_audit_guard();
create or replace function greenloop_private.src_require(write_access boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())
 or not coalesce(public.has_page_capability_v1('reports','view'),false)
 or not coalesce(public.has_page_capability_v1('reports','report_receipt_correction'),false)
 or(write_access and(not coalesce(public.has_page_capability_v1('reports','receipt_quantity_correction'),false)
 or not exists(select 1 from public.user_page_permissions where user_id=auth.uid()and page_key='reports'and access_level='edit')))
 then raise exception 'Stock Receipt Correction permission is required.'using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.src_receipt(p_batch_id uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;r record;entered bigint;reserved bigint;planned bigint;basis jsonb;
begin
 select *into b from public.receiving_batches where id=p_batch_id;
 if not found or b.planned_quantity is null then raise exception 'Select a stock receipt with a recorded received quantity.'using errcode='22023';end if;
 select *into r from greenloop_private.sc_receipts()where batch_id=b.id;
 select count(*)into entered from public.jobs where receiving_batch_id=b.id and deleted_at is null;
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
end;$$;
create or replace function greenloop_private.src_list(p_supplier_id uuid,p_query text,p_offset integer,p_limit integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare rows jsonb;suppliers jsonb;n bigint;names boolean:=coalesce(public.get_my_partner_name_access(),false);
begin
 perform greenloop_private.src_require();
 if p_offset is null or p_offset<0 or p_limit is distinct from 50 or length(coalesce(p_query,''))>160 then raise exception 'Use a valid receipt search and a 50-record page.'using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(s)order by s.supplier_code),'[]')into suppliers from(select distinct r.supplier_id,r.supplier_code,r.supplier_name from greenloop_private.sc_receipts()r where r.supplier_id is not null)s;
 select count(*)into n from greenloop_private.sc_receipts()r where r.received_quantity is not null and(p_supplier_id is null or r.supplier_id=p_supplier_id)
  and(nullif(btrim(p_query),'')is null or position(lower(btrim(p_query))in lower(concat_ws(' ',r.supplier_code,r.supplier_name,r.batch_number,r.invoice_number)))>0);
 select coalesce(jsonb_agg(to_jsonb(s)order by s.received_at desc,s.batch_id),'[]')into rows from(select r.batch_id,r.supplier_id,r.supplier_code,r.supplier_name,r.batch_number,r.invoice_number,r.received_quantity quantity,r.received_at from greenloop_private.sc_receipts()r
  where r.received_quantity is not null and(p_supplier_id is null or r.supplier_id=p_supplier_id)
  and(nullif(btrim(p_query),'')is null or position(lower(btrim(p_query))in lower(concat_ws(' ',r.supplier_code,r.supplier_name,r.batch_number,r.invoice_number)))>0)
  order by r.received_at desc,r.batch_id offset p_offset limit p_limit)s;
 return jsonb_build_object('suppliers',suppliers,'receipts',rows,'total',n,'names_allowed',names);
end;$$;
create or replace function greenloop_private.src_detail(p_batch_id uuid,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare receipt jsonb;history jsonb;n bigint;
begin
 perform greenloop_private.src_require();if p_offset is null or p_offset<0 then raise exception 'Use a valid history page.'using errcode='22023';end if;
 receipt:=greenloop_private.src_receipt(p_batch_id);
 select count(*)into n from greenloop_private.receipt_quantity_audit where batch_id=p_batch_id;
 select coalesce(jsonb_agg(to_jsonb(a)order by created_at desc,request_id),'[]')into history from(select h.request_id,h.created_at,h.old_quantity,h.new_quantity,h.reason,coalesce(p.full_name,'Account no longer available')actor_name from greenloop_private.receipt_quantity_audit h left join public.user_profiles p on p.id=h.actor where h.batch_id=p_batch_id order by h.created_at desc,h.request_id offset p_offset limit 50)a;
 return jsonb_build_object('receipt',receipt,'history',history,'history_total',n);
end;$$;
create or replace function greenloop_private.src_save(p_batch_id uuid,p_snapshot text,p_quantity integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;r jsonb;prior greenloop_private.receipt_quantity_audit%rowtype;
begin
 perform greenloop_private.src_require(true);
 if p_request_id is null or p_batch_id is null or p_snapshot is null or p_quantity is null or p_quantity<1 or p_reason is null or length(btrim(p_reason))not between 5 and 2000 then raise exception 'Enter a positive whole quantity and a reason from 5 to 2000 characters.'using errcode='22023';end if;
 -- Intake and supplier returns lock this same receipt, so the capacity check and write are atomic.
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into b from public.receiving_batches where id=p_batch_id for update;
 if not found then raise exception 'The stock receipt is no longer available.'using errcode='22023';end if;
 select *into prior from greenloop_private.receipt_quantity_audit where request_id=p_request_id;
 if found then
  if prior.batch_id<>p_batch_id or prior.actor<>auth.uid()or prior.expected_snapshot<>p_snapshot or prior.new_quantity<>p_quantity or prior.reason<>btrim(p_reason)then raise exception 'This save reference belongs to a different correction.'using errcode='22023';end if;
  return jsonb_build_object('saved',true,'request_id',p_request_id,'applied_quantity',prior.new_quantity,'detail',greenloop_private.src_detail(p_batch_id,0));
 end if;
 r:=greenloop_private.src_receipt(p_batch_id);
 if r->>'snapshot'is distinct from p_snapshot then raise exception 'This receipt changed after it was loaded. Reload before correcting it.'using errcode='40001';end if;
 if p_quantity=b.planned_quantity then raise exception 'Enter a quantity different from the current received quantity.'using errcode='22023';end if;
 if nullif(r->>'parent_batch_id','')is not null then raise exception 'Replacement receipts retain their recorded replacement quantity. Select the original stock receipt.'using errcode='22023';end if;
 if p_quantity<(r->>'minimum_quantity')::bigint then raise exception 'Quantity cannot be below %: linked IMEIs, reserved returns or saved stock plan already require these units. No records were deleted.',r->>'minimum_quantity'using errcode='22023';end if;
 insert into greenloop_private.receipt_quantity_audit(request_id,batch_id,actor,old_quantity,new_quantity,reason,expected_snapshot,before_receipt,transaction_id)
 values(p_request_id,b.id,auth.uid(),b.planned_quantity,p_quantity,btrim(p_reason),p_snapshot,to_jsonb(b),txid_current());
 update public.receiving_batches set planned_quantity=p_quantity,updated_at=clock_timestamp()where id=b.id and planned_quantity=b.planned_quantity;
 if not found then raise exception 'Receipt quantity changed. Reload before retrying.'using errcode='40001';end if;
 return jsonb_build_object('saved',true,'request_id',p_request_id,'applied_quantity',p_quantity,'detail',greenloop_private.src_detail(p_batch_id,0));
end;$$;
-- Permit just the audited quantity correction, including receipts with return history.
-- All other edits and deletion remain subject to the original Supplier Return guard.
do $guard$declare d text;h text;proof text:=$proof$
 -- greenloop-receipt-quantity-audit-272
 if tg_op='UPDATE'and (to_jsonb(new)-array['planned_quantity','updated_at'])is not distinct from(to_jsonb(old)-array['planned_quantity','updated_at'])
 and exists(select 1 from greenloop_private.receipt_quantity_audit a where a.batch_id=old.id and a.actor=auth.uid()and a.transaction_id=txid_current()and a.old_quantity=old.planned_quantity and a.new_quantity=new.planned_quantity and a.before_receipt=to_jsonb(old))then return new;end if;
$proof$;
begin
 select md5(replace(prosrc,chr(13),'')),replace(pg_get_functiondef(oid),chr(13),'')into h,d from pg_proc where oid='greenloop_private.supplier_return_receipt_guard()'::regprocedure;
 if position('greenloop-receipt-quantity-audit-272'in d)=0 then
  if h<>'5ec29f5d671ecabd32ddad07e30270c7'then raise exception 'Supplier Return receipt boundary differs. No correction was installed.';end if;
  execute replace(d,E'begin\n',E'begin\n'||proof);
 end if;
 update greenloop_private.supplier_return_installation set definition_hash=md5(pg_get_functiondef('greenloop_private.supplier_return_receipt_guard()'::regprocedure))where object_kind='function'and object_identity='greenloop_private.supplier_return_receipt_guard()';
end;$guard$;
create or replace function public.get_stock_receipt_correction_receipts_v1(p_supplier_id uuid default null,p_query text default '',p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.src_list(p_supplier_id,p_query,p_offset,p_limit);end;$$;
create or replace function public.get_stock_receipt_correction_detail_v1(p_batch_id uuid,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.src_detail(p_batch_id,p_offset);end;$$;
create or replace function public.correct_stock_receipt_quantity_v1(p_batch_id uuid,p_snapshot text,p_quantity integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.src_save(p_batch_id,p_snapshot,p_quantity,p_reason,p_request_id);end;$$;
do $catalog$declare c jsonb;begin
 select capabilities into strict c from greenloop_private.page_capability_catalog where page_key='reports';
 if not exists(select 1 from jsonb_array_elements(c)v where v->>'key'='report_receipt_correction')then c:=c||'[{"key":"report_receipt_correction","label":"Stock Receipt Correction: view receipt and history","write":false},{"key":"receipt_quantity_correction","label":"Correct received stock quantity (audited)","write":true}]'::jsonb;end if;
 update greenloop_private.page_capability_catalog set capabilities=c where page_key='reports';
 insert into greenloop_private.report_access_sections values('stock_receipt_correction','{"label":"Stock Receipt Correction","view":"report_receipt_correction","actions":["receipt_quantity_correction"]}')on conflict(report_key)do update set config=excluded.config;
 insert into greenloop_private.report_access_dependencies values('receipt_quantity_correction','"report_receipt_correction"')on conflict(capability)do update set required_views=excluded.required_views;
 -- Preserve all ordinary accounts. Existing owners with full correction access get this new tool once.
 if to_regprocedure('public.get_stock_receipt_correction_version()')is null then
  update greenloop_private.user_page_capabilities u set capabilities=jsonb_set(u.capabilities,'{reports}',(u.capabilities->'reports')||'["report_receipt_correction","receipt_quantity_correction"]'::jsonb)
  where u.capabilities->'reports'?'workflow_correction'and u.capabilities->'reports'?'view'
  and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.user_id and r.role_key::text in('owner','super_admin'))
  and exists(select 1 from public.user_page_permissions p where p.user_id=u.user_id and p.page_key='reports'and p.access_level='edit');
 end if;
end;$catalog$;
insert into greenloop_private.capability_rpc_rules values
 ('get_stock_receipt_correction_receipts_v1','{"page":"reports","capability":"report_receipt_correction","read":true}'),
 ('get_stock_receipt_correction_detail_v1','{"page":"reports","capability":"report_receipt_correction","read":true}'),
 ('correct_stock_receipt_quantity_v1','{"page":"reports","capability":"receipt_quantity_correction"}')on conflict(rpc_name)do update set rule=excluded.rule;
do $permissions$declare f record;sig text;impl text;begin
 for f in select *from(values
 ('public.get_stock_receipt_correction_receipts_v1(uuid,text,integer,integer)','greenloop_private.src_list(uuid,text,integer,integer)'),
 ('public.get_stock_receipt_correction_detail_v1(uuid,integer)','greenloop_private.src_detail(uuid,integer)'),
 ('public.correct_stock_receipt_quantity_v1(uuid,text,integer,text,uuid)','greenloop_private.src_save(uuid,text,integer,text,uuid)'))x(sig,impl)loop
  execute format('revoke all on function %s from public,anon,authenticated',f.sig);execute format('grant execute on function %s to authenticated',f.sig);
  insert into greenloop_private.office_routines values(f.sig,f.impl,md5(pg_get_functiondef(f.impl::regprocedure)),md5(pg_get_functiondef(f.sig::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
 for f in select oid from pg_proc where pronamespace='greenloop_private'::regnamespace and proname in('src_require','src_receipt','src_list','src_detail','src_save','src_audit_guard')loop execute format('revoke all on function %s from public,anon,authenticated',f.oid::regprocedure);end loop;
end;$permissions$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
update greenloop_private.report_access_config_seal set sections_hash=(select md5(jsonb_agg(to_jsonb(s)order by report_key)::text)from greenloop_private.report_access_sections s),dependencies_hash=(select md5(jsonb_agg(to_jsonb(d)order by capability)::text)from greenloop_private.report_access_dependencies d);
create table if not exists greenloop_private.receipt_correction_installation(identity text primary key,hash text not null);
alter table greenloop_private.receipt_correction_installation enable row level security;revoke all on greenloop_private.receipt_correction_installation from public,anon,authenticated;
create or replace function public.get_stock_receipt_correction_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=11 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.receipt_correction_installation)
 and not has_table_privilege('authenticated','greenloop_private.receipt_quantity_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.receipt_quantity_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.src_save(uuid,text,integer,text,uuid)','EXECUTE')and not has_function_privilege('anon','public.correct_stock_receipt_quantity_v1(uuid,text,integer,text,uuid)','EXECUTE')
 and has_function_privilege('authenticated','public.correct_stock_receipt_quantity_v1(uuid,text,integer,text,uuid)','EXECUTE')
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.receipt_quantity_audit'::regclass and tgname='receipt_quantity_audit_immutable'and tgenabled='O')
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities@>'[{"key":"receipt_quantity_correction","write":true},{"key":"report_receipt_correction","write":false}]'::jsonb)
 and exists(select 1 from greenloop_private.report_access_sections where report_key='stock_receipt_correction'and config->>'view'='report_receipt_correction')
 then '20261109-stock-receipt-correction-1'end;$$;
revoke all on function public.get_stock_receipt_correction_version()from public;grant execute on function public.get_stock_receipt_correction_version()to anon,authenticated;
insert into greenloop_private.receipt_correction_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where
 p.pronamespace='greenloop_private'::regnamespace and p.proname in('src_require','src_receipt','src_list','src_detail','src_save','src_audit_guard','supplier_return_receipt_guard')
 or p.pronamespace='public'::regnamespace and p.proname in('get_stock_receipt_correction_receipts_v1','get_stock_receipt_correction_detail_v1','correct_stock_receipt_quantity_v1','get_stock_receipt_correction_version')on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_stock_receipt_correction_version()is distinct from '20261109-stock-receipt-correction-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_report_section_access_version()is distinct from '20261104-report-permissions-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Stock Receipt Correction verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$src_install$;
select public.get_stock_receipt_correction_version()as installed_stock_receipt_correction_version;
