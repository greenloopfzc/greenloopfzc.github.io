-- Linked supplier replacements. Existing returns and receiving functions stay intact.
begin;
do $$begin
 if public.get_accounts_imei_data_version()is distinct from '20261104-accounts-imei-data-1'then raise exception 'Verify Accounts IMEI DATA first.';end if;
 if to_regprocedure('public.get_stock_replacement_version()')is not null then
  if public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'then raise exception 'Existing Stock Replacement installation requires review.';end if;
 end if;
end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='supplier_returns'and capabilities @> '[{"key":"replacement_view"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop
   insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;
  end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"replacement_view","label":"View Stock Replacement","write":false},{"key":"replacement_entry","label":"Receive Stock Replacement","write":true},{"key":"replacement_download","label":"Replacement PDF / Excel","write":false}]'where page_key='supplier_returns';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{supplier_returns}',(capabilities->'supplier_returns')||'["replacement_view","replacement_entry","replacement_download"]')
   where capabilities->'supplier_returns'?'view'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';

-- No foreign keys to operational records: authorized deletion preserves this audit.
create table if not exists greenloop_private.srp_receipts(
 id uuid primary key default gen_random_uuid(),actor_id uuid not null,idempotency_key uuid not null,
 command jsonb not null,response jsonb not null,group_id uuid not null,original_batch_id uuid not null,
 replacement_batch_id uuid not null unique,supplier_id uuid not null,quantity integer not null check(quantity between 1 and 1000),
 original_snapshot jsonb not null,received_at timestamptz not null default now(),unique(actor_id,idempotency_key));
create table if not exists greenloop_private.srp_allocations(
 return_id uuid primary key,receipt_id uuid not null references greenloop_private.srp_receipts(id),
 original_imei text,return_number text not null);
create index if not exists srp_receipts_group on greenloop_private.srp_receipts(group_id);
create index if not exists srp_allocations_receipt on greenloop_private.srp_allocations(receipt_id);
alter table greenloop_private.srp_receipts enable row level security;
alter table greenloop_private.srp_allocations enable row level security;
revoke all on greenloop_private.srp_receipts,greenloop_private.srp_allocations from public,anon,authenticated;
create or replace function greenloop_private.srp_immutable()returns trigger language plpgsql set search_path=pg_catalog,public as $$begin raise exception 'Replacement receipt links and audit history are permanent.'using errcode='55000';end;$$;
drop trigger if exists srp_immutable on greenloop_private.srp_receipts;
create trigger srp_immutable before update or delete on greenloop_private.srp_receipts for each row execute function greenloop_private.srp_immutable();
drop trigger if exists srp_immutable on greenloop_private.srp_allocations;
create trigger srp_immutable before update or delete on greenloop_private.srp_allocations for each row execute function greenloop_private.srp_immutable();

create or replace function greenloop_private.srp_access(p_cap text default 'replacement_view')returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 perform greenloop_private.pf_cap('supplier_returns','view');perform greenloop_private.pf_cap('supplier_returns','replacement_view');
 if p_cap<>'replacement_view'then perform greenloop_private.pf_cap('supplier_returns',p_cap);end if;
end;$$;
create or replace function greenloop_private.srp_rows()returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select g||jsonb_build_object('replacement_received',a.received,'replacement_pending',a.pending,'other_settled',a.other_settled,
  'status',case when a.pending>0 and a.received>0 then 'Partially received'when a.pending>0 then 'Awaiting replacement'when a.received>0 then 'Replacement received'else 'Already settled'end,
  'receipts',coalesce(h.receipts,'[]'::jsonb))
 from jsonb_array_elements(public.list_active_stock_returns(null,null))g
 cross join lateral(select count(*)filter(where al.return_id is not null)::integer received,
  count(*)filter(where al.return_id is null and r.settled_at is null and r.settlement_type is null)::integer pending,
  count(*)filter(where al.return_id is null and(r.settled_at is not null or r.settlement_type is not null))::integer other_settled
  from jsonb_array_elements_text(g->'return_ids')i join public.supplier_returns r on r.id=i.value::uuid
  left join greenloop_private.srp_allocations al on al.return_id=r.id
  where r.archived_at is null and r.status='returned')a
 left join lateral(select jsonb_agg(jsonb_build_object('receipt_id',p.id,'batch_id',p.replacement_batch_id,'batch_number',p.response->>'batch_number',
  'invoice_number',p.response->>'invoice_number','quantity',p.quantity,'received_at',p.received_at,'received_by',coalesce(u.full_name,u.login_username,'Staff'),
  'receipt_available',b.id is not null,'notes',p.command->>'notes',
  'phones',coalesce((select jsonb_agg(v order by v->>'imei')from(select distinct on(d.id)jsonb_build_object('imei',d.imei_1,'model',d.model,'gb',d.storage_gb,'color',d.color,'stage',j.current_status)v
   from public.jobs j join public.devices d on d.id=j.device_id where j.receiving_batch_id=p.replacement_batch_id and j.deleted_at is null and d.deleted_at is null order by d.id,j.created_at desc,j.id desc)x),'[]'::jsonb)
  )order by p.received_at desc,p.id)receipts from greenloop_private.srp_receipts p left join public.receiving_batches b on b.id=p.replacement_batch_id
  left join public.user_profiles u on u.id=p.actor_id where p.group_id=(g->>'group_id')::uuid)h on true;
$$;
create or replace function public.get_stock_replacement_data_v1(p_filters jsonb default '{}',p_download boolean default false,p_expected_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare rows jsonb;token text;begin
 perform greenloop_private.srp_access(case when coalesce(p_download,false)then 'replacement_download'else 'replacement_view'end);
 if jsonb_typeof(p_filters)is distinct from 'object'or exists(select 1 from jsonb_each(p_filters)e where e.key<>all(array['supplier_id','batch_id','from_date','to_date','query'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Choose valid replacement filters.'using errcode='22023';end if;
 if p_filters<>'{}'then perform greenloop_private.pf_cap('supplier_returns','search');end if;
 if nullif(p_filters->>'from_date','')::date>nullif(p_filters->>'to_date','')::date then raise exception 'From date must not be after To date.'using errcode='22023';end if;
 select coalesce(jsonb_agg(r order by r->>'returned_at'desc,r->>'group_id'),'[]')into rows from greenloop_private.srp_rows()r where
  (nullif(p_filters->>'supplier_id','')is null or r->>'supplier_id'=p_filters->>'supplier_id')and(nullif(p_filters->>'batch_id','')is null or r->>'batch_id'=p_filters->>'batch_id')
  and(nullif(p_filters->>'from_date','')is null or timezone('Asia/Dubai',(r->>'returned_at')::timestamptz)::date>=(p_filters->>'from_date')::date)
  and(nullif(p_filters->>'to_date','')is null or timezone('Asia/Dubai',(r->>'returned_at')::timestamptz)::date<=(p_filters->>'to_date')::date)
  and(nullif(btrim(p_filters->>'query'),'')is null or strpos(lower(r::text),lower(btrim(p_filters->>'query')))>0);
 token:=md5(rows::text);if p_expected_snapshot is not null and token is distinct from p_expected_snapshot then raise exception 'Replacement data changed. Refresh before downloading.'using errcode='40001';end if;
 return jsonb_build_object('rows',rows,'filters',p_filters,'snapshot',token,'generated_at',statement_timestamp(),'names_allowed',coalesce(public.get_my_partner_name_access(),false),
  'summary',jsonb_build_object('returned',coalesce((select sum((r->>'returned_quantity')::integer)from jsonb_array_elements(rows)r),0),'received',coalesce((select sum((r->>'replacement_received')::integer)from jsonb_array_elements(rows)r),0),'pending',coalesce((select sum((r->>'replacement_pending')::integer)from jsonb_array_elements(rows)r),0)),
  'permissions',jsonb_build_object('receive',coalesce(public.has_page_capability_v1('supplier_returns','replacement_entry'),false)));
end;$$;
create or replace function public.receive_stock_replacement_v1(p_group_id uuid,p_quantity integer,p_idempotency_key uuid,p_notes text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare saved greenloop_private.srp_receipts%rowtype;g jsonb;b public.receiving_batches%rowtype;r record;ids uuid[]:='{}';
 cmd jsonb;bid uuid;batchno text;invno text;channel_name text;channel_id uuid;result jsonb;receipt uuid:=gen_random_uuid();actor text;scope_started boolean:=false;
begin
 perform greenloop_private.srp_access('replacement_entry');
 if p_group_id is null or p_idempotency_key is null or p_quantity is null or p_quantity not between 1 and 1000 or length(coalesce(p_notes,''))>2000 then raise exception 'Select a return and a replacement quantity from 1 to 1000.'using errcode='22023';end if;
 cmd:=jsonb_build_object('group_id',p_group_id,'quantity',p_quantity,'notes',nullif(btrim(p_notes),''));
 perform pg_advisory_xact_lock(hashtextextended('srp-command:'||auth.uid()::text||p_idempotency_key::text,0));
 select * into saved from greenloop_private.srp_receipts where actor_id=auth.uid()and idempotency_key=p_idempotency_key;
 if found then if saved.command<>cmd then raise exception 'This retry key belongs to different replacement details.'using errcode='22023';end if;return saved.response;end if;
 perform pg_advisory_xact_lock(hashtextextended('srp-group:'||p_group_id::text,0));
 select v into g from jsonb_array_elements(public.list_active_stock_returns(null,null))v where v->>'group_id'=p_group_id::text;
 if g is null then raise exception 'Select a completed, active supplier return.'using errcode='22023';end if;
 select * into b from public.receiving_batches where id=(g->>'batch_id')::uuid for update;
 if b.id is null or b.supplier_id is distinct from(g->>'supplier_id')::uuid or not exists(select 1 from public.suppliers where id=b.supplier_id and deleted_at is null and is_active)then raise exception 'The original supplier receipt is unavailable.'using errcode='55000';end if;
 for r in select x.* from public.supplier_returns x where x.id in(select value::uuid from jsonb_array_elements_text(g->'return_ids'))order by x.id for update loop
  if r.status='returned'and r.archived_at is null and r.batch_id=b.id and r.supplier_id=b.supplier_id and r.settled_at is null and r.settlement_type is null and not exists(select 1 from greenloop_private.srp_allocations a where a.return_id=r.id)then ids:=array_append(ids,r.id);end if;
 end loop;
 if cardinality(ids)<p_quantity then raise exception 'Only % replacement phone(s) remain pending. Refresh the report.',cardinality(ids)using errcode='22023';end if;
 ids:=ids[1:p_quantity];
 select c.id,c.channel_name into channel_id,channel_name from public.stock_channels c where c.is_active and(c.id=b.stock_channel_id or b.stock_channel_id is null and lower(c.channel_name)='company stock')order by c.id limit 1;
 if channel_id is null then raise exception 'The original stock channel is inactive. Review it before receiving replacements.'using errcode='22023';end if;
 batchno:='BATCH-'||to_char(timezone('Asia/Dubai',now()),'YYYY')||'-'||lpad(nextval('public.receiving_batch_number_sequence')::text,4,'0');
 invno:='INV-'||to_char(timezone('Asia/Dubai',now()),'YYYY')||'-'||lpad(nextval('public.stock_receipt_invoice_number_sequence')::text,6,'0');
 perform greenloop_private.begin_capability('receive_stock_replacement_v1',cmd);scope_started:=true;
 insert into public.receiving_batches(batch_number,invoice_number,receiving_source,notes,created_by,stock_channel_id,planned_model,planned_quantity,supplier_id)
  values(batchno,invno,channel_name,'Replacement for '||(g->>'return_reference')||' / '||b.batch_number||coalesce(E'\n'||nullif(btrim(p_notes),''),''),auth.uid(),channel_id,'Stock received',p_quantity,b.supplier_id)returning id into bid;
 result:=jsonb_build_object('receipt_id',receipt,'batch_id',bid,'batch_number',batchno,'invoice_number',invno,'quantity',p_quantity,'return_reference',g->>'return_reference');
 insert into greenloop_private.srp_receipts(id,actor_id,idempotency_key,command,response,group_id,original_batch_id,replacement_batch_id,supplier_id,quantity,original_snapshot)
  values(receipt,auth.uid(),p_idempotency_key,cmd,result,p_group_id,b.id,bid,b.supplier_id,p_quantity,g);
 insert into greenloop_private.srp_allocations(return_id,receipt_id,original_imei,return_number)select id,receipt,imei_1,return_number from public.supplier_returns where id=any(ids);
 insert into greenloop_private.supplier_return_capabilities select txid_current(),pg_backend_pid(),id from public.supplier_returns where id=any(ids)on conflict do nothing;
 update public.supplier_returns set settlement_type='replacement',settlement_reference=batchno,settlement_notes=nullif(btrim(p_notes),''),settled_by=auth.uid(),settled_at=now(),updated_at=now()where id=any(ids);
 select coalesce(full_name,login_username,'Staff')into actor from public.user_profiles where id=auth.uid();
 insert into public.supplier_return_events(return_id,action,from_status,to_status,actor_id,actor_name,notes,event_data)
  select id,'settlement','returned','returned',auth.uid(),coalesce(actor,'Staff'),nullif(btrim(p_notes),''),jsonb_build_object('settlement_type','replacement','settlement_reference',batchno,'replacement_batch_id',bid,'financial_posting',false)from public.supplier_returns where id=any(ids);
 delete from greenloop_private.supplier_return_capabilities where transaction_id=txid_current()and backend_pid=pg_backend_pid()and return_id=any(ids);
 perform greenloop_private.end_capability();scope_started:=false;return result;
exception when others then if scope_started then perform greenloop_private.end_capability();end if;raise;
end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_stock_replacement_data_v1','{"page":"supplier_returns","capability":"replacement_view","read":true}'),
 ('receive_stock_replacement_v1','{"page":"supplier_returns","capability":"replacement_entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_stock_replacement_data_v1','receive_stock_replacement_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
  body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),case when f.provolatile='s'then 'stable'else 'volatile'end,body);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
revoke all on function greenloop_private.srp_access(text),greenloop_private.srp_rows(),greenloop_private.srp_immutable()from public,anon,authenticated;
create table if not exists greenloop_private.srp_installation(identity text primary key,hash text not null);
alter table greenloop_private.srp_installation enable row level security;revoke all on greenloop_private.srp_installation from public,anon,authenticated;
create or replace function public.get_stock_replacement_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_accounts_imei_data_version()='20261104-accounts-imei-data-1'
 and(select count(*)=8 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.srp_installation)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='supplier_returns'and capabilities @> '[{"key":"replacement_view","write":false},{"key":"replacement_entry","write":true},{"key":"replacement_download","write":false}]')
 and(select count(*)=2 and bool_and(relrowsecurity)from pg_class where oid in('greenloop_private.srp_receipts'::regclass,'greenloop_private.srp_allocations'::regclass))
 and(select count(*)=2 from pg_trigger where tgrelid in('greenloop_private.srp_receipts'::regclass,'greenloop_private.srp_allocations'::regclass)and tgname='srp_immutable'and tgenabled='O'and tgfoid='greenloop_private.srp_immutable()'::regprocedure)
 and exists(select 1 from pg_constraint where conrelid='greenloop_private.srp_allocations'::regclass and contype='p'and pg_get_constraintdef(oid)='PRIMARY KEY (return_id)')
 and exists(select 1 from pg_constraint where conrelid='greenloop_private.srp_receipts'::regclass and contype='u'and pg_get_constraintdef(oid)='UNIQUE (actor_id, idempotency_key)')
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='receive_stock_replacement_v1'and rule='{"page":"supplier_returns","capability":"replacement_entry"}'::jsonb)
 and not has_function_privilege('anon','public.get_stock_replacement_data_v1(jsonb,boolean,text)','EXECUTE')and not has_function_privilege('anon','public.receive_stock_replacement_v1(uuid,integer,uuid,text)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.srp_receipts','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.srp_receipts','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.srp_allocations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.srp_allocations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.srp_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 then '20261104-stock-replacement-1'end;$$;
revoke all on function public.get_stock_replacement_version()from public;grant execute on function public.get_stock_replacement_version()to anon,authenticated;
insert into greenloop_private.srp_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where
 p.pronamespace='greenloop_private'::regnamespace and p.proname in('srp_access','srp_rows','srp_immutable')or p.pronamespace='public'::regnamespace and p.proname in('get_stock_replacement_data_v1','receive_stock_replacement_v1','get_stock_replacement_version')
 or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_stock_replacement_data_v1(jsonb,boolean,text)'::regprocedure,'public.receive_stock_replacement_v1(uuid,integer,uuid,text)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'then raise exception 'Stock Replacement verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_stock_replacement_version()as installed_stock_replacement_version;
