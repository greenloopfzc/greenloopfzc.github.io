-- Audited reassignment of an original stock receipt; installation changes no business rows.
do $install$
declare old text;updated text;sig text;api_oid oid;target_oid oid;n integer;t record;c record;b record;reviewed jsonb:='[]';sealed text[]:=array[
'greenloop_private.rss_require(boolean)','greenloop_private.rss_scope(uuid)','greenloop_private.rss_read(uuid,uuid,integer,text)','greenloop_private.rss_save(uuid,uuid,text,text,uuid)','greenloop_private.rss_permitted_receipt(jsonb,jsonb)','greenloop_private.rss_corrected_batch(uuid)','greenloop_private.rss_audit_guard()','public.get_stock_receipt_supplier_v1(uuid,uuid,integer,text)','public.correct_stock_receipt_supplier_v1(uuid,uuid,text,text,uuid)','public.get_receipt_supplier_correction_version()'];
begin
perform set_config('search_path','pg_catalog,public',true);
if to_regprocedure('public.get_receipt_supplier_correction_version()')is not null then
 if public.get_receipt_supplier_correction_version()is distinct from '20261119-receipt-supplier-correction-1'then raise exception 'Existing receipt supplier correction integrity differs. Nothing installed.';end if;return;
end if;
if public.get_chaman_custody_notice_version()is distinct from '20261119-chaman-custody-notice-1'or public.get_stock_receipt_correction_version()is distinct from '20261109-stock-receipt-correction-1'or public.get_imei_grade_audit_version()is distinct from '20261114-imei-grade-audit-1'then raise exception 'Verify receipt correction, IMEI audit and Chaman prerequisites first.';end if;
if not exists(select 1 from greenloop_private.page_capability_installation where identity='catalog'and hash=(select md5(jsonb_agg(to_jsonb(r)order by page_key)::text)from greenloop_private.page_capability_catalog r))or not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Permission catalog or RPC rules integrity differs.';end if;
create table greenloop_private.receipt_supplier_audit(
 request_id uuid primary key,root_batch_id uuid not null,batch_ids uuid[]not null,actor uuid not null,created_at timestamptz not null default clock_timestamp(),transaction_id bigint not null,
 old_supplier_id uuid not null,new_supplier_id uuid not null,expected_snapshot text not null,reason text not null check(length(btrim(reason))between 5 and 2000),
 old_label jsonb not null,new_label jsonb not null,before_data jsonb not null,check(old_supplier_id<>new_supplier_id));
create table greenloop_private.receipt_supplier_permits(transaction_id bigint not null,backend_pid integer not null,actor uuid not null,request_id uuid not null,relation text not null,row_id uuid not null,old_hash text not null,new_supplier_id uuid not null,primary key(transaction_id,backend_pid,relation,row_id));
 alter table greenloop_private.receipt_supplier_permits enable row level security;revoke all on greenloop_private.receipt_supplier_permits from public,anon,authenticated;
create index receipt_supplier_audit_root on greenloop_private.receipt_supplier_audit(root_batch_id,created_at desc,request_id);
create index receipt_supplier_audit_scope on greenloop_private.receipt_supplier_audit using gin(batch_ids);
create index receipt_supplier_audit_transaction on greenloop_private.receipt_supplier_audit(transaction_id,actor);
alter table greenloop_private.receipt_supplier_audit enable row level security;revoke all on greenloop_private.receipt_supplier_audit from public,anon,authenticated;
create or replace function greenloop_private.rss_audit_guard()returns trigger language plpgsql set search_path=pg_catalog,public as $f$begin raise exception 'Supplier correction history is permanent.'using errcode='55000';end;$f$;
create trigger receipt_supplier_audit_immutable before update or delete or truncate on greenloop_private.receipt_supplier_audit for each statement execute function greenloop_private.rss_audit_guard();
create or replace function greenloop_private.rss_require(p_write boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $f$
begin
 perform greenloop_private.src_require(false);
 if p_write and(not coalesce(public.has_page_capability_v1('reports','receipt_supplier_correction'),false)or not exists(select 1 from public.user_page_permissions where user_id=auth.uid()and page_key='reports'and access_level='edit'))then raise exception 'Stock supplier correction permission is required.'using errcode='42501';end if;
end;$f$;
create or replace function greenloop_private.rss_scope(p_batch uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare b public.receiving_batches%rowtype;ids uuid[];jobs jsonb;returns jsonb;batches jsonb;result jsonb;
begin
 select *into b from public.receiving_batches where id=p_batch;
 if not found or b.supplier_id is null or b.planned_quantity is null then raise exception 'Select an original stock receipt with a saved supplier and quantity.'using errcode='22023';end if;
 if exists(select 1 from greenloop_private.srp_receipts where replacement_batch_id=p_batch and original_batch_id<>p_batch)then raise exception 'Select the original stock receipt to correct its supplier and linked replacements together.'using errcode='22023';end if;
 with recursive tree(id)as(select b.id union select r.replacement_batch_id from greenloop_private.srp_receipts r join tree t on r.original_batch_id=t.id)
 select array_agg(id order by id)into ids from tree;
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into batches from public.receiving_batches x where id=any(ids);
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into jobs from public.jobs x where receiving_batch_id=any(ids);
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into returns from public.supplier_returns x where batch_id=any(ids)or job_id in(select (j->>'id')::uuid from jsonb_array_elements(jobs)j);
 if exists(select 1 from jsonb_array_elements(batches||jobs||returns)x where nullif(x->>'supplier_id','')is not null and x->>'supplier_id'<>b.supplier_id::text)then raise exception 'Linked supplier identities differ. Reload and review the inconsistent stock links before correcting this receipt.'using errcode='40001';end if;
 if exists(select 1 from jsonb_array_elements(returns)x where nullif(x->>'batch_id','')is not null and not((x->>'batch_id')::uuid=any(ids)))then raise exception 'A linked return belongs to another receipt. Review its stock link first.'using errcode='40001';end if;
 result:=jsonb_build_object('root',to_jsonb(b),'batch_ids',to_jsonb(ids),'batches',batches,'jobs',jobs,'returns',returns,
 'supplier',(select to_jsonb(s)from public.suppliers s where s.id=b.supplier_id),
 'plans',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.stock_batch_plan_lines x where receiving_batch_id=any(ids)),'[]'),
 'replacements',coalesce((select jsonb_agg(to_jsonb(x)order by id)from greenloop_private.srp_receipts x where original_batch_id=any(ids)),'[]'),
 'chaman',coalesce((select jsonb_agg(to_jsonb(x)order by id)from greenloop_private.chaman_lines x where job_id in(select (j->>'id')::uuid from jsonb_array_elements(jobs)j)),'[]'),
 'box_workflow',coalesce((select jsonb_agg(to_jsonb(x)order by box_id)from greenloop_private.box_workflow x where box_id in(select box_id from public.export_box_items where device_id in(select (j->>'device_id')::uuid from jsonb_array_elements(jobs)j))),'[]'),
 'boxes',coalesce((select jsonb_agg(to_jsonb(x)order by id)from public.export_box_items x where device_id in(select (j->>'device_id')::uuid from jsonb_array_elements(jobs)j)),'[]'));
 return result;
end;$f$;
create or replace function greenloop_private.rss_read(p_batch uuid,p_supplier uuid default null,p_offset integer default 0,p_history_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$
declare ctx jsonb;target public.suppliers%rowtype;names boolean;history jsonb;n bigint;history_token text;
begin
 perform greenloop_private.rss_require(false);if p_offset is null or p_offset<0 or p_offset%50<>0 then raise exception 'Use a valid 50-record history page.'using errcode='22023';end if;
 ctx:=greenloop_private.rss_scope(p_batch);names:=coalesce(public.get_my_partner_name_access(),false);
 if p_supplier is not null then
  select *into target from public.suppliers where id=p_supplier and is_active and deleted_at is null;
  if not found then raise exception 'Choose an active supplier.'using errcode='22023';end if;
  if target.id::text=ctx->'root'->>'supplier_id'then raise exception 'Choose a supplier different from the current stock supplier.'using errcode='22023';end if;
 end if;
 select count(*),md5(coalesce(jsonb_agg(request_id order by created_at desc,request_id),'[]')::text)into n,history_token from greenloop_private.receipt_supplier_audit where root_batch_id=p_batch;
 if(p_offset>0 and p_history_snapshot is null)or(p_history_snapshot is not null and p_history_snapshot<>history_token)then raise exception 'Supplier correction history changed. Reload the receipt before paging.'using errcode='40001';end if;
 select coalesce(jsonb_agg(x order by created_at desc,request_id),'[]')into history from(select h.request_id,h.created_at,coalesce(u.full_name,'Not recorded')actor_name,h.reason,
 (h.before_data->'root'->>'planned_quantity')::integer quantity,h.old_label->>'supplier_code'old_code,case when names then h.old_label->>'company_name'end old_name,h.new_label->>'supplier_code'new_code,case when names then h.new_label->>'company_name'end new_name
 from greenloop_private.receipt_supplier_audit h left join public.user_profiles u on u.id=h.actor where h.root_batch_id=p_batch order by h.created_at desc,h.request_id offset p_offset limit 50)x;
 return jsonb_build_object('version','20261119-receipt-supplier-correction-1','batch_id',p_batch,'batch_number',ctx->'root'->'batch_number','invoice_number',ctx->'root'->'invoice_number','quantity',ctx->'root'->'planned_quantity',
 'supplier_id',ctx->'root'->'supplier_id','supplier_code',ctx->'supplier'->'supplier_code','supplier_name',case when names then ctx->'supplier'->'company_name'end,
 'target_id',target.id,'target_code',target.supplier_code,'target_name',case when names then target.company_name end,
 'batch_count',jsonb_array_length(ctx->'batches'),'job_count',jsonb_array_length(ctx->'jobs'),'phone_count',(select count(distinct x->>'device_id')from jsonb_array_elements(ctx->'jobs')x),
 'return_count',jsonb_array_length(ctx->'returns'),'replacement_count',jsonb_array_length(ctx->'replacements'),
 'snapshot',md5(jsonb_build_object('context',ctx,'target',to_jsonb(target))::text),
 'suppliers',coalesce((select jsonb_agg(jsonb_build_object('supplier_id',s.id,'supplier_code',s.supplier_code,'supplier_name',case when names then s.company_name end)order by s.supplier_code,s.id)from public.suppliers s where is_active and deleted_at is null),'[]'),
 'history',history,'history_total',n,'history_snapshot',history_token,'offset',p_offset,'limit',50);
end;$f$;
create or replace function greenloop_private.rss_permitted_receipt(p_old jsonb,p_new jsonb)returns boolean language sql stable security definer set search_path=pg_catalog,public as $f$
 select (p_old-'supplier_id')is not distinct from(p_new-'supplier_id')and p_old->>'supplier_id'is distinct from p_new->>'supplier_id'and exists(
 select 1 from greenloop_private.receipt_supplier_audit a where a.transaction_id=txid_current()and a.actor=auth.uid()and a.new_supplier_id::text=p_new->>'supplier_id'
 and a.before_data->'batches'@>jsonb_build_array(p_old));$f$;
create or replace function greenloop_private.rss_corrected_batch(p_batch uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $f$
 select exists(select 1 from greenloop_private.receipt_supplier_audit a where a.batch_ids@>array[p_batch]);$f$;
create or replace function greenloop_private.rss_save(p_batch uuid,p_supplier uuid,p_snapshot text,p_reason text,p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $f$
declare ctx jsonb;preview jsonb;prior greenloop_private.receipt_supplier_audit%rowtype;ids uuid[];target public.suppliers%rowtype;old_supplier uuid;stamp timestamptz:=clock_timestamp();
begin
 perform greenloop_private.rss_require(true);
 if p_request is null or p_batch is null or p_supplier is null or p_snapshot is null or p_reason is null or length(btrim(p_reason))not between 5 and 2000 then raise exception 'Select the stock and supplier, review the change and enter a reason from 5 to 2000 characters.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(20420261026);perform pg_advisory_xact_lock(19920261026);
 select *into prior from greenloop_private.receipt_supplier_audit where request_id=p_request;
 if found then
  if prior.root_batch_id<>p_batch or prior.actor<>auth.uid()or prior.new_supplier_id<>p_supplier or prior.expected_snapshot<>p_snapshot or prior.reason<>btrim(p_reason)then raise exception 'This save reference belongs to a different supplier correction.'using errcode='22023';end if;
  return jsonb_build_object('saved',true,'request_id',p_request,'applied_supplier_id',prior.new_supplier_id,'supplier_detail',greenloop_private.rss_read(p_batch,null,0),'detail',greenloop_private.src_detail(p_batch,0));
 end if;
 perform 1 from public.receiving_batches where id=p_batch for update;
 ctx:=greenloop_private.rss_scope(p_batch);select array_agg(x::uuid)into ids from jsonb_array_elements_text(ctx->'batch_ids')x;
 perform 1 from public.receiving_batches where id=any(ids)order by id for update;
 perform 1 from public.jobs where receiving_batch_id=any(ids)order by id for update;
 perform 1 from public.supplier_returns where batch_id=any(ids)or job_id in(select id from public.jobs where receiving_batch_id=any(ids))order by id for update;
 perform 1 from public.suppliers where id=p_supplier for share;
 perform 1 from greenloop_private.box_workflow where box_id in(select box_id from public.export_box_items where job_id in(select id from public.jobs where receiving_batch_id=any(ids)))order by box_id for update;
 preview:=greenloop_private.rss_read(p_batch,p_supplier,0);
 if preview->>'snapshot'is distinct from p_snapshot then raise exception 'This stock or supplier changed after review. Reload and review the supplier correction again.'using errcode='40001';end if;
 ctx:=greenloop_private.rss_scope(p_batch);old_supplier:=(ctx->'root'->>'supplier_id')::uuid;
 select *into target from public.suppliers where id=p_supplier and is_active and deleted_at is null;
 if not found then raise exception 'Choose an active supplier.'using errcode='22023';end if;
 insert into greenloop_private.receipt_supplier_audit(request_id,root_batch_id,batch_ids,actor,created_at,transaction_id,old_supplier_id,new_supplier_id,expected_snapshot,reason,old_label,new_label,before_data)
 values(p_request,p_batch,ids,auth.uid(),stamp,txid_current(),old_supplier,p_supplier,p_snapshot,btrim(p_reason),ctx->'supplier',to_jsonb(target),ctx);
 insert into greenloop_private.receipt_supplier_permits select txid_current(),pg_backend_pid(),auth.uid(),p_request,k,(x->>'id')::uuid,md5(x::text),p_supplier from unnest(array['batches','jobs'])k cross join lateral jsonb_array_elements(ctx->k)x;
 -- Existing private return capabilities permit only this function's explicit
 -- supplier-link updates. Permanent events and frozen source snapshots stay intact.
 insert into greenloop_private.supplier_return_capabilities(transaction_id,backend_pid,return_id)
 select txid_current(),pg_backend_pid(),(x->>'id')::uuid from jsonb_array_elements(ctx->'returns')x on conflict do nothing;
 update public.receiving_batches set supplier_id=p_supplier where id=any(ids);
 update public.jobs set supplier_id=p_supplier where receiving_batch_id=any(ids);
 update public.supplier_returns set supplier_id=p_supplier where id in(select (x->>'id')::uuid from jsonb_array_elements(ctx->'returns')x);
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id,created_at)
 select distinct on(j.device_id)j.device_id,j.id,'receipt_supplier_correction','Stock supplier corrected',jsonb_build_object('audit_id',p_request,'reason',btrim(p_reason),'batch_id',p_batch,
 'before',jsonb_build_object('supplier_code',ctx->'supplier'->>'supplier_code','supplier_name',ctx->'supplier'->>'company_name'),
 'after',jsonb_build_object('supplier_code',target.supplier_code,'supplier_name',target.company_name)),auth.uid(),stamp
 from public.jobs j where j.receiving_batch_id=any(ids)order by j.device_id,j.received_at desc,j.id;
 delete from greenloop_private.receipt_supplier_permits where transaction_id=txid_current()and backend_pid=pg_backend_pid()and request_id=p_request;
 delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id in(select (x->>'id')::uuid from jsonb_array_elements(ctx->'returns')x);
 return jsonb_build_object('saved',true,'request_id',p_request,'applied_supplier_id',p_supplier,'supplier_detail',greenloop_private.rss_read(p_batch,null,0),'detail',greenloop_private.src_detail(p_batch,0));
end;$f$;
create or replace function public.get_stock_receipt_supplier_v1(p_batch_id uuid,p_supplier_id uuid default null,p_offset integer default 0,p_expected_history_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $f$begin perform greenloop_private.require_office_network();return greenloop_private.rss_read(p_batch_id,p_supplier_id,p_offset,p_expected_history_snapshot);end;$f$;
create or replace function public.correct_stock_receipt_supplier_v1(p_batch_id uuid,p_supplier_id uuid,p_snapshot text,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $f$begin perform greenloop_private.require_office_network();return greenloop_private.rss_save(p_batch_id,p_supplier_id,p_snapshot,p_reason,p_request_id);end;$f$;
revoke all on function greenloop_private.rss_require(boolean),greenloop_private.rss_scope(uuid),greenloop_private.rss_read(uuid,uuid,integer,text),greenloop_private.rss_save(uuid,uuid,text,text,uuid),greenloop_private.rss_permitted_receipt(jsonb,jsonb),greenloop_private.rss_corrected_batch(uuid),greenloop_private.rss_audit_guard(),public.get_stock_receipt_supplier_v1(uuid,uuid,integer,text),public.correct_stock_receipt_supplier_v1(uuid,uuid,text,text,uuid)from public,anon,authenticated;
grant execute on function public.get_stock_receipt_supplier_v1(uuid,uuid,integer,text),public.correct_stock_receipt_supplier_v1(uuid,uuid,text,text,uuid)to authenticated;
-- Permit only the complete, immutable-audited receipt supplier field change.
sig:='greenloop_private.supplier_return_receipt_guard()';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'310724378f097327684bc6f269664ae5'then raise exception 'Receipt supplier guard boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
select count(*)into n from regexp_matches(old,E'begin\\s','g');if n<>1 then raise exception 'Receipt guard entry differs.';end if;
updated:=regexp_replace(old,E'begin\\s',E'begin\n if tg_op=''UPDATE''and greenloop_private.rss_permitted_receipt(to_jsonb(old),to_jsonb(new))then return new;end if;\n');execute updated;
-- Frozen return source snapshots remain historical; current return displays use
-- the corrected canonical link only for an explicitly corrected receipt.
sig:='greenloop_private.supplier_return_record(uuid)';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'f1085e6102b95a7a98f3a660a2540077'then raise exception 'Return record display boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
updated:=replace(old,$q$coalesce(r.source_snapshot->>'supplier_code',s.supplier_code)$q$,$q$case when greenloop_private.rss_corrected_batch(coalesce(r.batch_id,j.receiving_batch_id))then s.supplier_code else coalesce(r.source_snapshot->>'supplier_code',s.supplier_code)end$q$);
updated:=replace(updated,$q$coalesce(r.source_snapshot->>'supplier_name',s.company_name)$q$,$q$case when greenloop_private.rss_corrected_batch(coalesce(r.batch_id,j.receiving_batch_id))then s.company_name else coalesce(r.source_snapshot->>'supplier_name',s.company_name)end$q$);if updated=old then raise exception 'Return supplier display pattern differs.';end if;execute updated;
-- Resolve the actual registered Office implementation; generated names vary.
api_oid:='public.list_simple_stock_returns(date,date)'::regprocedure;
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into n,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
if n<>1 or target_oid is null or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Missing, ambiguous or changed registered Stock Return implementation.';end if;
if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)then raise exception 'Stock Return implementation shape differs.';end if;
if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 or position('require_office_network()'in regexp_replace(pg_get_functiondef(api_oid),'\s','','g'))=0 then raise exception 'Disconnected Stock Return Office implementation.';end if;
old:=pg_get_functiondef(target_oid);sig:=target_oid::regprocedure::text;sealed:=sealed||api_oid::regprocedure::text;
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'e19bb2d268cb01faccffe6d4cab9a4bd'then raise exception 'Stock Return list supplier boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
updated:=replace(old,$q$coalesce(r.source_snapshot->>'supplier_code',s.supplier_code)$q$,$q$case when greenloop_private.rss_corrected_batch(r.batch_id)then s.supplier_code else coalesce(r.source_snapshot->>'supplier_code',s.supplier_code)end$q$);
updated:=replace(updated,$q$coalesce(r.source_snapshot->>'supplier_name',s.company_name)$q$,$q$case when greenloop_private.rss_corrected_batch(r.batch_id)then s.company_name else coalesce(r.source_snapshot->>'supplier_name',s.company_name)end$q$);if updated=old then raise exception 'Stock Return list supplier pattern differs.';end if;execute updated;

create or replace function greenloop_private.rss_permitted_supplier(p_table text,p_old jsonb,p_new jsonb)returns boolean language sql stable security definer set search_path=pg_catalog,public as $f$
 select p_table in('jobs','batches')and(p_old-'supplier_id')is not distinct from(p_new-'supplier_id')and p_old->>'supplier_id'is distinct from p_new->>'supplier_id'and exists(
 select 1 from greenloop_private.receipt_supplier_permits p join greenloop_private.receipt_supplier_audit a on a.request_id=p.request_id
 where p.transaction_id=txid_current()and p.backend_pid=pg_backend_pid()and p.actor=auth.uid()and p.relation=p_table and p.row_id=(p_old->>'id')::uuid and p.old_hash=md5(p_old::text)and p.new_supplier_id::text=p_new->>'supplier_id'and a.transaction_id=p.transaction_id and a.actor=p.actor);$f$;
create or replace function greenloop_private.rss_permitted_receipt(p_old jsonb,p_new jsonb)returns boolean language sql stable security definer set search_path=pg_catalog,public as $f$select greenloop_private.rss_permitted_supplier('batches',p_old,p_new);$f$;
revoke all on function greenloop_private.rss_permitted_supplier(text,jsonb,jsonb)from public,anon,authenticated;
sealed:=sealed||array['greenloop_private.rss_permitted_supplier(text,jsonb,jsonb)'];
sig:='greenloop_private.box_source_changed()';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'693b8928e0629d8ff4812f375803040d'then raise exception 'Box source correction boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
if(length(old)-length(replace(old,'begin','')))/length('begin')<>1 then raise exception 'Box source entry changed.';end if;
updated:=replace(old,'begin',$patch$begin
 -- An audited supplier-link correction changes no physical stock, box status,
 -- packing verification or original printed evidence. All other edits retain
 -- the existing mandatory source recheck. Record this metadata correction once.
 if tg_op='UPDATE'and tg_table_name in('jobs','receiving_batches')and greenloop_private.rss_permitted_supplier(case tg_table_name when 'jobs'then 'jobs'else 'batches'end,to_jsonb(old),to_jsonb(new))then
  for r in select distinct bx.id,bx.box_number,a.request_id,a.reason from public.export_boxes bx join public.export_box_items it on it.box_id=bx.id
   cross join greenloop_private.receipt_supplier_audit a where a.transaction_id=txid_current()and a.actor=auth.uid()and a.new_supplier_id=new.supplier_id
   and exists(select 1 from greenloop_private.receipt_supplier_permits p where p.transaction_id=txid_current()and p.backend_pid=pg_backend_pid()and p.relation=case tg_table_name when 'jobs'then 'jobs'else 'batches'end and p.row_id=new.id and p.request_id=a.request_id)
   and((tg_table_name='jobs'and it.job_id=new.id)or(tg_table_name='receiving_batches'and it.job_id in(select j.id from public.jobs j where j.receiving_batch_id=new.id)))loop
   if not exists(select 1 from greenloop_private.box_workflow_audit h where h.box_id=r.id and h.action='source_corrected'and h.details->>'supplier_correction_id'=r.request_id::text)then
    insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details)values(r.id,r.box_number,'source_corrected',auth.uid(),jsonb_build_object('supplier_correction_id',r.request_id,'correction_kind','supplier_link_only','old_supplier_id',old.supplier_id,'new_supplier_id',new.supplier_id,'reason',r.reason));
   end if;
  end loop;
  return new;
 end if;
$patch$);execute updated;


-- Resolve current supplier labels without rewriting original custody snapshots.
create or replace function greenloop_private.rss_chaman_details(p_details jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $f$
 select p_details||coalesce((select jsonb_build_object('supplier_id',s.id,'supplier_code',s.supplier_code,'supplier_name',case when public.get_my_partner_name_access()then s.company_name end)
 from public.receiving_batches rb join public.suppliers s on s.id=rb.supplier_id where rb.id=(p_details->>'batch_id')::uuid and greenloop_private.rss_corrected_batch(rb.id)),'{}'::jsonb);$f$;
revoke all on function greenloop_private.rss_chaman_details(jsonb)from public,anon,authenticated;
sealed:=sealed||array['greenloop_private.rss_chaman_details(jsonb)'];
sig:='greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'f197f7b397c808b0da7be350cc106d71'then raise exception 'Chaman supplier display boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
updated:=replace(replace(old,'line.details','greenloop_private.rss_chaman_details(line.details)'),'l.details','greenloop_private.rss_chaman_details(l.details)');if updated=old then raise exception 'Chaman details pattern differs.';end if;execute updated;
sig:='greenloop_private.chaman_preview(text,jsonb)';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'1125b4854ca1b00bee44d570c76df031'then raise exception 'Chaman supplier display boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
updated:=replace(replace(old,'line.details','greenloop_private.rss_chaman_details(line.details)'),'l.details','greenloop_private.rss_chaman_details(l.details)');if updated=old then raise exception 'Chaman details pattern differs.';end if;execute updated;
sig:='greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)';old:=pg_get_functiondef(sig::regprocedure);
if md5(regexp_replace(replace(old,chr(13),''),'FUNCTION greenloop_private\.[^(]+\(','FUNCTION greenloop_private.REVIEWED('))<>'c60816a140c3f6a69ed10b2650eb1977'then raise exception 'Chaman supplier display boundary differs.';end if;
reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=sealed||sig;
updated:=replace(replace(old,'line.details','greenloop_private.rss_chaman_details(line.details)'),'l.details','greenloop_private.rss_chaman_details(l.details)');if updated=old then raise exception 'Chaman details pattern differs.';end if;execute updated;

-- Exact prior hash receipts only; never bless an unrelated changed definition.
for b in select *from jsonb_to_recordset(reviewed)as x(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))v(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'
   and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.office_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
 update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(identity)=to_regprocedure(b.identity)and wrapped_hash=b.hash;
end loop;
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"receipt_supplier_correction","label":"Correct stock supplier (audited)","write":true}]'::jsonb where page_key='reports'and not(capabilities@>'[{"key":"receipt_supplier_correction"}]');
update greenloop_private.user_page_capabilities uc set capabilities=jsonb_set(capabilities,'{reports}',coalesce(capabilities->'reports','[]')||'["receipt_supplier_correction"]')where capabilities->'reports'?'report_receipt_correction'and not(capabilities->'reports'?'receipt_supplier_correction')and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=uc.user_id and r.role_key::text in('owner','super_admin'));
update greenloop_private.report_access_sections set config=jsonb_set(config,'{actions}',(config->'actions')||'["receipt_supplier_correction"]')where report_key='stock_receipt_correction'and not(config->'actions'?'receipt_supplier_correction');
insert into greenloop_private.report_access_dependencies values('receipt_supplier_correction','"report_receipt_correction"')on conflict(capability)do update set required_views=excluded.required_views;
insert into greenloop_private.capability_rpc_rules values('get_stock_receipt_supplier_v1','{"page":"reports","capability":"report_receipt_correction","read":true}'),('correct_stock_receipt_supplier_v1','{"page":"reports","capability":"receipt_supplier_correction"}'),('get_receipt_supplier_correction_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by page_key)::text)from greenloop_private.page_capability_catalog r)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table greenloop_private.receipt_supplier_installation(identity text primary key,hash text not null);
alter table greenloop_private.receipt_supplier_installation enable row level security;revoke all on greenloop_private.receipt_supplier_installation from public,anon,authenticated;
create or replace function public.get_receipt_supplier_correction_version()returns text language sql stable security definer set search_path=pg_catalog,public as $f$
 select case when public.get_chaman_custody_notice_version()='20261119-chaman-custody-notice-1'and public.get_stock_receipt_correction_version()='20261109-stock-receipt-correction-1'
 and(select count(*)=20 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.receipt_supplier_installation)
 and(select count(*)=1 and bool_and(original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))from greenloop_private.office_routines where to_regprocedure(identity)='public.list_simple_stock_returns(date,date)'::regprocedure)
 and exists(select 1 from greenloop_private.office_routines o join greenloop_private.receipt_supplier_installation i on to_regprocedure(i.identity)=to_regprocedure(o.implementation)where to_regprocedure(o.identity)='public.list_simple_stock_returns(date,date)'::regprocedure and position((select 'greenloop_private.'||proname||'('from pg_proc where oid=to_regprocedure(o.implementation))in regexp_replace(replace(pg_get_functiondef(to_regprocedure(o.identity)),'"',''),'\s','','g'))>0)
 and not exists(select 1 from greenloop_private.receipt_supplier_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.receipt_supplier_audit'::regclass and tgname='receipt_supplier_audit_immutable'and tgenabled='O'and tgfoid='greenloop_private.rss_audit_guard()'::regprocedure)
 and not exists(select 1 from pg_class where oid in('greenloop_private.receipt_supplier_audit'::regclass,'greenloop_private.receipt_supplier_installation'::regclass,'greenloop_private.receipt_supplier_permits'::regclass)and not relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.receipt_supplier_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.receipt_supplier_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.receipt_supplier_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.receipt_supplier_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.receipt_supplier_permits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.receipt_supplier_permits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and has_function_privilege('authenticated','public.correct_stock_receipt_supplier_v1(uuid,uuid,text,text,uuid)','EXECUTE')and not has_function_privilege('anon','public.correct_stock_receipt_supplier_v1(uuid,uuid,text,text,uuid)','EXECUTE')
 and has_function_privilege('authenticated','public.get_stock_receipt_supplier_v1(uuid,uuid,integer,text)','EXECUTE')and not has_function_privilege('anon','public.get_stock_receipt_supplier_v1(uuid,uuid,integer,text)','EXECUTE')
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities@>'[{"key":"receipt_supplier_correction","write":true}]')
 and exists(select 1 from greenloop_private.report_access_sections where report_key='stock_receipt_correction'and config->'actions'?'receipt_supplier_correction')
 and exists(select 1 from greenloop_private.report_access_dependencies where capability='receipt_supplier_correction'and required_views='"report_receipt_correction"')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_receipt_supplier_v1'and rule='{"page":"reports","capability":"report_receipt_correction","read":true}'::jsonb)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='correct_stock_receipt_supplier_v1'and rule='{"page":"reports","capability":"receipt_supplier_correction"}'::jsonb)
 and exists(select 1 from greenloop_private.page_capability_installation where identity='catalog'and hash=(select md5(jsonb_agg(to_jsonb(r)order by page_key)::text)from greenloop_private.page_capability_catalog r))
 and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))
 then '20261119-receipt-supplier-correction-1'end;$f$;
revoke all on function public.get_receipt_supplier_correction_version()from public;grant execute on function public.get_receipt_supplier_correction_version()to anon,authenticated;
insert into greenloop_private.receipt_supplier_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_receipt_supplier_correction_version()is distinct from '20261119-receipt-supplier-correction-1'then raise exception 'Receipt supplier correction verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_receipt_supplier_correction_version()as installed_receipt_supplier_correction_version;
