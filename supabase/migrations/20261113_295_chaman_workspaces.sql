-- Chaman Shop workspaces and audited correction. Run the entire statement.
DO $chaman_roles$ BEGIN EXECUTE $ddl$
alter table greenloop_private.chaman_documents add column if not exists deleted_at timestamptz;
alter table greenloop_private.chaman_documents add column if not exists deleted_by uuid references auth.users(id);
alter table greenloop_private.chaman_documents add column if not exists delete_reason text;
alter table greenloop_private.chaman_lines add column if not exists voided_at timestamptz;
alter table greenloop_private.chaman_lines add column if not exists voided_by uuid references auth.users(id);
-- Immutable dispatch ordering prevents reversing an older trip after another round trip.
create sequence if not exists greenloop_private.chaman_custody_seq;
alter table greenloop_private.chaman_lines add column if not exists custody_order bigint;
do $$declare r record;begin for r in select l.id from greenloop_private.chaman_lines l join greenloop_private.chaman_documents d on d.id=l.out_document where l.custody_order is null order by d.reference,l.id loop update greenloop_private.chaman_lines set custody_order=nextval('greenloop_private.chaman_custody_seq')where id=r.id;end loop;end;$$;
alter table greenloop_private.chaman_lines alter column custody_order set default nextval('greenloop_private.chaman_custody_seq');
alter table greenloop_private.chaman_lines alter column custody_order set not null;
revoke all on sequence greenloop_private.chaman_custody_seq from public,anon,authenticated;
create table if not exists greenloop_private.chaman_audit(id uuid primary key default gen_random_uuid(),event_order bigint generated always as identity,document_id uuid not null references greenloop_private.chaman_documents(id),actor uuid not null references auth.users(id),action text not null,reason text not null,created_at timestamptz not null default now(),before_data jsonb not null,after_data jsonb not null);
alter table greenloop_private.chaman_audit enable row level security;
revoke all on greenloop_private.chaman_audit from public,anon,authenticated;
create table if not exists greenloop_private.chaman_roles_installation(identity text primary key,hash text not null);
revoke all on greenloop_private.chaman_roles_installation from public,anon,authenticated;
-- Keep existing grants; only Admin receives the new correction privileges by default.
insert into greenloop_private.page_capability_catalog(page_key,capabilities)values('chaman_shop','[{"key": "view", "label": "View Chaman Shop", "write": false}, {"key": "search", "label": "Search and filters", "write": false}, {"key": "entry", "label": "Dispatch and confirm receiving", "write": true}, {"key": "download", "label": "PDF and Excel", "write": false}, {"key": "greenloop_operations", "label": "Greenloop workspace: send stock / receive returns", "write": false}, {"key": "shop_operations", "label": "Chaman workspace: receive stock / return stock", "write": false}]')on conflict(page_key)do update set capabilities=excluded.capabilities;
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key": "report_chaman_correction", "label": "Chaman Transfer Correction: view transfers and audit", "write": false}, {"key": "chaman_correction", "label": "Correct Chaman transfer details / receiving (Admin only)", "write": true}, {"key": "chaman_delete", "label": "Remove phones / delete Chaman transfers (Admin only)", "write": true}]'::jsonb where page_key='reports'and not exists(select 1 from jsonb_array_elements(capabilities)c where c->>'key'='report_chaman_correction');
update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(c.capabilities,'{reports}',(select jsonb_agg(distinct v)from jsonb_array_elements(coalesce(c.capabilities->'reports','[]')||'["report_chaman_correction","chaman_correction","chaman_delete"]')v))where exists(select 1 from public.user_roles u join public.roles r on r.id=u.role_id where u.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
do $patch$declare reviews jsonb;sig text;r record;begin
select jsonb_agg(jsonb_build_object('identity',s,'before_hash',md5(pg_get_functiondef(s::regprocedure))))into reviews from unnest(array['greenloop_private.chaman_access(boolean)','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)','greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)'])s;
execute $definition$create or replace function greenloop_private.chaman_side()returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$declare c jsonb;begin
 perform greenloop_private.require_office_network();
 if not coalesce(public.is_active_staff(),false)then raise exception 'Active account required.'using errcode='42501';end if;
 perform greenloop_private.pf_cap('chaman_shop','view');
 if public.has_role(array['owner','super_admin']::public.app_role_key[])then return 'admin';end if;
 c:=greenloop_private.user_capabilities(auth.uid())->'chaman_shop';
 if coalesce(c?'greenloop_operations',false)=coalesce(c?'shop_operations',false)then raise exception 'Ask Admin to select exactly one Chaman Shop workspace: Greenloop or Chaman.'using errcode='42501';end if;
 return case when c?'greenloop_operations'then 'greenloop'else 'shop'end;
end;$$;
create or replace function greenloop_private.chaman_access(write_action boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.chaman_side();if write_action then perform greenloop_private.pf_cap('chaman_shop','entry');end if;
end;$$;
$definition$;
execute $definition$create or replace function greenloop_private.chaman_move(p_action text,p_imeis jsonb,p_document_id uuid,p_notes text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
#variable_conflict use_variable
declare phone jsonb;imei text;line greenloop_private.chaman_lines%rowtype;doc greenloop_private.chaman_documents%rowtype;signature text;prior record;outcome jsonb;ids text[];n integer;
begin
 perform greenloop_private.chaman_access(true);
 if greenloop_private.chaman_side()='greenloop'and p_action not in('send','company_receive')or greenloop_private.chaman_side()='shop'and p_action not in('shop_receive','return_send')then raise exception 'This action belongs to the other workspace.'using errcode='42501';end if;
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
  select *into doc from greenloop_private.chaman_documents where id=p_document_id and deleted_at is null for update;
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
end;$$;$definition$;
execute $definition$create or replace function greenloop_private.chaman_read(p_view text,p_document_id uuid,p_query text,p_from date,p_to date,p_offset integer,p_download boolean,p_expected_snapshot text,p_imeis jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare source jsonb;chosen jsonb;token text;totals jsonb;doc jsonb;side text;begin
 perform greenloop_private.chaman_access(false);side:=greenloop_private.chaman_side();
 if p_view is null or p_view not in('out','return','balance','history','detail','preview')or p_offset is null or p_offset<0 or length(coalesce(p_query,''))>160 or p_download is null or p_from>p_to then raise exception 'Choose valid Chaman filters and page.';end if;
 if p_download then perform greenloop_private.pf_cap('chaman_shop','download');end if;
 select jsonb_build_object('out_pending',count(*)filter(where phase='out_pending'),'shop',count(*)filter(where phase='shop'),'return_pending',count(*)filter(where phase='return_pending'),'outside_greenloop',count(*)filter(where phase<>'company'))into totals from greenloop_private.chaman_lines where voided_at is null;
 if p_view='preview'then
  if jsonb_typeof(p_imeis)is distinct from 'array'or jsonb_array_length(p_imeis)=0 then raise exception 'Scan IMEIs to preview.';end if;
  if side='shop'then
   select coalesce(jsonb_agg(l.details||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then l.details->'supplier_name'else 'null'::jsonb end,'imei',l.imei,'phase',l.phase)order by a.n),'[]')into source from jsonb_array_elements_text(p_imeis)with ordinality a(v,n)join greenloop_private.chaman_lines l on l.imei=a.v and l.phase='shop'and l.voided_at is null;
   if jsonb_array_length(source)<>jsonb_array_length(p_imeis)then raise exception 'Only phones received at Chaman can be previewed for return.';end if;
  else
   select coalesce(jsonb_agg(greenloop_private.chaman_phone(v)order by n),'[]')into source from jsonb_array_elements_text(p_imeis)with ordinality a(v,n);
  end if;
 elsif p_view in('balance','detail')then
  if p_view='detail'then select to_jsonb(d)into doc from greenloop_private.chaman_documents d where id=p_document_id and deleted_at is null;if doc is null then raise exception 'Transfer card not found.';end if;end if;
  select coalesce(jsonb_agg(l.details||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then l.details->'supplier_name'else 'null'::jsonb end,'line_id',l.id,'imei',l.imei,'phase',l.phase,'shop_received_at',l.shop_received_at,'company_received_at',l.company_received_at,'reference',d.reference,'return_reference',rd.reference,'sent_at',case when p_view='detail'and doc->>'direction'='return'then rd.created_at else d.created_at end)order by d.created_at desc,l.imei,l.id),'[]')into source
  from greenloop_private.chaman_lines l join greenloop_private.chaman_documents d on d.id=l.out_document left join greenloop_private.chaman_documents rd on rd.id=l.return_document
  where l.voided_at is null and ((p_view='balance'and l.phase='shop')or(p_view='detail'and(l.out_document=p_document_id or l.return_document=p_document_id)));
 else
  select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('sent',x.sent,'received',x.received,'pending',x.sent-x.received,'status',case when x.received=0 then 'Pending Receipt'when x.received<x.sent then 'Partially Received'else 'Received'end)order by d.created_at desc,d.id),'[]')into source
  from greenloop_private.chaman_documents d cross join lateral(select count(*)sent,count(*)filter(where l.voided_at is null and case when d.direction='out'then l.shop_received_at is not null else l.company_received_at is not null end)received from greenloop_private.chaman_lines l where l.voided_at is null and case when d.direction='out'then l.out_document=d.id else l.return_document=d.id end)x
  where d.deleted_at is null and (p_view='history'or d.direction=p_view);
 end if;
 select coalesce(jsonb_agg(r order by n),'[]')into chosen from jsonb_array_elements(source)with ordinality a(r,n)where
 (nullif(btrim(p_query),'')is null or lower(r::text)like '%'||lower(btrim(p_query))||'%')and(p_from is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz>=p_from::timestamp at time zone 'Asia/Dubai')and(p_to is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz<(p_to+1)::timestamp at time zone 'Asia/Dubai');
 token:=md5(chosen::text);if p_download and p_expected_snapshot is not null and token<>p_expected_snapshot then raise exception 'Chaman stock changed. Refresh before downloading.';end if;
 return jsonb_build_object('rows',case when p_download or p_view='preview'then chosen else coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(chosen)with ordinality a(r,n)where n>p_offset and n<=p_offset+50),'[]')end,'total',jsonb_array_length(chosen),'totals',totals,'snapshot',token,'document',doc,'access',jsonb_build_object('side',side,'actions',case when side='admin'then '["send","company_receive","shop_receive","return_send"]'::jsonb when side='greenloop'then '["send","company_receive"]'::jsonb else '["shop_receive","return_send"]'::jsonb end),'generated_at',statement_timestamp());
end;$$;$definition$;
for r in select *from jsonb_to_recordset(reviews)a(identity text,before_hash text)loop
 update greenloop_private.chaman_installation set hash=md5(pg_get_functiondef(r.identity::regprocedure))where identity=r.identity and hash=r.before_hash;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(r.identity::regprocedure))where to_regprocedure(implementation)=r.identity::regprocedure and original_hash=r.before_hash;
end loop;end;$patch$;
-- Report access is independent from operational Chaman page access.
create or replace function greenloop_private.chaman_report_access(p_write text default null)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if not coalesce(public.is_active_staff(),false)or not coalesce(public.has_role(array['owner','super_admin']::public.app_role_key[]),false)then raise exception 'Only Admin can correct or delete Chaman transfers.'using errcode='42501';end if;
 perform greenloop_private.pf_cap('reports','view');perform greenloop_private.pf_cap('reports','report_chaman_correction');
 if p_write is not null then perform greenloop_private.pf_cap('reports',p_write);end if;
end;$$;
create or replace function greenloop_private.chaman_document_snapshot(p_id uuid)returns jsonb language sql volatile security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('document',to_jsonb(d),'lines',coalesce((select jsonb_agg(to_jsonb(l)order by l.id)from greenloop_private.chaman_lines l where l.out_document=d.id or l.return_document=d.id),'[]'))from greenloop_private.chaman_documents d where d.id=p_id;
$$;
create or replace function greenloop_private.chaman_correction_read(p_view text,p_document_id uuid,p_query text,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare rows jsonb;chosen jsonb;snap jsonb;archive jsonb;begin
 perform greenloop_private.chaman_report_access();
 if p_view not in('active','deleted','detail','audit')or p_view is null or p_offset is null or p_offset<0 or length(coalesce(p_query,''))>160 then raise exception 'Choose valid transfer filters.';end if;
 if p_view in('detail','audit')then
  snap:=greenloop_private.chaman_document_snapshot(p_document_id);if snap is null then raise exception 'Transfer not found.';end if;
 end if;
 if p_view='detail'then
  if snap->'document'->>'deleted_at'is not null then select a.before_data into archive from greenloop_private.chaman_audit a where a.document_id=p_document_id order by a.created_at desc,a.event_order desc limit 1;end if;
  select coalesce(jsonb_agg((l->'details')||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then l->'details'->'supplier_name'else 'null'::jsonb end,'line_id',l->'id','imei',l->'imei','phase',l->'phase','voided_at',l->'voided_at','shop_received_at',l->'shop_received_at','company_received_at',l->'company_received_at','sent_at',snap->'document'->'created_at')order by l->>'imei',l->>'id'),'[]')into rows from jsonb_array_elements(coalesce(archive->'lines',snap->'lines'))l;
 elsif p_view='audit'then
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'action',a.action,'reason',a.reason,'created_at',a.created_at,'actor',coalesce(u.full_name,'Admin'),'before_document',a.before_data->'document','after_document',a.after_data->'document','before',coalesce((select jsonb_agg(jsonb_build_object('imei',l->'imei','phase',l->'phase','voided_at',l->'voided_at'))from jsonb_array_elements(a.before_data->'lines')l),'[]'),'after',coalesce((select jsonb_agg(jsonb_build_object('imei',l->'imei','phase',l->'phase','voided_at',l->'voided_at'))from jsonb_array_elements(a.after_data->'lines')l),'[]'))order by a.created_at desc,a.event_order),'[]')into rows from greenloop_private.chaman_audit a left join public.user_profiles u on u.id=a.actor where a.document_id=p_document_id;
 else
  select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('sent',x.sent,'received',x.received,'pending',x.sent-x.received)order by coalesce(d.deleted_at,d.created_at)desc,d.id),'[]')into rows from greenloop_private.chaman_documents d cross join lateral(select count(*)sent,count(*)filter(where case when d.direction='out'then l.shop_received_at is not null else l.company_received_at is not null end)received from greenloop_private.chaman_lines l where l.voided_at is null and case when d.direction='out'then l.out_document=d.id else l.return_document=d.id end)x where(d.deleted_at is null)=(p_view='active');
 end if;
 select coalesce(jsonb_agg(r order by n),'[]')into chosen from jsonb_array_elements(rows)with ordinality a(r,n)where nullif(btrim(p_query),'')is null or lower(r::text)like '%'||lower(btrim(p_query))||'%';
 return jsonb_build_object('rows',coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(chosen)with ordinality a(r,n)where n>p_offset and n<=p_offset+50),'[]'),'total',jsonb_array_length(chosen),'document',snap->'document','snapshot',case when snap is not null then md5(snap::text)end);
end;$$;
create or replace function greenloop_private.chaman_correct(p_action text,p_document_id uuid,p_imeis jsonb,p_notes text,p_date date,p_reason text,p_expected_snapshot text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
#variable_conflict use_variable
declare doc greenloop_private.chaman_documents%rowtype;l greenloop_private.chaman_lines%rowtype;before_data jsonb;after_data jsonb;ids text[];v text;signature text;prior record;result jsonb;job public.jobs%rowtype;device public.devices%rowtype;n integer:=0;begin
 perform greenloop_private.chaman_report_access(case when p_action in('delete','remove')then 'chaman_delete'else 'chaman_correction'end);
 if p_action is null or p_action not in('details','undo_receive','remove','delete')or p_request_id is null or length(btrim(coalesce(p_reason,'')))<5 or length(p_reason)>2000 or length(coalesce(p_notes,''))>1000 or jsonb_typeof(p_imeis)is distinct from 'array'or octet_length(p_imeis::text)>2000000 then raise exception 'Choose an action and enter a reason of at least 5 characters.';end if;
 signature:=md5(jsonb_build_array('correction',p_action,p_document_id,p_imeis,p_notes,p_date,p_reason,p_expected_snapshot)::text);
 perform pg_advisory_xact_lock(hashtextextended('chaman-command:'||auth.uid()::text||p_request_id::text,0));
 select *into prior from greenloop_private.chaman_commands where actor=auth.uid()and request_id=p_request_id;
 if found then if prior.signature<>signature then raise exception 'This retry changed. Reload first.';end if;return prior.result;end if;
 -- Match operational lock order: sorted IMEI/device, then document. Recheck snapshot after all locks.
 for v in select distinct x.imei from greenloop_private.chaman_lines x where x.out_document=p_document_id or x.return_document=p_document_id order by x.imei loop
  perform pg_advisory_xact_lock(hashtextextended('chaman-imei:'||v,0));perform 1 from public.devices d where d.imei_1=v for update;
 end loop;
 select *into doc from greenloop_private.chaman_documents where id=p_document_id for update;
 if doc.id is null or doc.deleted_at is not null then raise exception 'This transfer is missing or already deleted. Reload.';end if;
 before_data:=greenloop_private.chaman_document_snapshot(doc.id);
 if p_expected_snapshot is null or md5(before_data::text)<>p_expected_snapshot then raise exception 'Transfer changed. Reload and review before correcting.';end if;
 if p_action='details'then
  if p_date is null or p_date<date '2000-01-01'or p_date>(now()at time zone 'Asia/Dubai')::date then raise exception 'Choose a valid transfer date.';end if;
  -- A corrected date may not put dispatch after an existing receipt, or return before shop receipt.
  if exists(select 1 from greenloop_private.chaman_lines x where x.voided_at is null and case when doc.direction='out'then x.out_document=doc.id and x.shop_received_at is not null and p_date>(x.shop_received_at at time zone 'Asia/Dubai')::date else x.return_document=doc.id and(p_date<(x.shop_received_at at time zone 'Asia/Dubai')::date or x.company_received_at is not null and p_date>(x.company_received_at at time zone 'Asia/Dubai')::date)end)then raise exception 'Dispatch date must agree with the receiving history.';end if;
  update greenloop_private.chaman_documents set notes=coalesce(p_notes,''),created_at=(p_date+time '12:00')at time zone 'Asia/Dubai'where id=doc.id;
 else
  if p_action='delete'then select array_agg(x.imei order by x.imei)into ids from greenloop_private.chaman_lines x where x.voided_at is null and case when doc.direction='out'then x.out_document=doc.id else x.return_document=doc.id end;
  else
   if jsonb_array_length(p_imeis)=0 or exists(select 1 from jsonb_array_elements(p_imeis)x where jsonb_typeof(x)<>'string'or x#>>'{}'!~'^[0-9]{15}$')then raise exception 'Scan the exact IMEIs to correct.';end if;
   select array_agg(x order by x)into ids from jsonb_array_elements_text(p_imeis)x;
   if(select count(distinct x)from unnest(ids)x)<>cardinality(ids)then raise exception 'Duplicate IMEI. Nothing changed.';end if;
  end if;
  if coalesce(cardinality(ids),0)=0 then raise exception 'No active phones to correct.';end if;
  foreach v in array ids loop
   select *into l from greenloop_private.chaman_lines x where x.imei=v and x.voided_at is null and case when doc.direction='out'then x.out_document=doc.id else x.return_document=doc.id end for update;
   if l.id is null then raise exception 'IMEI % is not on this transfer.',v;end if;
   select *into job from public.jobs j where j.id=l.job_id for update;select *into device from public.devices d where d.id=l.device_id for update;
   if doc.direction='out'then
    if l.return_document is not null or l.phase not in('out_pending','shop')then raise exception 'IMEI % has a later return. Correct that return first.',v;end if;
    if p_action='undo_receive'then
     if l.phase<>'shop'then raise exception 'IMEI % has not been received at Chaman.',v;end if;
     update greenloop_private.chaman_lines set phase='out_pending',shop_received_at=null,shop_received_by=null where id=l.id;
    else
     if job.current_status<>'shop_stock'or device.current_status<>'shop_stock'or job.deleted_at is not null or device.deleted_at is not null then raise exception 'IMEI % workflow changed. Reload before correcting.',v;end if;
     update greenloop_private.chaman_lines set phase='company',voided_at=now(),voided_by=auth.uid()where id=l.id;
     update public.jobs set current_status=l.original_job_status where id=l.job_id;update public.devices set current_status=l.original_device_status where id=l.device_id;
    end if;
   else
    if l.phase not in('return_pending','company')then raise exception 'IMEI % is no longer on this return.',v;end if;
    if l.phase='company'then
     -- Never pull a phone back out after later work, packing, deletion, another trip or another job.
     if job.current_status<>l.original_job_status or device.current_status<>l.original_device_status or job.deleted_at is not null or device.deleted_at is not null or device.imei_1 is distinct from l.imei or job.device_id is distinct from l.device_id or job.receiving_batch_id is distinct from(l.details->>'batch_id')::uuid or exists(select 1 from greenloop_private.chaman_lines x where x.device_id=l.device_id and x.id<>l.id and(x.phase<>'company'or x.custody_order>l.custody_order))or exists(select 1 from public.export_box_items where job_id=l.job_id)or exists(select 1 from public.jobs j where j.device_id=l.device_id and j.id<>l.job_id and j.deleted_at is null and j.current_status not in('shipped','returned_to_customer','returned_to_supplier','rma_completed','scrap'))then raise exception 'IMEI % has later work or another transfer. Its completed return cannot be reversed.',v;end if;
    elsif p_action='undo_receive'then raise exception 'IMEI % has not been received at Greenloop.',v;end if;
    update greenloop_private.chaman_lines set phase=case when p_action='undo_receive'then 'return_pending'else 'shop'end,company_received_at=null,company_received_by=null,return_document=case when p_action='undo_receive'then return_document else null end where id=l.id;
    update public.jobs set current_status='shop_stock'where id=l.job_id;update public.devices set current_status='shop_stock'where id=l.device_id;
   end if;n:=n+1;
  end loop;
  if p_action='delete'or not exists(select 1 from greenloop_private.chaman_lines x where x.voided_at is null and case when doc.direction='out'then x.out_document=doc.id else x.return_document=doc.id end)then update greenloop_private.chaman_documents set deleted_at=now(),deleted_by=auth.uid(),delete_reason=p_reason where id=doc.id;end if;
 end if;
 after_data:=greenloop_private.chaman_document_snapshot(doc.id);
 insert into greenloop_private.chaman_audit(document_id,actor,action,reason,before_data,after_data)values(doc.id,auth.uid(),p_action,btrim(p_reason),before_data,after_data);
 result:=jsonb_build_object('document_id',doc.id,'reference',doc.reference,'quantity',n,'action',p_action);
 insert into greenloop_private.chaman_commands values(auth.uid(),p_request_id,signature,result,now());return result;
end;$$;
create or replace function public.get_chaman_corrections_v1(p_view text default 'active',p_document_id uuid default null,p_query text default '',p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_correction_read(p_view,p_document_id,p_query,p_offset);end;$$;
create or replace function public.correct_chaman_transfer_v1(p_action text,p_document_id uuid,p_imeis jsonb,p_notes text,p_date date,p_reason text,p_expected_snapshot text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_correct(p_action,p_document_id,p_imeis,p_notes,p_date,p_reason,p_expected_snapshot,p_request_id);end;$$;
revoke all on function greenloop_private.chaman_side(),greenloop_private.chaman_report_access(text),greenloop_private.chaman_document_snapshot(uuid),greenloop_private.chaman_correction_read(text,uuid,text,integer),greenloop_private.chaman_correct(text,uuid,jsonb,text,date,text,text,uuid)from public,anon,authenticated;
revoke all on function public.get_chaman_corrections_v1(text,uuid,text,integer),public.correct_chaman_transfer_v1(text,uuid,jsonb,text,date,text,text,uuid)from public,anon;
grant execute on function public.get_chaman_corrections_v1(text,uuid,text,integer),public.correct_chaman_transfer_v1(text,uuid,jsonb,text,date,text,text,uuid)to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_chaman_corrections_v1','{"page":"reports","capability":"report_chaman_correction","read":true}'),('correct_chaman_transfer_v1','{"page":"reports","capability":"report_chaman_correction"}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.office_routines values
('public.get_chaman_corrections_v1(text,uuid,text,integer)','greenloop_private.chaman_correction_read(text,uuid,text,integer)',md5(pg_get_functiondef('greenloop_private.chaman_correction_read(text,uuid,text,integer)'::regprocedure)),md5(pg_get_functiondef('public.get_chaman_corrections_v1(text,uuid,text,integer)'::regprocedure))),
('public.correct_chaman_transfer_v1(text,uuid,jsonb,text,date,text,text,uuid)','greenloop_private.chaman_correct(text,uuid,jsonb,text,date,text,text,uuid)',md5(pg_get_functiondef('greenloop_private.chaman_correct(text,uuid,jsonb,text,date,text,text,uuid)'::regprocedure)),md5(pg_get_functiondef('public.correct_chaman_transfer_v1(text,uuid,jsonb,text,date,text,text,uuid)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create or replace function public.get_chaman_shop_roles_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_chaman_shop_version()='20261112-chaman-shop-1'and public.get_page_capabilities_version()='20261016-page-capabilities-1'
 and(select count(*)=11 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))))from greenloop_private.chaman_roles_installation)
 and not has_table_privilege('authenticated','greenloop_private.chaman_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.chaman_correct(text,uuid,jsonb,text,date,text,text,uuid)','EXECUTE')
 then '20261113-chaman-workspaces-1'end;$$;
revoke all on function public.get_chaman_shop_roles_version()from public;grant execute on function public.get_chaman_shop_roles_version()to anon,authenticated;
insert into greenloop_private.chaman_roles_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.chaman_side()','greenloop_private.chaman_report_access(text)','greenloop_private.chaman_document_snapshot(uuid)','greenloop_private.chaman_correction_read(text,uuid,text,integer)','greenloop_private.chaman_correct(text,uuid,jsonb,text,date,text,text,uuid)','greenloop_private.chaman_access(boolean)','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)','greenloop_private.chaman_read(text,uuid,text,date,date,integer,boolean,text,jsonb)','public.get_chaman_corrections_v1(text,uuid,text,integer)','public.correct_chaman_transfer_v1(text,uuid,jsonb,text,date,text,text,uuid)','public.get_chaman_shop_roles_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_chaman_shop_roles_version()is distinct from '20261113-chaman-workspaces-1'then raise exception 'Chaman workspace verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$chaman_roles$;
select public.get_chaman_shop_roles_version()as installed_chaman_workspace_version;
