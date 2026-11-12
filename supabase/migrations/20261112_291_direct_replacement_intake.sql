-- Atomic replacement intake. Private ledger IDs are not business batches.
DO $gl4_install$ BEGIN EXECUTE $gl4_ddl$

do $$begin
 if public.get_replacement_original_stock_version()is distinct from '20261111-replacement-original-stock-1' or public.get_replacement_auto_match_version()is distinct from '20261111-replacement-auto-match-1' or public.get_imei_replacement_history_version()is distinct from '20261111-imei-replacement-history-1' then raise exception 'Verify Original Stock Replacement and IMEI Replacement History prerequisites first.';end if;
 if to_regprocedure('public.get_direct_replacement_intake_version()')is not null then if public.get_direct_replacement_intake_version()is distinct from '20261112-direct-replacement-intake-1' then raise exception 'Installed direct replacement definitions changed; review before reinstalling.';end if;end if;
end;$$;
create temporary table gl4_review(identity text primary key,before_hash text not null)on commit drop;
insert into gl4_review select id,md5(pg_get_functiondef(to_regprocedure(id)))from unnest(array['greenloop_private.srma_candidates(uuid)','greenloop_private.srma_plan(uuid,uuid,jsonb)','greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)','greenloop_private.srma_intake()','greenloop_private.sc_receipts()','greenloop_private.supplier_return_intake_guard()','greenloop_private.simple_stock_return_model_intake_guard()'])id;
create table if not exists greenloop_private.gl4_return_phone_details(return_id uuid primary key,capture jsonb not null);
alter table greenloop_private.gl4_return_phone_details enable row level security;revoke all on greenloop_private.gl4_return_phone_details from public,anon,authenticated;
create or replace function greenloop_private.srma_candidates(p_batch uuid)returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('return_id',r.id,'group_id',g->>'group_id','return_reference',g->>'return_reference','old_imei',r.imei_1,
 'model',coalesce(nullif(r.model,''),d.model,c.capture->>'model'),'storage_gb',coalesce(d.storage_gb,nullif(r.source_snapshot->>'storage_gb','')::integer,nullif(c.capture->>'storage_gb','')::integer),
 'color',coalesce(nullif(d.color,''),nullif(r.source_snapshot->>'color',''),c.capture->>'color'),'returned_at',coalesce(r.handed_over_at,r.requested_at))
 from jsonb_array_elements(public.list_active_stock_returns(null,null))g
 cross join lateral jsonb_array_elements_text(g->'return_ids')i
 join public.supplier_returns r on r.id=i.value::uuid left join public.devices d on d.id=r.device_id
 left join greenloop_private.gl4_return_phone_details c on c.return_id=r.id
 where r.batch_id=p_batch and r.archived_at is null and r.status='returned'and r.settled_at is null and r.settlement_type is null
 and not exists(select 1 from greenloop_private.srp_allocations a where a.return_id=r.id)
 order by coalesce(r.handed_over_at,r.requested_at),r.requested_at,r.id;$$;

create table if not exists greenloop_private.gl4_intake_permits(transaction_id bigint,backend_pid integer,job_id uuid primary key,device_id uuid,batch_id uuid,allocation_id uuid);
alter table greenloop_private.gl4_intake_permits enable row level security;
revoke all on greenloop_private.gl4_intake_permits from public,anon,authenticated;
create or replace function greenloop_private.gl4_permitted(j uuid,d uuid,b uuid)returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from greenloop_private.gl4_intake_permits t join greenloop_private.srp_receipts r on r.replacement_batch_id=t.allocation_id join greenloop_private.srma_pairs p on p.receipt_id=r.id join public.devices x on x.imei_1=p.new_imei where t.transaction_id=txid_current() and t.backend_pid=pg_backend_pid() and t.job_id=j and t.device_id=d and t.batch_id=b and r.original_batch_id=b and x.id=d);$$;
CREATE OR REPLACE FUNCTION greenloop_private.supplier_return_intake_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare b public.receiving_batches%rowtype; p public.stock_batch_plan_lines%rowtype; d public.devices%rowtype; n integer; held integer;
begin
 if tg_op='INSERT' and greenloop_private.gl4_permitted(new.id,new.device_id,new.receiving_batch_id) then return new;end if;
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
 if tg_op='INSERT' and greenloop_private.gl4_permitted(new.id,new.device_id,new.receiving_batch_id) then return new;end if;
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
CREATE OR REPLACE FUNCTION greenloop_private.sc_receipts()
 RETURNS TABLE(batch_id uuid, parent_batch_id uuid, supplier_id uuid, supplier_code text, supplier_name text, batch_number text, invoice_number text, received_at timestamp with time zone, received_quantity bigint, returned_quantity bigint, replacement_quantity bigint, balance_quantity bigint, return_pending bigint, descendant_ids uuid[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 with recursive edges as materialized(select x.original_batch_id parent,x.replacement_batch_id child,x.quantity from greenloop_private.srp_receipts x),tree as(
 select b.id root,b.id node,array[b.id]path,0::bigint replacement from public.receiving_batches b
 union all select t.root,e.child,t.path||e.child,e.quantity::bigint from tree t join edges e on e.parent=t.node where not e.child=any(t.path)
 ),ret as materialized(select batch_id,count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))filter(where status='returned')done,count(distinct coalesce(device_id::text,job_id::text,imei_1,id::text))filter(where status in('requested','approved'))pending from public.supplier_returns where archived_at is null group by batch_id),roll as(
 select t.root,sum(t.replacement)replacement,coalesce(sum(ret.done),0)done,coalesce(sum(ret.pending),0)pending,array_agg(distinct t.node)ids from tree t left join ret on ret.batch_id=t.node group by t.root)
 select b.id,(select e.parent from edges e where e.child=b.id limit 1),b.supplier_id,s.supplier_code,case when coalesce(public.get_my_partner_name_access(),false)then s.company_name end,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity::bigint,x.done::bigint,x.replacement::bigint,(b.planned_quantity-x.done+x.replacement)::bigint,x.pending::bigint,x.ids
 from public.receiving_batches b join roll x on x.root=b.id left join public.suppliers s on s.id=b.supplier_id;
$function$
;
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
  if jsonb_typeof(v)is distinct from 'object'or exists(select 1 from jsonb_object_keys(v)k where k<>all(array['imei','model','storage_gb','color','imei_2','serial_number','specification_region','battery_health','brand','platform']))then raise exception 'Use supported replacement fields.'using errcode='22023';end if;
  if imei is null or imei!~'^[0-9]{15}$'then why:='Enter a complete 15-digit new IMEI.';
  elsif imei=any(imeis)then why:='Duplicate new IMEI in this list.';
  elsif exists(select 1 from public.devices where imei_1=imei or imei_2=imei)or exists(select 1 from public.supplier_returns where imei_1=imei and archived_at is null and status in('requested','approved','returned'))then why:='This IMEI already belongs to a saved or returned phone.';
  elsif exists(select 1 from greenloop_private.gl4_return_phone_details c where imei in(c.capture->>'imei',c.capture->>'imei_2')or nullif(v->>'imei_2','')in(c.capture->>'imei',c.capture->>'imei_2')or upper(nullif(v->>'serial_number',''))=upper(nullif(c.capture->>'serial_number','')))then why:='This identity belongs to a returned phone.';
  elsif exists(select 1 from greenloop_private.srma_pairs where new_imei=imei)then why:='This IMEI is already reserved for a replacement receipt.';
  elsif nullif(v->>'imei_2','') is not null and ((v->>'imei_2')!~'^[0-9]{15}$' or v->>'imei_2'=imei or v->>'imei_2'=any(imeis)) then why:='Invalid or duplicate secondary identity.';
  elsif exists(select 1 from public.devices where imei_1=nullif(v->>'imei_2','') or imei_2=nullif(v->>'imei_2','') or upper(serial_number)=upper(nullif(btrim(v->>'serial_number'),''))) then why:='Secondary IMEI or Serial Number already belongs to a phone.';
  elsif length(coalesce(v->>'serial_number',''))>128 or length(coalesce(v->>'specification_region',''))>128 then why:='Identity details are too long.';
  elsif nullif(v->>'battery_health','') is not null and (coalesce(v->>'battery_health','')!~'^[0-9]{1,3}$' or (v->>'battery_health')::integer>100) then why:='Battery health must be between 0 and 100.';
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
  if imei is not null then imeis:=array_append(imeis,imei);if nullif(v->>'imei_2','') is not null then imeis:=array_append(imeis,v->>'imei_2');end if;end if;
  if why is null then used:=array_append(used,(c->>'return_id')::uuid);else ok:=false;end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('line',n,'imei',imei,'model',m,'storage_gb',gb,'color',col,'matched',why is null,'reason',coalesce(why,'Matched oldest pending return'),
   'return_id',c->'return_id','group_id',c->'group_id','old_imei',c->'old_imei','return_reference',c->'return_reference','batch_number',b.batch_number,'received_quantity',b.planned_quantity));
 end loop;
 return jsonb_build_object('rows',rows,'all_matched',ok,'snapshot',md5(jsonb_build_object('supplier',p_supplier,'batch',p_batch,'rows',rows,'phones',p_phones)::text));
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
 if (new.receiving_batch_id is distinct from p.replacement_batch_id and not greenloop_private.gl4_permitted(new.id,new.device_id,new.receiving_batch_id)) or d.imei_1 is distinct from p.new_imei then raise exception 'This IMEI is reserved for its matched replacement receipt. Use that receipt and IMEI 1.'using errcode='22023';end if;
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
 bid uuid;receipt uuid;batchno text;invno text;channel uuid;channel_name text;v_notes text:=nullif(btrim(p_notes),'');output jsonb:='[]';actor_name text;started boolean:=false;phone jsonb;did uuid;jid uuid;loc uuid;
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
  perform greenloop_private.lock_cable_identity_v1(x->>'imei',x->>'imei_2',x->>'serial_number');
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
  receipt:=gen_random_uuid();batchno:=b.batch_number; -- Private allocation ledger; keep original business references
  invno:=b.invoice_number;
  bid:=gen_random_uuid(); -- Audit allocation identifier only; no business receipt, batch or invoice is created.
  x:=jsonb_build_object('receipt_id',receipt,'batch_id',b.id,'original_batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'receipt_quantity',b.planned_quantity,'quantity',grp.qty,'return_reference',g->>'return_reference');
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
   select value into phone from jsonb_array_elements(p_phones) where value->>'imei'=r.v->>'imei';
   select id into loc from public.locations where location_code='RECEIVING' and is_active;
   if loc is null then raise exception 'Receiving location is not configured.';end if;
   insert into public.devices(device_number,imei_1,model,storage_gb,color,battery_health,brand,device_platform,battery_health_unavailable,current_owner_type,current_location_id,current_status,notes,created_by)
   values(null,phone->>'imei',r.v->>'model',(r.v->>'storage_gb')::integer,nullif(r.v->>'color',''),nullif(phone->>'battery_health','')::smallint,coalesce(nullif(phone->>'brand',''),'Apple'),coalesce(nullif(phone->>'platform',''),'ios'),false,'company_owned',loc,'initial_qc_pending',v_notes,auth.uid())returning id into did;
   perform greenloop_private.store_cable_identity_v1(phone->>'imei',phone->>'imei_2',phone->>'serial_number',phone->>'specification_region');
   jid:=gen_random_uuid();
   insert into greenloop_private.gl4_intake_permits values(txid_current(),pg_backend_pid(),jid,did,b.id,bid);
   insert into public.jobs(id,job_number,device_id,job_type,ownership_type,supplier_id,receiving_source,purchase_cost,received_by,receiving_batch_id,current_location_id,current_status,notes,created_by)
   values(jid,null,did,case when lower(b.receiving_source)='rma' then 'rma'::public.job_type else 'company_refurbishment'::public.job_type end,'company_owned',b.supplier_id,b.receiving_source,0,auth.uid(),b.id,loc,'initial_qc_pending',v_notes,auth.uid());
   delete from greenloop_private.gl4_intake_permits where job_id=jid;
   insert into public.device_location_history(device_id,job_id,to_location_id,movement_reason,notes,moved_by)values(did,jid,loc,'Replacement received into original stock',v_notes,auth.uid());
   insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)values(did,jid,'replacement_received','Replacement received — Initial QC',jsonb_build_object('old_imei',r.v->>'old_imei','new_imei',phone->>'imei','batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'receipt_quantity',b.planned_quantity,'return_id',r.v->>'return_id'),auth.uid());
   delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id=(r.v->>'return_id')::uuid;
  end loop;
  output:=output||jsonb_build_array(x);
 end loop;
 x:=jsonb_build_object('receipts',output,'quantity',jsonb_array_length(p_phones),'pairs',plan->'rows');
 insert into greenloop_private.srma_commands(actor,request_id,command,response)values(auth.uid(),p_request,cmd,x);
 perform greenloop_private.end_capability();started:=false;return x;
exception when others then if started then perform greenloop_private.end_capability();end if;raise;
end;$$;
revoke all on function greenloop_private.gl4_permitted(uuid,uuid,uuid)from public,anon,authenticated;

create or replace function greenloop_private.gl4_history(p_filters jsonb,p_download boolean,p_expected_snapshot text,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare data jsonb;g jsonb;r record;v jsonb;allrows jsonb:='[]';n integer:=0;token text;begin
 data:=public.get_stock_replacement_data_v1(p_filters,p_download,null);
 for g in select value from jsonb_array_elements(data->'rows')loop
 for r in select sr.*,coalesce(d.model,sr.model,cap.capture->>'model') phone_model,coalesce(d.storage_gb,nullif(sr.source_snapshot->>'storage_gb','')::integer,nullif(cap.capture->>'storage_gb','')::integer) gb,coalesce(d.color,cap.capture->>'color') phone_color,
 nd.imei_1 new_imei,nd.model new_model,nd.storage_gb new_gb,nd.color new_color,p.new_imei reserved_imei,p.model reserved_model,p.storage_gb reserved_gb,p.color reserved_color
 from jsonb_array_elements_text(g->'return_ids') ids join public.supplier_returns sr on sr.id=ids.value::uuid
 left join public.devices d on d.id=sr.device_id left join greenloop_private.gl4_return_phone_details cap on cap.return_id=sr.id left join greenloop_private.srp_phone_links l on l.return_id=sr.id left join public.devices nd on nd.id=l.replacement_device_id
 left join greenloop_private.srma_pairs p on p.return_id=sr.id order by sr.requested_at,sr.id loop
 n:=n+1;v:=g-'receipts'-'return_ids'-'imeis';
 allrows:=allrows||jsonb_build_array(v||jsonb_build_object('serial',n,'kind','returned','imei',r.imei_1,'phone_model',r.phone_model,'gb',r.gb,'color',r.phone_color,'reason',g->>'reason','linked_imei',coalesce(r.new_imei,r.reserved_imei)));
 if coalesce(r.new_imei,r.reserved_imei)is not null then
 allrows:=allrows||jsonb_build_array(v||jsonb_build_object('serial',n,'kind','replacement','imei',coalesce(r.new_imei,r.reserved_imei),'phone_model',coalesce(r.new_model,r.reserved_model),'gb',coalesce(r.new_gb,r.reserved_gb),'color',coalesce(r.new_color,r.reserved_color),'reason',case when r.new_imei is null then 'Legacy reservation — intake pending'else 'Replacement received'end,'linked_imei',r.imei_1));end if;
 end loop;end loop;
 token:=md5(allrows::text);if p_expected_snapshot is not null and p_expected_snapshot<>token then raise exception 'History changed. Refresh before downloading.'using errcode='40001';end if;
 return data||jsonb_build_object('phone_rows',coalesce((select jsonb_agg(value order by t.n)from jsonb_array_elements(allrows)with ordinality t(value,n)where p_download or(t.n>greatest(0,p_offset)and t.n<=greatest(0,p_offset)+50)),'[]'),'rows',case when p_download then data->'rows'else '[]'::jsonb end,'catalog',greenloop_private.srma_receipts(),'total',jsonb_array_length(allrows),'snapshot',token);
end;$$;
create or replace function public.get_return_replacement_history_v1(p_filters jsonb default '{}',p_download boolean default false,p_expected_snapshot text default null,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.require_office_network();return greenloop_private.gl4_history(p_filters,p_download,p_expected_snapshot,p_offset);end;$$;
revoke all on function greenloop_private.gl4_history(jsonb,boolean,text,integer)from public,anon,authenticated;
revoke all on function public.get_return_replacement_history_v1(jsonb,boolean,text,integer)from public,anon;
grant execute on function public.get_return_replacement_history_v1(jsonb,boolean,text,integer)to authenticated;
create table if not exists greenloop_private.gl4_return_capture(actor uuid not null,request_id uuid not null,details jsonb not null,created_at timestamptz not null default now(),primary key(actor,request_id));
alter table greenloop_private.gl4_return_capture enable row level security;revoke all on greenloop_private.gl4_return_capture from public,anon,authenticated;
create or replace function public.record_stock_return_with_capture_v1(p_payload jsonb,p_idempotency_key uuid,p_phone_details jsonb default '[]')returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb;x jsonb;prior jsonb;begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('supplier_returns','entry');
 if jsonb_typeof(p_phone_details)is distinct from 'array' or jsonb_array_length(p_phone_details)>1000 then raise exception 'Invalid phone capture.';end if;
 if exists(select k from jsonb_array_elements(p_phone_details)dups(value) cross join lateral unnest(array[nullif(dups.value->>'imei',''),nullif(dups.value->>'imei_2','')])k where k is not null group by k having count(*)>1)or exists(select upper(dups.value->>'serial_number')from jsonb_array_elements(p_phone_details)dups(value) where nullif(dups.value->>'serial_number','')is not null group by upper(dups.value->>'serial_number')having count(*)>1)then raise exception 'Duplicate captured phone identity.';end if;
 perform pg_advisory_xact_lock(hashtextextended('gl4-return:'||auth.uid()::text||p_idempotency_key::text,0));
 select details into prior from greenloop_private.gl4_return_capture where actor=auth.uid()and request_id=p_idempotency_key;
 if prior is not null then if prior<>p_phone_details then raise exception 'Retry capture changed. Nothing saved.';end if;return public.record_simple_stock_return(p_payload,p_idempotency_key);end if;
 for x in select value from jsonb_array_elements(p_phone_details)order by value->>'imei'loop
 if not coalesce(p_payload->'imeis' ? (x->>'imei'),false)then raise exception 'Captured phone is not in the return list.';end if;
 if length(coalesce(x->>'serial_number',''))>128 or length(coalesce(x->>'specification_region',''))>128 or length(coalesce(x->>'model',''))>120 or length(coalesce(x->>'color',''))>120 then raise exception 'Captured details are too long.';end if;
 if nullif(x->>'storage_gb','')is not null and ((x->>'storage_gb')!~'^[0-9]{1,5}$'or(x->>'storage_gb')::integer not between 1 and 16384)then raise exception 'Invalid captured storage.';end if;
 perform greenloop_private.lock_cable_identity_v1(x->>'imei',x->>'imei_2',x->>'serial_number');
 if exists(select 1 from greenloop_private.gl4_return_phone_details c where c.capture->>'imei'<>x->>'imei' and (nullif(x->>'imei_2','')in(c.capture->>'imei',c.capture->>'imei_2')or x->>'imei'=c.capture->>'imei_2' or upper(nullif(x->>'serial_number',''))=upper(c.capture->>'serial_number')))then raise exception 'Captured identity belongs to another returned phone.';end if;
 if exists(select 1 from public.devices where imei_1=x->>'imei' and deleted_at is null)then
 perform greenloop_private.store_cable_identity_v1(x->>'imei',x->>'imei_2',x->>'serial_number',x->>'specification_region');
 elsif nullif(x->>'imei_2','')is not null or nullif(x->>'serial_number','')is not null then
 if nullif(x->>'imei_2','')is not null and ((x->>'imei_2')!~'^[0-9]{15}$'or x->>'imei_2'=x->>'imei')then raise exception 'Invalid secondary identity.';end if;
 if exists(select 1 from public.devices where imei_1=x->>'imei_2' or imei_2=x->>'imei_2' or upper(serial_number)=upper(nullif(x->>'serial_number','')))then raise exception 'Captured identity belongs to another phone.';end if;
 end if;
 end loop;
 result:=public.record_simple_stock_return(p_payload,p_idempotency_key);
 for x in select value from jsonb_array_elements(p_phone_details)loop
 insert into greenloop_private.gl4_return_phone_details(return_id,capture)select r.id,x from public.supplier_returns r where r.batch_id=(p_payload->>'batch_id')::uuid and r.imei_1=x->>'imei'and r.status='returned'and r.archived_at is null on conflict do nothing;
 end loop;
 insert into greenloop_private.gl4_return_capture(actor,request_id,details)values(auth.uid(),p_idempotency_key,p_phone_details)on conflict do nothing;
 return result;
end;$$;
revoke all on function public.record_stock_return_with_capture_v1(jsonb,uuid,jsonb)from public,anon;
grant execute on function public.record_stock_return_with_capture_v1(jsonb,uuid,jsonb)to authenticated;


create or replace function public.get_stock_return_phone_history_v1(p_query text default '',p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare rows jsonb;begin
 perform greenloop_private.require_office_network();perform greenloop_private.simple_stock_return_view_access();
 if length(coalesce(p_query,''))>200 then raise exception 'Search text is too long.';end if;
 if nullif(btrim(p_query),'')is not null then perform greenloop_private.pf_cap('supplier_returns','search');end if;
 with phones as(select g-'imeis'-'return_ids'||jsonb_build_object('imei',r.imei_1,'phone_model',coalesce(d.model,r.model,cap.capture->>'model'),'gb',coalesce(d.storage_gb,nullif(r.source_snapshot->>'storage_gb','')::integer,nullif(cap.capture->>'storage_gb','')::integer),'color',coalesce(d.color,cap.capture->>'color'),'return_id',r.id) v
 from jsonb_array_elements(public.list_active_stock_returns(null,null))g cross join lateral jsonb_array_elements_text(g->'return_ids')i join public.supplier_returns r on r.id=i.value::uuid left join public.devices d on d.id=r.device_id left join greenloop_private.gl4_return_phone_details cap on cap.return_id=r.id)
 select coalesce(jsonb_agg(v order by v->>'returned_at'desc,v->>'return_id'),'[]')into rows from phones where nullif(btrim(p_query),'')is null or strpos(lower(v::text),lower(btrim(p_query)))>0;
 return jsonb_build_object('total',jsonb_array_length(rows),'rows',coalesce((select jsonb_agg(value||jsonb_build_object('serial',n)order by n)from jsonb_array_elements(rows)with ordinality t(value,n)where n>greatest(0,p_offset)and n<=greatest(0,p_offset)+50),'[]'));
end;$$;
revoke all on function public.get_stock_return_phone_history_v1(text,integer)from public,anon;grant execute on function public.get_stock_return_phone_history_v1(text,integer)to authenticated;

-- Update only integrity seals whose recorded before-definition matches exactly.
do $review$declare t record;r record;c record;begin
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'
  and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype) and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   for r in select *from gl4_review loop execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''') and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using r.identity,r.before_hash;end loop;
  end loop;
 end loop;
 for r in select *from gl4_review loop
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(r.identity)))where to_regprocedure(implementation)=to_regprocedure(r.identity)and original_hash=r.before_hash;
 end loop;
end;$review$;

-- Existing legacy links are rehomed only through the already guarded/audited repair.
do $$declare r record;begin for r in select l.replacement_job_id from greenloop_private.srp_phone_links l join public.jobs j on j.id=l.replacement_job_id where j.receiving_batch_id is distinct from l.root_batch_id and j.deleted_at is null order by l.linked_at,l.replacement_job_id loop perform greenloop_private.sro_rehome(r.replacement_job_id);end loop;end;$$;
drop trigger if exists gl4_capture_immutable on greenloop_private.gl4_return_capture;
create trigger gl4_capture_immutable before update or delete on greenloop_private.gl4_return_capture for each row execute function greenloop_private.srp_immutable();
drop trigger if exists gl4_details_immutable on greenloop_private.gl4_return_phone_details;
create trigger gl4_details_immutable before update or delete on greenloop_private.gl4_return_phone_details for each row execute function greenloop_private.srp_immutable();
create table if not exists greenloop_private.gl4_installation(identity text primary key,hash text not null);
alter table greenloop_private.gl4_installation enable row level security;revoke all on greenloop_private.gl4_installation from public,anon,authenticated;
create or replace function public.get_direct_replacement_intake_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
select case when (select count(*)=14 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.gl4_installation)
and not has_table_privilege('authenticated','greenloop_private.gl4_intake_permits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and not has_table_privilege('authenticated','greenloop_private.gl4_return_capture','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and not has_function_privilege('authenticated','greenloop_private.gl4_permitted(uuid,uuid,uuid)','execute')
then '20261112-direct-replacement-intake-1'end;$$;
revoke all on function public.get_direct_replacement_intake_version()from public;grant execute on function public.get_direct_replacement_intake_version()to anon,authenticated;
insert into greenloop_private.gl4_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from gl4_review
union all select id,md5(pg_get_functiondef(to_regprocedure(id)))from unnest(array['greenloop_private.gl4_permitted(uuid,uuid,uuid)','greenloop_private.gl4_history(jsonb,boolean,text,integer)','public.get_return_replacement_history_v1(jsonb,boolean,text,integer)','public.record_stock_return_with_capture_v1(jsonb,uuid,jsonb)','public.get_stock_return_phone_history_v1(text,integer)','public.get_direct_replacement_intake_version()','greenloop_private.sro_rehome(uuid)'])id on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_direct_replacement_intake_version()is distinct from '20261112-direct-replacement-intake-1' then raise exception 'Direct replacement verification failed; nothing installed.';end if;end;$$;
notify pgrst,'reload schema';

$gl4_ddl$; END $gl4_install$;
select public.get_direct_replacement_intake_version()installed_direct_replacement_intake_version;
