-- Atomic installer: one SQL statement; no temporary-table/session dependency.
DO $chaman_install$ BEGIN EXECUTE $chaman_ddl$
-- Chaman Shop: audited, admin-only dispatch/receipt/return. No sales.
create sequence if not exists greenloop_private.chaman_document_seq;
create table if not exists greenloop_private.chaman_documents(id uuid primary key default gen_random_uuid(),reference text not null unique,direction text not null check(direction in('out','return')),created_at timestamptz not null default now(),created_by uuid not null references auth.users(id),notes text not null default '');
create table if not exists greenloop_private.chaman_lines(id uuid primary key default gen_random_uuid(),out_document uuid not null references greenloop_private.chaman_documents(id),return_document uuid references greenloop_private.chaman_documents(id),device_id uuid not null references public.devices(id),job_id uuid not null references public.jobs(id),imei text not null,details jsonb not null,original_job_status public.job_status not null,original_device_status public.job_status not null,phase text not null check(phase in('out_pending','shop','return_pending','company')),shop_received_at timestamptz,company_received_at timestamptz,shop_received_by uuid references auth.users(id),company_received_by uuid references auth.users(id));
create unique index if not exists chaman_one_location on greenloop_private.chaman_lines(device_id)where phase<>'company';
create index if not exists chaman_out_document on greenloop_private.chaman_lines(out_document);
create index if not exists chaman_return_document on greenloop_private.chaman_lines(return_document);
create table if not exists greenloop_private.chaman_commands(actor uuid not null,request_id uuid not null,signature text not null,result jsonb not null,created_at timestamptz not null default now(),primary key(actor,request_id));
alter table greenloop_private.chaman_documents enable row level security;alter table greenloop_private.chaman_lines enable row level security;alter table greenloop_private.chaman_commands enable row level security;
revoke all on greenloop_private.chaman_documents,greenloop_private.chaman_lines,greenloop_private.chaman_commands from public,anon,authenticated;
revoke all on sequence greenloop_private.chaman_document_seq from public,anon,authenticated;
create or replace function greenloop_private.chaman_access(write_action boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if not coalesce(public.is_active_staff(),false)or not coalesce(public.has_role(array['owner','super_admin']::public.app_role_key[]),false)then raise exception 'Chaman Shop currently requires Admin access.'using errcode='42501';end if;
 perform greenloop_private.pf_cap('chaman_shop','view');if write_action then perform greenloop_private.pf_cap('chaman_shop','entry');end if;
end;$$;
create or replace function greenloop_private.chaman_phone(p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r record;begin
 select j.id job_id,j.current_status job_status,d.id device_id,d.current_status device_status,d.imei_1 imei,d.model,d.storage_gb,d.color,d.gc_grade grade,j.receiving_batch_id batch_id,b.batch_number,b.planned_quantity receipt_quantity,b.invoice_number,s.supplier_code,case when public.get_my_partner_name_access()then s.company_name end supplier_name,j.ownership_type into r
 from public.devices d join public.jobs j on j.device_id=d.id and j.deleted_at is null left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=coalesce(j.supplier_id,b.supplier_id)
 where d.imei_1=p_imei and d.deleted_at is null order by j.received_at desc,j.created_at desc,j.id desc limit 1;
 if r.device_id is null then raise exception 'IMEI % was not found in Greenloop stock.',p_imei;end if;
 return to_jsonb(r);
end;$$;
create or replace function greenloop_private.chaman_move(p_action text,p_imeis jsonb,p_document_id uuid,p_notes text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
#variable_conflict use_variable
declare phone jsonb;imei text;line greenloop_private.chaman_lines%rowtype;doc greenloop_private.chaman_documents%rowtype;signature text;prior record;outcome jsonb;ids text[];n integer;
begin
 perform greenloop_private.chaman_access(true);
 if p_action is null or p_action not in('send','shop_receive','return_send','company_receive')or p_request_id is null or jsonb_typeof(p_imeis)is distinct from 'array'or jsonb_array_length(p_imeis)=0 or octet_length(p_imeis::text)>2000000 or length(coalesce(p_notes,''))>1000 then raise exception 'Choose an action and scan the phones first.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_imeis)x where jsonb_typeof(x)<>'string'or x#>>'{}'!~'^[0-9]{15}$')then raise exception 'Every IMEI must have exactly 15 digits.';end if;
 select array_agg(v order by v),count(*)into ids,n from jsonb_array_elements_text(p_imeis)v;
 if (select count(distinct v)from unnest(ids)v)<>n then raise exception 'Duplicate IMEI in this request. Nothing moved.';end if;
 signature:=md5(jsonb_build_array(p_action,ids,p_document_id,coalesce(p_notes,''))::text);
 perform pg_advisory_xact_lock(hashtextextended('chaman-command:'||auth.uid()::text||p_request_id::text,0));
 select *into prior from greenloop_private.chaman_commands where actor=auth.uid()and request_id=p_request_id;
 if found then if prior.signature<>signature then raise exception 'This retry changed. Reload before trying again.';end if;return prior.result;end if;
 foreach imei in array ids loop
  perform pg_advisory_xact_lock(hashtextextended('chaman-imei:'||imei,0));
  perform 1 from public.devices d where d.imei_1=imei for update;
 end loop;
 if p_action in('send','return_send')then
  insert into greenloop_private.chaman_documents(reference,direction,created_by,notes)values('CHM-'||case when p_action='send'then 'TR-'else 'RT-'end||lpad(nextval('greenloop_private.chaman_document_seq')::text,6,'0'),case when p_action='send'then 'out'else 'return'end,auth.uid(),coalesce(p_notes,''))returning *into doc;
 else
  select *into doc from greenloop_private.chaman_documents where id=p_document_id for update;
  if doc.id is null or doc.direction<>(case when p_action='shop_receive'then 'out'else 'return'end) then raise exception 'Select the correct delivery or return card first.';end if;
 end if;
 foreach imei in array ids loop
  if p_action='send'then
   if exists(select 1 from greenloop_private.chaman_lines l where l.imei=imei and l.phase<>'company')then raise exception 'IMEI % is already outside Greenloop in the Chaman process.',imei;end if;
   phone:=greenloop_private.chaman_phone(imei);
   perform 1 from public.jobs j where j.id=(phone->>'job_id')::uuid for update;
   if not exists(select 1 from public.jobs j where j.id=(phone->>'job_id')::uuid and j.current_status::text=phone->>'job_status'and j.device_id=(phone->>'device_id')::uuid)then raise exception 'IMEI % changed during dispatch. Reload and retry.',imei;end if;
   if phone->>'ownership_type'<>'company_owned'or phone->>'batch_id'is null or phone->>'job_status'not in('received','initial_qc_pending','initial_qc_completed','no_work_required','qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then raise exception 'IMEI % is not available for a shop transfer. Finish active work first.',imei;end if;
   if exists(select 1 from public.jobs j where j.device_id=(phone->>'device_id')::uuid and j.id<>(phone->>'job_id')::uuid and j.deleted_at is null and j.current_status not in('shipped','returned_to_customer','returned_to_supplier','rma_completed','scrap'))then raise exception 'IMEI % has another active job. Resolve it before dispatch.',imei;end if;
   if exists(select 1 from public.export_box_items where job_id=(phone->>'job_id')::uuid)then raise exception 'IMEI % is reserved in an export box.',imei;end if;
   update public.jobs set current_status='shop_stock'where id=(phone->>'job_id')::uuid;
   update public.devices set current_status='shop_stock'where id=(phone->>'device_id')::uuid;
   insert into greenloop_private.chaman_lines(out_document,device_id,job_id,imei,details,original_job_status,original_device_status,phase)values(doc.id,(phone->>'device_id')::uuid,(phone->>'job_id')::uuid,imei,phone,(phone->>'job_status')::public.job_status,(phone->>'device_status')::public.job_status,'out_pending');
  else
   select *into line from greenloop_private.chaman_lines l where l.imei=imei and l.phase<>'company'for update;
   if line.id is null then raise exception 'IMEI % is not in an active Chaman transfer.',imei;end if;
   perform 1 from public.jobs j where j.id=line.job_id for update;
   if p_action='shop_receive'then
    if line.out_document<>doc.id or line.phase<>'out_pending'then raise exception 'IMEI % is not pending on this Chaman delivery.',imei;end if;
    update greenloop_private.chaman_lines set phase='shop',shop_received_at=now(),shop_received_by=auth.uid()where id=line.id;
   elsif p_action='return_send'then
    if line.phase<>'shop'then raise exception 'IMEI % must be received at Chaman before return dispatch.',imei;end if;
    update greenloop_private.chaman_lines set phase='return_pending',return_document=doc.id where id=line.id;
   else
    if line.return_document<>doc.id or line.phase<>'return_pending'then raise exception 'IMEI % is not pending on this Greenloop return.',imei;end if;
    update greenloop_private.chaman_lines set phase='company',company_received_at=now(),company_received_by=auth.uid()where id=line.id;
    update public.jobs set current_status=line.original_job_status where id=line.job_id;
    update public.devices set current_status=line.original_device_status where id=line.device_id;
   end if;
  end if;
 end loop;
 outcome:=jsonb_build_object('document_id',doc.id,'reference',doc.reference,'quantity',n,'action',p_action);
 insert into greenloop_private.chaman_commands values(auth.uid(),p_request_id,signature,outcome,now());return outcome;
end;$$;
create or replace function greenloop_private.chaman_guard()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$begin
 if tg_op='INSERT'then perform 1 from public.devices d where d.id=new.device_id for update;if exists(select 1 from greenloop_private.chaman_lines l where l.device_id=new.device_id and l.phase<>'company')then raise exception 'This phone is in the Chaman process. Receive its return before creating another company job.';end if;return new;end if;
 if ((new.current_status is distinct from old.current_status and new.current_status<>'shop_stock')or(to_jsonb(new)->'receiving_batch_id'is distinct from to_jsonb(old)->'receiving_batch_id')or(to_jsonb(new)->'device_id'is distinct from to_jsonb(old)->'device_id')or(to_jsonb(new)->'imei_1'is distinct from to_jsonb(old)->'imei_1')or(to_jsonb(new)->'deleted_at'is distinct from to_jsonb(old)->'deleted_at'))and exists(select 1 from greenloop_private.chaman_lines l where l.phase<>'company'and case when tg_table_name='jobs'then l.job_id=old.id else l.device_id=old.id end)then raise exception 'This phone is in the Chaman process. Confirm Greenloop return receiving before moving it into company stock.';end if;return new;
end;$$;
drop trigger if exists chaman_stock_guard on public.jobs;create trigger chaman_stock_guard before insert or update of current_status,receiving_batch_id,device_id,deleted_at on public.jobs for each row execute function greenloop_private.chaman_guard();
drop trigger if exists chaman_stock_guard on public.export_box_items;create trigger chaman_stock_guard before insert on public.export_box_items for each row execute function greenloop_private.chaman_guard();
drop trigger if exists chaman_stock_guard on public.devices;create trigger chaman_stock_guard before update of current_status,imei_1,deleted_at on public.devices for each row execute function greenloop_private.chaman_guard();
create or replace function greenloop_private.chaman_read(p_view text,p_document_id uuid,p_query text,p_from date,p_to date,p_offset integer,p_download boolean,p_expected_snapshot text,p_imeis jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source jsonb;chosen jsonb;token text;totals jsonb;doc jsonb;begin
 perform greenloop_private.chaman_access(false);
 if p_view is null or p_view not in('out','return','balance','history','detail','preview')or p_offset is null or p_offset<0 or length(coalesce(p_query,''))>160 or p_download is null or p_from>p_to then raise exception 'Choose valid Chaman filters and page.';end if;
 if p_download then perform greenloop_private.pf_cap('chaman_shop','download');end if;
 select jsonb_build_object('out_pending',count(*)filter(where phase='out_pending'),'shop',count(*)filter(where phase='shop'),'return_pending',count(*)filter(where phase='return_pending'),'outside_greenloop',count(*)filter(where phase<>'company'))into totals from greenloop_private.chaman_lines;
 if p_view='preview'then
  if jsonb_typeof(p_imeis)is distinct from 'array'or jsonb_array_length(p_imeis)=0 then raise exception 'Scan IMEIs to preview.';end if;
  select coalesce(jsonb_agg(greenloop_private.chaman_phone(v)order by n),'[]')into source from jsonb_array_elements_text(p_imeis)with ordinality a(v,n);
 elsif p_view in('balance','detail')then
  if p_view='detail'then select to_jsonb(d)into doc from greenloop_private.chaman_documents d where id=p_document_id;if doc is null then raise exception 'Transfer card not found.';end if;end if;
  select coalesce(jsonb_agg(l.details||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then l.details->'supplier_name'else 'null'::jsonb end,'line_id',l.id,'imei',l.imei,'phase',l.phase,'shop_received_at',l.shop_received_at,'company_received_at',l.company_received_at,'reference',d.reference,'return_reference',rd.reference,'sent_at',case when p_view='detail'and doc->>'direction'='return'then rd.created_at else d.created_at end)order by d.created_at desc,l.imei,l.id),'[]')into source
  from greenloop_private.chaman_lines l join greenloop_private.chaman_documents d on d.id=l.out_document left join greenloop_private.chaman_documents rd on rd.id=l.return_document
  where (p_view='balance'and l.phase='shop')or(p_view='detail'and(l.out_document=p_document_id or l.return_document=p_document_id));
 else
  select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('sent',x.sent,'received',x.received,'pending',x.sent-x.received,'status',case when x.received=0 then 'Pending Receipt'when x.received<x.sent then 'Partially Received'else 'Received'end)order by d.created_at desc,d.id),'[]')into source
  from greenloop_private.chaman_documents d cross join lateral(select count(*)sent,count(*)filter(where case when d.direction='out'then l.shop_received_at is not null else l.company_received_at is not null end)received from greenloop_private.chaman_lines l where case when d.direction='out'then l.out_document=d.id else l.return_document=d.id end)x
  where(p_view='history'or d.direction=p_view);
 end if;
 select coalesce(jsonb_agg(r order by n),'[]')into chosen from jsonb_array_elements(source)with ordinality a(r,n)where
 (nullif(btrim(p_query),'')is null or lower(r::text)like '%'||lower(btrim(p_query))||'%')and(p_from is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz>=p_from::timestamp at time zone 'Asia/Dubai')and(p_to is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz<(p_to+1)::timestamp at time zone 'Asia/Dubai');
 token:=md5(chosen::text);if p_download and p_expected_snapshot is not null and token<>p_expected_snapshot then raise exception 'Chaman stock changed. Refresh before downloading.';end if;
 return jsonb_build_object('rows',case when p_download or p_view='preview'then chosen else coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(chosen)with ordinality a(r,n)where n>p_offset and n<=p_offset+50),'[]')end,'total',jsonb_array_length(chosen),'totals',totals,'snapshot',token,'document',doc,'generated_at',statement_timestamp());
end;$$;
-- New page starts with Admin-only grants. Every RPC also checks the admin role.
do $$declare u record;begin
 for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
end;$$;
insert into greenloop_private.page_capability_catalog(page_key,capabilities)values('chaman_shop','[{"key":"view","label":"View Chaman Shop","write":false},{"key":"search","label":"Search and filters","write":false},{"key":"entry","label":"Dispatch and confirm receiving","write":true},{"key":"download","label":"PDF and Excel","write":false}]')on conflict(page_key)do update set capabilities=excluded.capabilities;
do $$declare rule text;prior_hash text;begin
 select pg_get_constraintdef(oid)into rule from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check';
 select md5(pg_get_constraintdef(oid)||convalidated::text)into prior_hash from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check';
 if rule is not null and strpos(rule,'chaman_shop')=0 then
  alter table public.user_page_permissions drop constraint user_page_permissions_page_key_check;
  execute 'alter table public.user_page_permissions add constraint user_page_permissions_page_key_check CHECK ('||substr(rule,7)||' OR page_key=''chaman_shop'')';
  update greenloop_private.tv_damage_access_installation set definition_hash=(select md5(pg_get_constraintdef(oid)||convalidated::text)from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check')where object_kind='constraint'and object_identity='user_page_permissions_page_key_check'and definition_hash=prior_hash;
 end if;
end;$$;
insert into public.user_page_permissions(user_id,page_key,access_level)select distinct ur.user_id,'chaman_shop','edit'from public.user_roles ur join public.roles r on r.id=ur.role_id where r.role_key::text in('owner','super_admin')on conflict(user_id,page_key)do update set access_level='edit';
update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{chaman_shop}',case when exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'))then '["view","search","entry","download"]'::jsonb else '[]'::jsonb end);
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create or replace function public.chaman_shop_move_v1(p_action text,p_imeis jsonb,p_document_id uuid default null,p_notes text default '',p_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_move(p_action,p_imeis,p_document_id,p_notes,p_request_id);end;$$;
create or replace function public.get_chaman_shop_v1(p_view text default 'history',p_document_id uuid default null,p_query text default '',p_from date default null,p_to date default null,p_offset integer default 0,p_download boolean default false,p_expected_snapshot text default null,p_imeis jsonb default '[]')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_read(p_view,p_document_id,p_query,p_from,p_to,p_offset,p_download,p_expected_snapshot,p_imeis);end;$$;
revoke all on function public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid),public.get_chaman_shop_v1(text,uuid,text,date,date,integer,boolean,text,jsonb)from public,anon;
grant execute on function public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid),public.get_chaman_shop_v1(text,uuid,text,date,date,integer,boolean,text,jsonb)to authenticated;
revoke all on function greenloop_private.chaman_access(boolean),greenloop_private.chaman_phone(text),greenloop_private.chaman_move(text,jsonb,uuid,text,uuid),greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb),greenloop_private.chaman_guard()from public,anon,authenticated;
insert into greenloop_private.capability_rpc_rules values('chaman_shop_move_v1','{"page":"chaman_shop","capability":"entry"}'),('get_chaman_shop_v1','{"page":"chaman_shop","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
insert into greenloop_private.office_routines values
('public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid)','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)',md5(pg_get_functiondef('greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)'::regprocedure)),md5(pg_get_functiondef('public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid)'::regprocedure))),
('public.get_chaman_shop_v1(text,uuid,text,date,date,integer,boolean,text,jsonb)','greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)',md5(pg_get_functiondef('greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)'::regprocedure)),md5(pg_get_functiondef('public.get_chaman_shop_v1(text,uuid,text,date,date,integer,boolean,text,jsonb)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;

-- Keep historical receipt quantities while excluding off-site phones from company availability.
do $$declare sig text;old text;updated text;reviews jsonb:='[]';t record;r record;c record;begin
 foreach sig in array array['greenloop_private.sc_receipts()','greenloop_private.accounts_supplier_rows()','greenloop_private.aid_rows(jsonb)','greenloop_private.aid_report(jsonb,integer,integer,text,text,boolean,text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)']loop
  old:=pg_get_functiondef(sig::regprocedure);updated:=old;
  if sig like '%sc_receipts%'then
   if strpos(old,'chaman_lines')=0 then updated:=replace(old,'(b.planned_quantity-x.done+x.replacement)::bigint','(b.planned_quantity-x.done+x.replacement-(select count(*)from greenloop_private.chaman_lines c where c.phase<>''company''and (c.details->>''batch_id'')::uuid=any(x.ids)))::bigint');if updated=old then raise exception 'Receipt balance definition changed. Review before installing.';end if;end if;
  elsif sig like '%accounts_supplier_rows%'and strpos(old,'then ''offsite''')=0 then updated:=replace(old,'case when j.current_status::text=''returned_to_supplier''','case when j.current_status::text=''shop_stock''and exists(select 1 from greenloop_private.chaman_lines cl where cl.job_id=j.id and cl.phase<>''company'')then ''offsite'' when j.current_status::text=''returned_to_supplier''');
  elsif sig like '%aid_rows%'and strpos(old,'then ''chaman''')=0 then
   updated:=replace(old,'select r||jsonb_build_object(','select r||jsonb_build_object(''category'',case when r->>''current_status''=''shop_stock''and exists(select 1 from greenloop_private.chaman_lines cl where cl.job_id=nullif(r->>''job_id'','''')::uuid and cl.phase<>''company'')then ''chaman''else r->>''category''end,''stage'',case when r->>''current_status''=''shop_stock''and exists(select 1 from greenloop_private.chaman_lines cl where cl.job_id=nullif(r->>''job_id'','''')::uuid and cl.phase<>''company'')then ''Chaman Shop / transit''else r->>''stage''end,');
   updated:=replace(updated,'when exported then ''Exported''','when current_status=''shop_stock''then ''Chaman Shop / transit''when exported then ''Exported''');
  elsif sig not like '%aid_rows%'and sig not like '%accounts_supplier_rows%'then
   updated:=replace(updated,'not in(''returned'',''exported'',''ready'')','not in(''returned'',''exported'',''ready'',''chaman'')');
   updated:=replace(updated,'not in(''returned'',''exported'')','not in(''returned'',''exported'',''chaman'')');
  end if;
  if updated<>old then reviews:=reviews||jsonb_build_array(jsonb_build_object('identity',sig,'before_hash',md5(old)));execute updated;end if;
 end loop;
 if strpos(pg_get_functiondef('greenloop_private.accounts_supplier_rows()'::regprocedure),'then ''offsite''')=0 or strpos(pg_get_functiondef('greenloop_private.aid_rows(jsonb)'::regprocedure),'then ''chaman''')=0 then raise exception 'Stock report definitions changed. Nothing installed.';end if;
-- Supplier progress shows off-site stock separately from pending company work.
 select implementation into sig from greenloop_private.office_routines where to_regprocedure(identity)='public.get_supplier_progress_v2(date,date)'::regprocedure;
 if sig is not null then
  old:=pg_get_functiondef(sig::regprocedure);updated:=old;
  if strpos(old,'chaman_quantity')=0 then
   updated:=replace(updated,'when p.status in(''received''','when p.status=''shop_stock''and exists(select 1 from greenloop_private.chaman_lines cl where cl.job_id=p.job_id and cl.phase<>''company'')then ''chaman''when p.status in(''received''');
   updated:=replace(updated,'::integer other_quantity,false receipt_balance','::integer other_quantity,count(*)filter(where stage=''chaman'')::integer chaman_quantity,false receipt_balance');
   updated:=replace(updated,'returned,reserved,0,true','returned,reserved,0,0,true');
   if strpos(updated,'chaman_quantity')=0 then raise exception 'Supplier progress definition changed. Review before installing.';end if;
   reviews:=reviews||jsonb_build_array(jsonb_build_object('identity',sig,'before_hash',md5(old)));execute updated;
  end if;
 end if;
-- Update only seals whose existing hash matches the reviewed before-definition.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'
  and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   for r in select *from jsonb_to_recordset(reviews)as reviewed(identity text,before_hash text) loop execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using r.identity,r.before_hash;end loop;
  end loop;
 end loop;
 for r in select *from jsonb_to_recordset(reviews)as reviewed(identity text,before_hash text) loop
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 end loop;
end;$$;
create table if not exists greenloop_private.chaman_installation(identity text primary key,hash text not null);alter table greenloop_private.chaman_installation enable row level security;revoke all on greenloop_private.chaman_installation from public,anon,authenticated;
create or replace function public.get_chaman_shop_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.chaman_installation)
 and not has_table_privilege('authenticated','greenloop_private.chaman_lines','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.chaman_lines','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)','EXECUTE')
 and(select count(*)=3 from pg_trigger where tgname='chaman_stock_guard'and tgrelid=any(array['public.jobs'::regclass,'public.devices'::regclass,'public.export_box_items'::regclass])and tgfoid='greenloop_private.chaman_guard()'::regprocedure and tgenabled='O')
 then '20261112-chaman-shop-1'end;$$;
revoke all on function public.get_chaman_shop_version()from public;grant execute on function public.get_chaman_shop_version()to anon,authenticated;
insert into greenloop_private.chaman_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.chaman_access(boolean)','greenloop_private.chaman_phone(text)','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)','greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)','greenloop_private.chaman_guard()','public.chaman_shop_move_v1(text,jsonb,uuid,text,uuid)','public.get_chaman_shop_v1(text,uuid,text,date,date,integer,boolean,text,jsonb)','public.get_chaman_shop_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_chaman_shop_version()is distinct from '20261112-chaman-shop-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'then raise exception 'Chaman Shop verification failed: component %, capabilities %.',public.get_chaman_shop_version(),public.get_page_capabilities_version();end if;end;$$;
notify pgrst,'reload schema';

$chaman_ddl$;END;$chaman_install$;
select public.get_chaman_shop_version()as installed_chaman_shop_version;
