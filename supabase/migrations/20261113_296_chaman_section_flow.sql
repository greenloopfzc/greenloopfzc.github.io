-- Chaman Shop: three-card sections, scanner entries and complete stock/IMEI history.
DO $flow_install$ BEGIN EXECUTE $ddl$
create table if not exists greenloop_private.chaman_events(id uuid primary key default gen_random_uuid(),event_order bigint generated always as identity,source_key text not null unique,line_id uuid not null references greenloop_private.chaman_lines(id),device_id uuid not null references public.devices(id),job_id uuid not null references public.jobs(id),document_id uuid references greenloop_private.chaman_documents(id),action text not null,occurred_at timestamptz not null,actor uuid references auth.users(id),details jsonb not null,reason text);
create index if not exists chaman_events_device on greenloop_private.chaman_events(device_id,occurred_at,event_order);
alter table greenloop_private.chaman_events enable row level security;revoke all on greenloop_private.chaman_events from public,anon,authenticated;
create table if not exists greenloop_private.chaman_flow_installation(identity text primary key,hash text not null);revoke all on greenloop_private.chaman_flow_installation from public,anon,authenticated;
create or replace function greenloop_private.chaman_counts(p_ids uuid[] default null,p_model text default null,p_storage text default null)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('sent',count(*),'shop_received',count(*)filter(where l.shop_received_at is not null),'return_sent',count(*)filter(where l.return_document is not null),'return_received',count(*)filter(where l.company_received_at is not null),'out_pending',count(*)filter(where l.phase='out_pending'),'shop',count(*)filter(where l.phase='shop'),'return_pending',count(*)filter(where l.phase='return_pending'),'outside_greenloop',count(*)filter(where l.phase<>'company'))from greenloop_private.chaman_lines l where l.voided_at is null and(p_ids is null or(l.details->>'batch_id')::uuid=any(p_ids)or exists(select 1 from greenloop_private.sc_receipts()s where s.batch_id=any(p_ids)and(l.details->>'batch_id')::uuid=any(s.descendant_ids)))and(p_model is null or l.details->>'model'=p_model)and(p_storage is null or l.details->>'storage_gb'=p_storage);
$$;
create or replace function greenloop_private.chaman_event(p_key text,p_line jsonb,p_action text,p_doc uuid,p_at timestamptz,p_actor uuid,p_reason text default null)returns void language sql security definer set search_path=pg_catalog,public as $$
 insert into greenloop_private.chaman_events(source_key,line_id,device_id,job_id,document_id,action,occurred_at,actor,details,reason)select p_key,(p_line->>'id')::uuid,(p_line->>'device_id')::uuid,(p_line->>'job_id')::uuid,p_doc,p_action,p_at,p_actor,p_line->'details',p_reason where not(p_key like 'backfill:%'and exists(select 1 from greenloop_private.chaman_events e where e.line_id=(p_line->>'id')::uuid and e.action=p_action and e.document_id is not distinct from p_doc and e.source_key like 'live:%'))on conflict(source_key)do nothing;
$$;
create or replace function greenloop_private.chaman_event_trigger()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$declare action text;doc uuid;begin
 if tg_op='INSERT'then action:='send';doc:=new.out_document;
 elsif new.voided_at is distinct from old.voided_at and new.voided_at is not null then action:='transfer_removed';doc:=new.out_document;
 elsif new.phase='shop'and old.phase='out_pending'then action:='shop_receive';doc:=new.out_document;
 elsif new.phase='return_pending'and old.phase='shop'then action:='return_send';doc:=new.return_document;
 elsif new.phase='company'and old.phase='return_pending'then action:='company_receive';doc:=new.return_document;
 elsif new.phase='return_pending'and old.phase='company'then action:='company_receipt_undone';doc:=new.return_document;
 elsif new.phase='out_pending'and old.phase='shop'then action:='shop_receipt_undone';doc:=new.out_document;
 elsif new.phase='shop'and old.return_document is not null and new.return_document is null then action:='return_removed';doc:=old.return_document;
 else return new;end if;
 perform greenloop_private.chaman_event('live:'||gen_random_uuid(),to_jsonb(new),action,doc,clock_timestamp(),auth.uid());return new;
end;$$;
create or replace function greenloop_private.chaman_audit_event_trigger()returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$declare l jsonb;begin
 for l in select value from jsonb_array_elements(new.before_data->'lines')loop perform greenloop_private.chaman_event('audit:'||new.id||':'||(l->>'id'),l,'admin_correction',new.document_id,new.created_at,new.actor,new.action||': '||new.reason);end loop;return new;
end;$$;
drop trigger if exists chaman_event on greenloop_private.chaman_lines;create trigger chaman_event after insert or update on greenloop_private.chaman_lines for each row execute function greenloop_private.chaman_event_trigger();
drop trigger if exists chaman_event on greenloop_private.chaman_audit;create trigger chaman_event after insert on greenloop_private.chaman_audit for each row execute function greenloop_private.chaman_audit_event_trigger();
-- Recover existing trip and correction history without changing any stock record.
do $$declare l jsonb;d record;a record;stamp timestamptz;begin
 for l in select to_jsonb(x)from greenloop_private.chaman_lines x union select x from greenloop_private.chaman_audit aud cross join lateral jsonb_array_elements(aud.before_data->'lines')x union select x from greenloop_private.chaman_audit aud cross join lateral jsonb_array_elements(aud.after_data->'lines')x loop
  select *into d from greenloop_private.chaman_documents where id=(l->>'out_document')::uuid;
  perform greenloop_private.chaman_event('backfill:send:'||(l->>'id'),l,'send',d.id,d.created_at,d.created_by);
  if l->>'shop_received_at'is not null then perform greenloop_private.chaman_event('backfill:shop:'||(l->>'id')||':'||(l->>'shop_received_at'),l,'shop_receive',d.id,(l->>'shop_received_at')::timestamptz,(l->>'shop_received_by')::uuid);end if;
  if l->>'return_document'is not null then
   select *into d from greenloop_private.chaman_documents where id=(l->>'return_document')::uuid;
   perform greenloop_private.chaman_event('backfill:return:'||(l->>'id')||':'||d.id,l,'return_send',d.id,d.created_at,d.created_by);
   if l->>'company_received_at'is not null then perform greenloop_private.chaman_event('backfill:company:'||(l->>'id')||':'||d.id||':'||(l->>'company_received_at'),l,'company_receive',d.id,(l->>'company_received_at')::timestamptz,(l->>'company_received_by')::uuid);end if;
  end if;
 end loop;
 for a in select *from greenloop_private.chaman_audit loop for l in select value from jsonb_array_elements(a.before_data->'lines')loop perform greenloop_private.chaman_event('audit:'||a.id||':'||(l->>'id'),l,'admin_correction',a.document_id,a.created_at,a.actor,a.action||': '||a.reason);end loop;end loop;
end;$$;
create or replace function greenloop_private.chaman_preview(p_action text,p_imeis jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare side text;v text;phone jsonb;l greenloop_private.chaman_lines%rowtype;doc uuid;rows jsonb:='[]';begin
 perform greenloop_private.chaman_access(true);side:=greenloop_private.chaman_side();
 if p_action is null or p_action not in('send','shop_receive','return_send','company_receive')or(side='shop'and p_action not in('shop_receive','return_send'))or(side='greenloop'and p_action not in('send','company_receive'))then raise exception 'This entry belongs to the other section.'using errcode='42501';end if;
 if jsonb_typeof(p_imeis)is distinct from 'array'or jsonb_array_length(p_imeis)=0 or octet_length(p_imeis::text)>2000000 then raise exception 'Scan or paste IMEIs first.';end if;
 if exists(select 1 from jsonb_array_elements(p_imeis)x where jsonb_typeof(x)<>'string'or x#>>'{}'!~'^[0-9]{15}$')or(select count(distinct x)from jsonb_array_elements_text(p_imeis)x)<>jsonb_array_length(p_imeis)then raise exception 'Use unique, exact 15-digit IMEIs.';end if;
 for v in select value from jsonb_array_elements_text(p_imeis)loop
  if p_action='send'then
   phone:=greenloop_private.chaman_phone(v);
   if phone->>'ownership_type'<>'company_owned'or phone->>'batch_id'is null or phone->>'job_status'not in('received','initial_qc_pending','initial_qc_completed','parts_pending','laboratory_pending','glass_pending','frame_pending','final_qc_pending','qc_failed','no_work_required','qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')or exists(select 1 from greenloop_private.chaman_lines x where x.device_id=(phone->>'device_id')::uuid and x.phase<>'company')then raise exception 'IMEI % is not available for transfer. Finish active work or resolve its existing transfer first.',v;end if;
   phone:=phone||jsonb_build_object('phase','company');
  else
   select *into l from greenloop_private.chaman_lines x where x.imei=v and x.voided_at is null and x.phase=case p_action when 'shop_receive'then 'out_pending'when 'return_send'then 'shop'else 'return_pending'end;
   if l.id is null then raise exception 'IMEI % is not pending for this entry.',v;end if;
   doc:=case when p_action='company_receive'then l.return_document else l.out_document end;
   phone:=l.details||jsonb_build_object('line_id',l.id,'imei',l.imei,'phase',l.phase,'document_id',doc,'reference',(select reference from greenloop_private.chaman_documents where id=doc),'shop_received_at',l.shop_received_at,'company_received_at',l.company_received_at);
  end if;
  phone:=phone||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then phone->'supplier_name'else 'null'::jsonb end,'stage_at_dispatch',phone->'job_status');rows:=rows||jsonb_build_array(phone);
 end loop;return jsonb_build_object('rows',rows,'total',jsonb_array_length(rows),'snapshot',md5(jsonb_build_array(p_action,rows)::text));
end;$$;
create or replace function greenloop_private.chaman_entry(p_action text,p_imeis jsonb,p_notes text,p_expected_snapshot text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare signature text;prior record;review jsonb;r record;outcome jsonb;docs jsonb:='[]';v text;begin
 perform greenloop_private.chaman_access(true);
 if p_request_id is null or length(coalesce(p_notes,''))>1000 then raise exception 'Valid request and notes required.';end if;
 signature:=md5(jsonb_build_array('entry_v2',p_action,p_imeis,coalesce(p_notes,''),p_expected_snapshot)::text);
 perform pg_advisory_xact_lock(hashtextextended('chaman-command:'||auth.uid()::text||p_request_id::text,0));select *into prior from greenloop_private.chaman_commands where actor=auth.uid()and request_id=p_request_id;
 if found then if signature<>prior.signature then raise exception 'This retry changed. Reload first.';end if;return prior.result;end if;
 -- Validate before locking, then review again under the same device/job locks used for dispatch.
 review:=greenloop_private.chaman_preview(p_action,p_imeis);
 for v in select value from jsonb_array_elements_text(p_imeis)order by value loop
  perform pg_advisory_xact_lock(hashtextextended('chaman-imei:'||v,0));perform 1 from public.devices d where d.imei_1=v for update;
 end loop;
 perform 1 from public.jobs j where j.id in(select (x->>'job_id')::uuid from jsonb_array_elements(review->'rows')x)order by j.id for update;
 review:=greenloop_private.chaman_preview(p_action,p_imeis);
 if p_expected_snapshot is null or p_expected_snapshot<>review->>'snapshot'then raise exception 'Phone details changed. Review the loaded lines again before confirming.';end if;
 if p_action in('send','return_send')then
  outcome:=greenloop_private.chaman_move(p_action,p_imeis,null,p_notes,md5('entry-child:'||p_request_id)::uuid);docs:=jsonb_build_array(outcome);
 else
  for r in select (x->>'document_id')::uuid id,jsonb_agg(x->>'imei'order by x->>'imei')imeis from jsonb_array_elements(review->'rows')x group by (x->>'document_id')::uuid order by 1 loop
   outcome:=greenloop_private.chaman_move(p_action,r.imeis,r.id,'',md5('entry-child:'||p_request_id||':'||r.id)::uuid);docs:=docs||jsonb_build_array(outcome);
  end loop;
 end if;
 outcome:=jsonb_build_object('action',p_action,'quantity',jsonb_array_length(p_imeis),'documents',docs);insert into greenloop_private.chaman_commands values(auth.uid(),p_request_id,signature,outcome,now());return outcome;
end;$$;
create or replace function greenloop_private.chaman_read_v2(p_view text,p_document_id uuid,p_query text,p_from date,p_to date,p_offset integer,p_download boolean,p_expected_snapshot text,p_action text,p_imeis jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare side text;rows jsonb;chosen jsonb;doc jsonb;token text;totals jsonb;begin
 perform greenloop_private.chaman_access(false);side:=greenloop_private.chaman_side();totals:=greenloop_private.chaman_counts();
 if p_view is null or p_view not in('home','preview','out','return','balance','detail','history')or p_offset is null or p_offset<0 or p_download is null or p_from>p_to or length(coalesce(p_query,''))>160 then raise exception 'Choose valid Chaman filters.';end if;
 if p_download then perform greenloop_private.pf_cap('chaman_shop','download');end if;
 if p_view='preview'then return greenloop_private.chaman_preview(p_action,p_imeis);end if;
 if p_view='home'then rows:='[]';
 elsif p_view in('balance','detail')then
  if p_view='detail'then select to_jsonb(d)into doc from greenloop_private.chaman_documents d where d.id=p_document_id and d.deleted_at is null;if doc is null then raise exception 'Transfer not found.';end if;end if;
  select coalesce(jsonb_agg(l.details||jsonb_build_object('supplier_name',case when public.get_my_partner_name_access()then l.details->'supplier_name'else 'null'::jsonb end,'imei',l.imei,'line_id',l.id,'phase',l.phase,'stage_at_dispatch',l.details->'job_status','shop_received_at',l.shop_received_at,'company_received_at',l.company_received_at,'sent_at',case when doc->>'direction'='return'then rd.created_at else d.created_at end,'reference',d.reference,'return_reference',rd.reference,'receipt_status',case when p_view='balance'then case when l.phase='shop'then 'Received'else 'Pending'end when doc->>'direction'='out'then case when l.shop_received_at is not null then 'Received'else 'Pending'end else case when l.company_received_at is not null then 'Received'else 'Pending'end end)order by d.created_at desc,l.custody_order),'[]')into rows from greenloop_private.chaman_lines l join greenloop_private.chaman_documents d on d.id=l.out_document left join greenloop_private.chaman_documents rd on rd.id=l.return_document where l.voided_at is null and(p_view='balance'and l.phase<>'company'or p_view='detail'and(l.out_document=p_document_id or l.return_document=p_document_id));
 else
  select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('sent',x.sent,'received',x.received,'pending',x.sent-x.received,'status',case when x.received=0 then 'Pending'when x.received<x.sent then 'Partially Received'else 'Received'end)order by d.created_at desc,d.reference desc),'[]')into rows
  from greenloop_private.chaman_documents d cross join lateral(select count(*)sent,count(*)filter(where case when d.direction='out'then l.shop_received_at is not null else l.company_received_at is not null end)received from greenloop_private.chaman_lines l where l.voided_at is null and case when d.direction='out'then l.out_document=d.id else l.return_document=d.id end)x
  where d.deleted_at is null and(p_view='history'or d.direction=p_view)and(nullif(btrim(p_query),'')is null or lower(to_jsonb(d)::text)like '%'||lower(btrim(p_query))||'%'or exists(select 1 from greenloop_private.chaman_lines l where l.voided_at is null and(l.out_document=d.id or l.return_document=d.id)and lower((l.details-'supplier_name')::text||' '||l.imei)like '%'||lower(btrim(p_query))||'%'));
 end if;
 select coalesce(jsonb_agg(r order by n),'[]')into chosen from jsonb_array_elements(rows)with ordinality a(r,n)where(p_view not in('balance','detail')or nullif(btrim(p_query),'')is null or lower(r::text)like '%'||lower(btrim(p_query))||'%')and(p_from is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz>=p_from::timestamp at time zone 'Asia/Dubai')and(p_to is null or coalesce(r->>'created_at',r->>'sent_at')::timestamptz<(p_to+1)::timestamp at time zone 'Asia/Dubai');
 token:=md5(chosen::text);if p_download and p_expected_snapshot is not null and token<>p_expected_snapshot then raise exception 'Stock changed. Refresh before downloading.';end if;
 return jsonb_build_object('rows',case when p_download then chosen else coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(chosen)with ordinality a(r,n)where n>p_offset and n<=p_offset+50),'[]')end,'total',jsonb_array_length(chosen),'totals',totals,'snapshot',token,'document',doc,'access',jsonb_build_object('side',side),'generated_at',statement_timestamp());
end;$$;
create or replace function greenloop_private.chaman_journey(p_data jsonb,p_imei text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare extra jsonb;current_line record;stats jsonb;begin
 if p_data->>'found'is distinct from 'true'then return p_data;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id','chaman-event:'||e.id,'stage','movement','title',case e.action when 'send'then 'Greenloop → Chaman: dispatched'when 'shop_receive'then 'Chaman: stock received'when 'return_send'then 'Chaman → Greenloop: return dispatched'when 'company_receive'then 'Greenloop: return received; original stage restored'when 'admin_correction'then 'Chaman transfer corrected by Admin'else replace(e.action,'_',' ')end,'occurred_at',e.occurred_at,'actor',coalesce(u.full_name,'Recorded user'),'status',e.action,'details',jsonb_build_array(jsonb_build_object('label','Transfer reference','value',d.reference),jsonb_build_object('label','Stage at dispatch','value',replace(e.details->>'job_status','_',' ')),jsonb_build_object('label','Stock / Batch','value',(e.details->>'batch_number')||'-('||(e.details->>'receipt_quantity')||')'),jsonb_build_object('label','Supplier code','value',(e.details->>'supplier_code')||'-('||(e.details->>'receipt_quantity')||')'),jsonb_build_object('label','Reason','value',e.reason)))order by e.occurred_at,e.event_order),'[]')into extra from greenloop_private.chaman_events e left join greenloop_private.chaman_documents d on d.id=e.document_id left join public.user_profiles u on u.id=e.actor where e.device_id in(select id from public.devices where imei_1=p_data->'device'->>'imei_1');
 select l.phase,l.details->>'job_status'original_stage into current_line from greenloop_private.chaman_lines l where l.device_id in(select id from public.devices where imei_1=p_data->'device'->>'imei_1')and l.phase<>'company'and l.voided_at is null limit 1;
 if found then p_data:=jsonb_set(p_data,'{device}',(p_data->'device')||jsonb_build_object('current_stage',case current_line.phase when 'out_pending'then 'Chaman Shop — awaiting receipt'when 'shop'then 'Chaman Shop — received'else 'Chaman return — awaiting Greenloop receipt'end));end if;
 select jsonb_build_object('sent',count(*),'returned',count(*)filter(where l.company_received_at is not null),'outside_greenloop',count(*)filter(where l.phase<>'company'))into stats from greenloop_private.chaman_lines l where l.imei=p_data->'device'->>'imei_1'and l.voided_at is null;
 return jsonb_set(p_data,'{rows}',coalesce(p_data->'rows','[]')||extra)||jsonb_build_object('chaman_summary',stats);
end;$$;
create or replace function greenloop_private.chaman_progress(p_data jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r jsonb;counts jsonb;rows jsonb:='[]';begin
 for r in select value from jsonb_array_elements(p_data->'rows')loop
  counts:=greenloop_private.chaman_counts(case when coalesce((r->>'receipt_balance')::boolean,false)then array[]::uuid[]else array[(r->>'batch_id')::uuid]end,r->>'model',r->>'storage_gb');rows:=rows||jsonb_build_array(r||jsonb_build_object('chaman_sent',counts->'sent','chaman_return_received',counts->'return_received','chaman_shop',counts->'shop','chaman_out_pending',counts->'out_pending','chaman_return_pending',counts->'return_pending'));
 end loop;return jsonb_set(p_data,'{rows}',rows);
end;$$;
create or replace function greenloop_private.chaman_accounts(p_data jsonb,p_ids uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare r jsonb;rows jsonb:='[]';phase text;begin
 for r in select value from jsonb_array_elements(p_data->'rows')loop
  phase:=null;select l.phase into phase from greenloop_private.chaman_lines l where l.job_id::text=r->>'job_id'and l.phase<>'company'and l.voided_at is null limit 1;
  if phase is not null then r:=r||jsonb_build_object('stage',case phase when 'out_pending'then 'Chaman — Pending receipt'when 'shop'then 'Chaman — Received'else 'Chaman return — Pending Greenloop receipt'end);end if;rows:=rows||jsonb_build_array(r);
 end loop;return jsonb_set(p_data,'{rows}',rows)||jsonb_build_object('chaman_summary',greenloop_private.chaman_counts(p_ids));
end;$$;
do $patch$declare reviews jsonb;sig text;old text;updated text;r record;t record;c record;begin
select jsonb_agg(jsonb_build_object('identity',s,'before_hash',md5(pg_get_functiondef(s::regprocedure))))into reviews from unnest(array['greenloop_private.chaman_side()','greenloop_private.chaman_move(text,jsonb,uuid,text,uuid)','greenloop_private.ia_read(text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)',(select implementation from greenloop_private.office_routines where to_regprocedure(identity)='public.get_supplier_progress_v2(date,date)'::regprocedure)])s;
execute $definition$create or replace function greenloop_private.chaman_side()returns text language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();if not coalesce(public.is_active_staff(),false)then raise exception 'Active account required.'using errcode='42501';end if;perform greenloop_private.pf_cap('chaman_shop','view');
 if public.has_role(array['owner','super_admin']::public.app_role_key[])then return 'admin';end if;
 if coalesce((greenloop_private.user_capabilities(auth.uid())->'chaman_shop')?'shop_operations',false)then return 'shop';end if;return 'greenloop';
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
   if phone->>'ownership_type'<>'company_owned'or phone->>'batch_id'is null or phone->>'job_status'not in('received','initial_qc_pending','initial_qc_completed','parts_pending','laboratory_pending','glass_pending','frame_pending','final_qc_pending','qc_failed','no_work_required','qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')then raise exception 'IMEI % is not available for a shop transfer. Finish active work first.',imei;end if;
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
foreach sig in array array['greenloop_private.ia_read(text)','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)',(select implementation from greenloop_private.office_routines where to_regprocedure(identity)='public.get_supplier_progress_v2(date,date)'::regprocedure)]loop
 old:=pg_get_functiondef(sig::regprocedure);updated:=old;
 if sig='greenloop_private.ia_read(text)'then
  if strpos(old,'greenloop_private.chaman_journey(')=0 then
   updated:=replace(updated,'return jsonb_set(data,''{rows}'',output)||','return greenloop_private.chaman_journey(jsonb_set(data,''{rows}'',output)||');
   updated:=replace(updated,'''20261109-imei-activity-1'');','''20261109-imei-activity-1''),p_imei);');
  end if;
  if strpos(updated,'greenloop_private.chaman_journey(')=0 then raise exception 'IMEI journey definition changed. Review before installing.';end if;
 elsif sig like '%acard_report%'then
  if strpos(old,'greenloop_private.chaman_accounts(')=0 then updated:=replace(updated,'return result;','return case when p_kind=''customer''then result else greenloop_private.chaman_accounts(result,ids)end;');end if;
  if strpos(updated,'greenloop_private.chaman_accounts(')=0 then raise exception 'Accounts definition changed. Review before installing.';end if;
 else
  if strpos(old,'greenloop_private.chaman_progress(')=0 then updated:=replace(updated,'return result;','return greenloop_private.chaman_progress(result);');end if;
  if strpos(updated,'greenloop_private.chaman_progress(')=0 then raise exception 'Supplier report definition changed. Review before installing.';end if;
 end if;if updated<>old then execute updated;end if;
end loop;
for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
  for r in select *from jsonb_to_recordset(reviews)a(identity text,before_hash text)loop execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using r.identity,r.before_hash;end loop;
 end loop;
end loop;
for r in select *from jsonb_to_recordset(reviews)a(identity text,before_hash text)loop
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
end loop;end;$patch$;
create or replace function public.get_chaman_shop_v2(p_view text default 'home',p_document_id uuid default null,p_query text default '',p_from date default null,p_to date default null,p_offset integer default 0,p_download boolean default false,p_expected_snapshot text default null,p_action text default null,p_imeis jsonb default '[]')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_read_v2(p_view,p_document_id,p_query,p_from,p_to,p_offset,p_download,p_expected_snapshot,p_action,p_imeis);end;$$;
create or replace function public.save_chaman_entry_v2(p_action text,p_imeis jsonb,p_notes text default '',p_expected_snapshot text default null,p_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.chaman_entry(p_action,p_imeis,p_notes,p_expected_snapshot,p_request_id);end;$$;
revoke all on function greenloop_private.chaman_counts(uuid[],text,text),greenloop_private.chaman_event(text,jsonb,text,uuid,timestamp with time zone,uuid,text),greenloop_private.chaman_event_trigger(),greenloop_private.chaman_audit_event_trigger(),greenloop_private.chaman_preview(text,jsonb),greenloop_private.chaman_entry(text,jsonb,text,text,uuid),greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb),greenloop_private.chaman_journey(jsonb,text),greenloop_private.chaman_progress(jsonb),greenloop_private.chaman_accounts(jsonb,uuid[])from public,anon,authenticated;
revoke all on function public.get_chaman_shop_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb),public.save_chaman_entry_v2(text,jsonb,text,text,uuid)from public,anon;grant execute on function public.get_chaman_shop_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb),public.save_chaman_entry_v2(text,jsonb,text,text,uuid)to authenticated;
insert into greenloop_private.office_routines values('public.get_chaman_shop_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)','greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)',md5(pg_get_functiondef('greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)'::regprocedure)),md5(pg_get_functiondef('public.get_chaman_shop_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.office_routines values('public.save_chaman_entry_v2(text,jsonb,text,text,uuid)','greenloop_private.chaman_entry(text,jsonb,text,text,uuid)',md5(pg_get_functiondef('greenloop_private.chaman_entry(text,jsonb,text,text,uuid)'::regprocedure)),md5(pg_get_functiondef('public.save_chaman_entry_v2(text,jsonb,text,text,uuid)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_chaman_shop_v2','{"page":"chaman_shop","capability":"view","read":true}'),('save_chaman_entry_v2','{"page":"chaman_shop","capability":"entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_catalog set capabilities=(select jsonb_agg(case when c->>'key'='shop_operations'then jsonb_set(c,'{label}','"This is the Chaman Shop login"')else c end)from jsonb_array_elements(capabilities)c where c->>'key'<>'greenloop_operations')where page_key='chaman_shop';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create or replace function public.get_chaman_shop_flow_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
select case when public.get_chaman_shop_roles_version()='20261113-chaman-workspaces-1'and public.get_accounts_summary_cards_version()='20261112-accounts-summary-cards-1'and public.get_imei_activity_journey_version()='20261109-imei-activity-1'
 and(select count(*)=13 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))))from greenloop_private.chaman_flow_installation)
 and exists(select 1 from pg_trigger where tgname='chaman_event'and tgrelid='greenloop_private.chaman_lines'::regclass and tgfoid='greenloop_private.chaman_event_trigger()'::regprocedure and tgenabled='O')
 and exists(select 1 from pg_trigger where tgname='chaman_event'and tgrelid='greenloop_private.chaman_audit'::regclass and tgfoid='greenloop_private.chaman_audit_event_trigger()'::regprocedure and tgenabled='O')
 and not has_table_privilege('authenticated','greenloop_private.chaman_events','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.chaman_entry(text,jsonb,text,text,uuid)','EXECUTE')
 then '20261113-chaman-section-flow-1'end;$$;
revoke all on function public.get_chaman_shop_flow_version()from public;grant execute on function public.get_chaman_shop_flow_version()to anon,authenticated;
insert into greenloop_private.chaman_flow_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.chaman_counts(uuid[],text,text)','greenloop_private.chaman_event(text,jsonb,text,uuid,timestamp with time zone,uuid,text)','greenloop_private.chaman_event_trigger()','greenloop_private.chaman_audit_event_trigger()','greenloop_private.chaman_preview(text,jsonb)','greenloop_private.chaman_entry(text,jsonb,text,text,uuid)','greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)','greenloop_private.chaman_journey(jsonb,text)','greenloop_private.chaman_progress(jsonb)','greenloop_private.chaman_accounts(jsonb,uuid[])','public.get_chaman_shop_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)','public.save_chaman_entry_v2(text,jsonb,text,text,uuid)','public.get_chaman_shop_flow_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_chaman_shop_flow_version()is distinct from '20261113-chaman-section-flow-1'then raise exception 'Chaman flow verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$flow_install$;
select public.get_chaman_shop_flow_version()as installed_chaman_flow_version;
