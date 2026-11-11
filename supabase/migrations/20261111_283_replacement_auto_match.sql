-- Match replacement identities to pending returns; retain normal IMEI Entry/QC.
begin;
do $$begin
 if public.get_return_imei_stage_version()is distinct from '20261111-return-imei-stage-1'
 or public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'then
 raise exception 'Verify the preceding Return Stock and Replacement installations first.';end if;
end;$$;
create table if not exists greenloop_private.srma_commands(
 actor uuid not null,request_id uuid not null,command jsonb not null,response jsonb not null,created_at timestamptz not null default now(),primary key(actor,request_id));
create table if not exists greenloop_private.srma_pairs(
 new_imei text primary key check(new_imei~'^[0-9]{15}$'),return_id uuid not null unique references greenloop_private.srp_allocations(return_id),
 receipt_id uuid not null references greenloop_private.srp_receipts(id),replacement_batch_id uuid not null,
 original_imei text,model text not null,storage_gb integer not null,color text not null,created_at timestamptz not null default now());
alter table greenloop_private.srma_commands enable row level security;alter table greenloop_private.srma_pairs enable row level security;
revoke all on greenloop_private.srma_commands,greenloop_private.srma_pairs from public,anon,authenticated;
drop trigger if exists srma_immutable on greenloop_private.srma_commands;
create trigger srma_immutable before update or delete on greenloop_private.srma_commands for each row execute function greenloop_private.srp_immutable();
drop trigger if exists srma_immutable on greenloop_private.srma_pairs;
create trigger srma_immutable before update or delete on greenloop_private.srma_pairs for each row execute function greenloop_private.srp_immutable();
create or replace function greenloop_private.srma_key(v text)returns text language sql immutable set search_path=pg_catalog,public as $$
 select regexp_replace(lower(btrim(coalesce(v,''))),'[^a-z0-9]','','g');$$;
create or replace function greenloop_private.srma_model(v text)returns text language sql immutable set search_path=pg_catalog,public as $$
 select regexp_replace(greenloop_private.srma_key(v),'^(apple)?iphone','');$$;
create or replace function greenloop_private.srma_candidates(p_batch uuid)returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('return_id',r.id,'group_id',g->>'group_id','return_reference',g->>'return_reference','old_imei',r.imei_1,
 'model',coalesce(nullif(r.model,''),d.model),'storage_gb',coalesce(d.storage_gb,nullif(r.source_snapshot->>'storage_gb','')::integer),
 'color',coalesce(nullif(d.color,''),nullif(r.source_snapshot->>'color','')),'returned_at',coalesce(r.handed_over_at,r.requested_at))
 from jsonb_array_elements(public.list_active_stock_returns(null,null))g
 cross join lateral jsonb_array_elements_text(g->'return_ids')i
 join public.supplier_returns r on r.id=i.value::uuid left join public.devices d on d.id=r.device_id
 where r.batch_id=p_batch and r.archived_at is null and r.status='returned'and r.settled_at is null and r.settlement_type is null
 and not exists(select 1 from greenloop_private.srp_allocations a where a.return_id=r.id)
 order by coalesce(r.handed_over_at,r.requested_at),r.requested_at,r.id;$$;
create or replace function greenloop_private.srma_receipts()returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce((select jsonb_agg(jsonb_build_object('batch_id',b.id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,
 'received_quantity',b.planned_quantity,'supplier_id',s.id,'supplier_code',s.supplier_code,'supplier_name',case when public.get_my_partner_name_access()then s.company_name end,
 'pending',x.n)order by b.received_at desc,b.id)from public.receiving_batches b join public.suppliers s on s.id=b.supplier_id
 cross join lateral(select count(*)filter(where r.settlement_type is null and r.settled_at is null and not exists(select 1 from greenloop_private.srp_allocations a where a.return_id=r.id))n,count(*)total from public.supplier_returns r where r.batch_id=b.id and r.status='returned'and r.archived_at is null)x
 where s.deleted_at is null and s.is_active and x.total>0),'[]'::jsonb);$$;
create or replace function greenloop_private.srma_options()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.srp_access('replacement_entry');
 return jsonb_build_object('receipts',greenloop_private.srma_receipts(),
 'models',coalesce((select jsonb_agg(distinct option_value order by option_value)from public.entry_options where is_active and option_group='model'),'[]'::jsonb),
 'colors',coalesce((select jsonb_agg(distinct option_value order by option_value)from public.entry_options where is_active and option_group='color'),'[]'::jsonb));end;$$;
create or replace function greenloop_private.srma_plan(p_supplier uuid,p_batch uuid,p_phones jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;v jsonb;c jsonb;choices jsonb;rows jsonb:='[]';used uuid[]:='{}';imeis text[]:='{}';imei text;m text;col text;gb integer;why text;n integer:=0;ok boolean:=true;
begin
 perform greenloop_private.srp_access('replacement_entry');
 if jsonb_typeof(p_phones)is distinct from 'array'or jsonb_array_length(p_phones)not between 1 and 1000 then raise exception 'Add 1 to 1000 replacement phones.'using errcode='22023';end if;
 select *into b from public.receiving_batches where id=p_batch and supplier_id=p_supplier;
 if b.id is null or b.planned_quantity is null or not exists(select 1 from public.suppliers where id=p_supplier and deleted_at is null and is_active)then raise exception 'Select a supplier and its original stock.'using errcode='22023';end if;
 select coalesce(jsonb_agg(x),'[]')into choices from greenloop_private.srma_candidates(b.id)x;
 for v in select value from jsonb_array_elements(p_phones)loop
  n:=n+1;c:=null;why:=null;imei:=btrim(v->>'imei');m:=btrim(v->>'model');col:=btrim(v->>'color');gb:=null;
  if jsonb_typeof(v)is distinct from 'object'or exists(select 1 from jsonb_object_keys(v)k where k<>all(array['imei','model','storage_gb','color']))then raise exception 'Use supported replacement fields.'using errcode='22023';end if;
  if imei is null or imei!~'^[0-9]{15}$'then why:='Enter a complete 15-digit new IMEI.';
  elsif imei=any(imeis)then why:='Duplicate new IMEI in this list.';
  elsif exists(select 1 from public.devices where imei_1=imei or imei_2=imei)or exists(select 1 from public.supplier_returns where imei_1=imei and archived_at is null and status in('requested','approved','returned'))then why:='This IMEI already belongs to a saved or returned phone.';
  elsif exists(select 1 from greenloop_private.srma_pairs where new_imei=imei)then why:='This IMEI is already reserved for a replacement receipt.';
  elsif nullif(m,'')is null or length(m)>120 or nullif(col,'')is null or length(col)>120 or coalesce(v->>'storage_gb','')!~'^[0-9]{1,5}$'then why:='Enter Model, GB and Color to match a returned phone.';
  else
   gb:=(v->>'storage_gb')::integer;
   if gb not between 1 and 16384 then why:='Choose valid storage.';
   else
    select x into c from jsonb_array_elements(choices)x where not((x->>'return_id')::uuid=any(used))and greenloop_private.srma_model(x->>'model')=greenloop_private.srma_model(m)
     and (x->>'storage_gb')::integer=gb and nullif(greenloop_private.srma_key(x->>'color'),'')=greenloop_private.srma_key(col)
     order by (x->>'returned_at')::timestamptz,(x->>'return_id')::uuid limit 1;
    if c is null then why:='No unmatched returned phone in this batch has the same Model, GB and Color. Missing return details cannot be assumed.';end if;
   end if;
  end if;
  if imei is not null then imeis:=array_append(imeis,imei);end if;
  if why is null then used:=array_append(used,(c->>'return_id')::uuid);else ok:=false;end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('line',n,'imei',imei,'model',m,'storage_gb',gb,'color',col,'matched',why is null,'reason',coalesce(why,'Matched oldest pending return'),
   'return_id',c->'return_id','group_id',c->'group_id','old_imei',c->'old_imei','return_reference',c->'return_reference','batch_number',b.batch_number,'received_quantity',b.planned_quantity));
 end loop;
 return jsonb_build_object('rows',rows,'all_matched',ok,'snapshot',md5(jsonb_build_object('supplier',p_supplier,'batch',p_batch,'rows',rows)::text));
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
  receipt:=gen_random_uuid();batchno:='BATCH-'||to_char(timezone('Asia/Dubai',now()),'YYYY')||'-'||lpad(nextval('public.receiving_batch_number_sequence')::text,4,'0');
  invno:='INV-'||to_char(timezone('Asia/Dubai',now()),'YYYY')||'-'||lpad(nextval('public.stock_receipt_invoice_number_sequence')::text,6,'0');
  insert into public.receiving_batches(batch_number,invoice_number,receiving_source,notes,created_by,stock_channel_id,planned_model,planned_quantity,supplier_id)
   values(batchno,invno,channel_name,'Matched replacements for '||(g->>'return_reference')||' / '||b.batch_number,auth.uid(),channel,'Stock received',grp.qty,p_supplier)returning id into bid;
  x:=jsonb_build_object('receipt_id',receipt,'batch_id',bid,'batch_number',batchno,'invoice_number',invno,'quantity',grp.qty,'return_reference',g->>'return_reference');
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
-- Lock exact old/new pairing before the native AFTER INSERT allocator runs.
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
 if greenloop_private.srma_model(d.model)<>greenloop_private.srma_model(p.model)or d.storage_gb is distinct from p.storage_gb or greenloop_private.srma_key(d.color)<>greenloop_private.srma_key(p.color)then raise exception 'Replacement Model, GB and Color must match the reviewed pairing.'using errcode='22023';end if;
 select *into r from public.supplier_returns where id=p.return_id;
 if r.id is null or exists(select 1 from greenloop_private.srp_phone_links where return_id=p.return_id)then raise exception 'This returned phone already has a replacement or its source is unavailable.'using errcode='23514';end if;
 k:=case when r.device_id is null then 'return:'||r.id::text else 'phone:'||r.batch_id::text||':'||r.device_id::text end;
 select *into parent from greenloop_private.srp_phone_links where replacement_device_id=r.device_id and replacement_batch_id=r.batch_id;
 insert into greenloop_private.srp_phone_links(return_id,replacement_batch_id,replacement_job_id,replacement_device_id,return_record_key,root_record_key,root_batch_id)
 values(r.id,p.replacement_batch_id,new.id,d.id,k,coalesce(parent.root_record_key,k),coalesce(parent.root_batch_id,r.batch_id));
 return new;
end;$$;
drop trigger if exists zy_srma_intake on public.jobs;
create trigger zy_srma_intake before insert on public.jobs for each row execute function greenloop_private.srma_intake();
create or replace function greenloop_private.srma_report(p_filters jsonb,p_download boolean,p_expected_snapshot text,p_offset integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare data jsonb;groups jsonb;rows jsonb:='[]';g jsonb;p jsonb;ps jsonb;token text;total integer;begin
 data:=public.get_stock_replacement_data_v1(p_filters,p_download,null);groups:=data->'rows';total:=jsonb_array_length(groups);
 token:=md5((data->>'snapshot')||coalesce((select jsonb_agg(to_jsonb(x)order by x.new_imei)::text from greenloop_private.srma_pairs x join greenloop_private.srp_receipts r on r.id=x.receipt_id where r.group_id in(select(v->>'group_id')::uuid from jsonb_array_elements(groups)v)),'[]'));
 if p_expected_snapshot is not null and p_expected_snapshot is distinct from token then raise exception 'Replacement data changed. Refresh before downloading.'using errcode='40001';end if;
 for g in select value from jsonb_array_elements(groups)with ordinality t(value,n)where coalesce(p_download,false)or(n>greatest(0,coalesce(p_offset,0))and n<=greatest(0,coalesce(p_offset,0))+50)order by n loop
  ps:='[]';for p in select value from jsonb_array_elements(g->'receipts')loop
   ps:=ps||jsonb_build_array(p||jsonb_build_object('pairs',coalesce((select jsonb_agg(jsonb_build_object('old_imei',x.original_imei,'new_imei',x.new_imei,'model',x.model,'storage_gb',x.storage_gb,'color',x.color,'entered',exists(select 1 from greenloop_private.srp_phone_links l where l.return_id=x.return_id))order by x.new_imei)from greenloop_private.srma_pairs x where x.receipt_id=(p->>'receipt_id')::uuid),'[]')));
  end loop;rows:=rows||jsonb_build_array(g||jsonb_build_object('receipts',ps));
 end loop;
 return data||jsonb_build_object('rows',rows,'catalog',greenloop_private.srma_receipts(),'total',total,'offset',greatest(0,coalesce(p_offset,0)),'snapshot',token);
end;$$;
create or replace function public.get_replacement_match_options_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.srma_options();end;$$;
create or replace function public.preview_matched_replacements_v1(p_supplier uuid,p_batch uuid,p_phones jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.srma_plan(p_supplier,p_batch,p_phones);end;$$;
create or replace function public.receive_matched_replacements_v1(p_supplier uuid,p_batch uuid,p_phones jsonb,p_snapshot text,p_request uuid,p_notes text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.srma_save(p_supplier,p_batch,p_phones,p_snapshot,p_request,p_notes);end;$$;
create or replace function public.get_stock_replacement_data_v2(p_filters jsonb default '{}',p_download boolean default false,p_expected_snapshot text default null,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.srma_report(p_filters,p_download,p_expected_snapshot,p_offset);end;$$;
do $seal$declare f record;begin
 for f in select oid::regprocedure signature from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'srma_%'loop execute format('revoke all on function %s from public,anon,authenticated',f.signature);end loop;
 for f in select a,b from(values
 ('public.get_replacement_match_options_v1()','greenloop_private.srma_options()'),
 ('public.preview_matched_replacements_v1(uuid,uuid,jsonb)','greenloop_private.srma_plan(uuid,uuid,jsonb)'),
 ('public.receive_matched_replacements_v1(uuid,uuid,jsonb,text,uuid,text)','greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)'),
 ('public.get_stock_replacement_data_v2(jsonb,boolean,text,integer)','greenloop_private.srma_report(jsonb,boolean,text,integer)'))x(a,b)loop
  execute format('revoke all on function %s from public,anon,authenticated',f.a);execute format('grant execute on function %s to authenticated',f.a);
  insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)values(f.a,f.b,md5(pg_get_functiondef(to_regprocedure(f.b))),md5(pg_get_functiondef(to_regprocedure(f.a))))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$seal$;
insert into greenloop_private.capability_rpc_rules(rpc_name,rule)values
 ('get_replacement_match_options_v1','{"page":"supplier_returns","capability":"replacement_entry","read":true}'),
 ('preview_matched_replacements_v1','{"page":"supplier_returns","capability":"replacement_entry","read":true}'),
 ('receive_matched_replacements_v1','{"page":"supplier_returns","capability":"replacement_entry"}'),
 ('get_stock_replacement_data_v2','{"page":"supplier_returns","capability":"replacement_view","read":true}')
 on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.srma_installation(identity text primary key,hash text not null);
alter table greenloop_private.srma_installation enable row level security;revoke all on greenloop_private.srma_installation from public,anon,authenticated;
create or replace function public.get_replacement_auto_match_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=14 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.srma_installation)
 and not exists(select 1 from greenloop_private.srma_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'execute')or has_function_privilege('authenticated',to_regprocedure(identity),'execute')))
 and not exists(select 1 from greenloop_private.srma_installation where identity like 'public.%'and identity<>'public.get_replacement_auto_match_version()'and(has_function_privilege('anon',to_regprocedure(identity),'execute')or not has_function_privilege('authenticated',to_regprocedure(identity),'execute')))
 and(select count(*)=3 and bool_and(relrowsecurity)from pg_class where oid in('greenloop_private.srma_commands'::regclass,'greenloop_private.srma_pairs'::regclass,'greenloop_private.srma_installation'::regclass))
 and not has_table_privilege('authenticated','greenloop_private.srma_pairs','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.srma_pairs','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.srma_commands','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.srma_commands','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.srma_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.srma_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_trigger where tgrelid='public.jobs'::regclass and tgname='zy_srma_intake'and tgenabled='O'and tgfoid='greenloop_private.srma_intake()'::regprocedure)
 and(select count(*)=2 from pg_trigger where tgrelid in('greenloop_private.srma_pairs'::regclass,'greenloop_private.srma_commands'::regclass)and tgname='srma_immutable'and tgenabled='O'and tgfoid='greenloop_private.srp_immutable()'::regprocedure)
 and(select count(*)=4 and bool_and(original_hash=md5(pg_get_functiondef(to_regprocedure(implementation)))and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))from greenloop_private.office_routines where identity in('public.get_replacement_match_options_v1()','public.preview_matched_replacements_v1(uuid,uuid,jsonb)','public.receive_matched_replacements_v1(uuid,uuid,jsonb,text,uuid,text)','public.get_stock_replacement_data_v2(jsonb,boolean,text,integer)'))
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='receive_matched_replacements_v1'and rule='{"page":"supplier_returns","capability":"replacement_entry"}'::jsonb)
 then '20261111-replacement-auto-match-1'else null end;$$;
revoke all on function public.get_replacement_auto_match_version()from public;grant execute on function public.get_replacement_auto_match_version()to anon,authenticated;
insert into greenloop_private.srma_installation(identity,hash)select oid::regprocedure::text,md5(pg_get_functiondef(oid))from pg_proc where
 pronamespace='greenloop_private'::regnamespace and proname like 'srma_%'or pronamespace='public'::regnamespace and proname in('get_replacement_match_options_v1','preview_matched_replacements_v1','receive_matched_replacements_v1','get_stock_replacement_data_v2','get_replacement_auto_match_version')on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_replacement_auto_match_version()is distinct from '20261111-replacement-auto-match-1'
 or public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'
 or public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Replacement matching integrity failed. Installation rolled back.';end if;
 notify pgrst,'reload schema';end;$$;
commit;
select public.get_replacement_auto_match_version()as installed_replacement_auto_match_version;
