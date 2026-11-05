-- Complete stock lists, permanent replacement phone pairing and bulk issue capacity.
begin;
set local statement_timeout='120s';
do $$begin
 if public.get_stock_bulk_search_version()is distinct from '20261105-stock-bulk-search-1'then raise exception 'Verify the preceding Stock/Bulk installation first.';end if;
 if to_regprocedure('public.get_complete_stock_lists_version()')is not null then if public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'then raise exception 'Existing Complete Stock Lists integrity requires review.';end if;end if;
end;$$;
create temporary table cl_review(identity text primary key)on commit drop;

-- Pair actual replacement phone entries with the slots allocated by the native
-- replacement receipt. Original phones and permanent return ledgers stay intact.
create table if not exists greenloop_private.srp_phone_links(
 return_id uuid primary key,replacement_batch_id uuid not null,
 replacement_job_id uuid not null unique,replacement_device_id uuid not null unique,
 return_record_key text not null,root_record_key text not null,root_batch_id uuid not null,
 linked_at timestamptz not null default now());
alter table greenloop_private.srp_phone_links enable row level security;
revoke all on greenloop_private.srp_phone_links from public,anon,authenticated;
drop trigger if exists srp_phone_links_immutable on greenloop_private.srp_phone_links;
create trigger srp_phone_links_immutable before update or delete on greenloop_private.srp_phone_links
 for each row execute function greenloop_private.srp_immutable();
create or replace function greenloop_private.cl_allocate_replacement(p_job uuid)returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.jobs%rowtype;a record;parent greenloop_private.srp_phone_links%rowtype;k text;begin
 select *into j from public.jobs where id=p_job;
 if j.id is null or not exists(select 1 from greenloop_private.srp_receipts where replacement_batch_id=j.receiving_batch_id)or exists(select 1 from greenloop_private.srp_phone_links where replacement_job_id=j.id)then return;end if;
 perform pg_advisory_xact_lock(hashtext('replacement-phone:'||j.receiving_batch_id::text));
 select r.id,r.batch_id,r.device_id into a from greenloop_private.srp_receipts p
 join greenloop_private.srp_allocations x on x.receipt_id=p.id
 join public.supplier_returns r on r.id=x.return_id
 where p.replacement_batch_id=j.receiving_batch_id and not exists(select 1 from greenloop_private.srp_phone_links l where l.return_id=r.id)
 order by r.requested_at,r.return_number,r.id limit 1;
 if a.id is null then raise exception 'No unassigned return slot remains for this replacement receipt.'using errcode='23514';end if;
 k:=case when a.device_id is null then 'return:'||a.id::text else 'phone:'||a.batch_id::text||':'||a.device_id::text end;
 select *into parent from greenloop_private.srp_phone_links where replacement_device_id=a.device_id and replacement_batch_id=a.batch_id;
 insert into greenloop_private.srp_phone_links(return_id,replacement_batch_id,replacement_job_id,replacement_device_id,return_record_key,root_record_key,root_batch_id)
 values(a.id,j.receiving_batch_id,j.id,j.device_id,k,coalesce(parent.root_record_key,k),coalesce(parent.root_batch_id,a.batch_id));
end;$$;
create or replace function greenloop_private.cl_replacement_job()returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.cl_allocate_replacement(new.id);return new;
end;$$;
revoke all on function greenloop_private.cl_allocate_replacement(uuid),greenloop_private.cl_replacement_job()from public,anon,authenticated;
drop trigger if exists cl_replacement_job on public.jobs;
create trigger cl_replacement_job after insert on public.jobs for each row execute function greenloop_private.cl_replacement_job();
do $$declare v_job record;begin for v_job in select j.id from public.jobs j join greenloop_private.srp_receipts p on p.replacement_batch_id=j.receiving_batch_id
 where j.deleted_at is null order by j.created_at,j.id loop perform greenloop_private.cl_allocate_replacement(v_job.id);end loop;end;$$;

-- Preserve the reviewed base reader for ordinary phone/history classification.
do $$declare s text;begin
 if to_regprocedure('greenloop_private.cl_base_aid_rows(jsonb)')is null then
  s:=pg_get_functiondef('greenloop_private.aid_rows(jsonb)'::regprocedure);
  if strpos(s,'from classified c')=0 then raise exception 'Accounts row reader boundary differs.';end if;
  execute replace(s,'FUNCTION greenloop_private.aid_rows(','FUNCTION greenloop_private.cl_base_aid_rows(');
 end if;
end;$$;
revoke all on function greenloop_private.cl_base_aid_rows(jsonb)from public,anon,authenticated;
create or replace function greenloop_private.aid_rows(f jsonb)returns setof jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
 select r||jsonb_build_object('is_replacement',l.return_id is not null,
  'replacement_return_id',l.return_id,'replacement_of_record_key',l.return_record_key,
  'replacement_root_record_key',l.root_record_key,'replacement_root_batch_id',l.root_batch_id)
 from greenloop_private.cl_base_aid_rows(f-array['supplier_id','batch_id','invoice_number'])r
 left join greenloop_private.srp_phone_links l on l.replacement_job_id=nullif(r->>'job_id','')::uuid
 where(nullif(f->>'supplier_id','')is null or r->>'supplier_id'=f->>'supplier_id')
 and(nullif(f->>'batch_id','')is null or exists(select 1 from greenloop_private.sc_receipts()b
   where b.batch_id=(f->>'batch_id')::uuid and nullif(r->>'batch_id','')::uuid=any(b.descendant_ids)))
 and(nullif(f->>'invoice_number','')is null or exists(select 1 from greenloop_private.sc_receipts()b
   where b.invoice_number=f->>'invoice_number'and nullif(r->>'batch_id','')::uuid=any(b.descendant_ids)));
$$;
create or replace function greenloop_private.cl_number_rows(p_rows jsonb)returns jsonb
language sql immutable set search_path=pg_catalog as $$
 with source as(select r,n,coalesce(nullif(r->>'replacement_root_record_key',''),r->>'record_key')g
  from jsonb_array_elements(p_rows)with ordinality x(r,n)),groups as(
  select g,row_number()over(order by min(n))serial_no from source group by g)
 select coalesce(jsonb_agg(r||jsonb_build_object('serial_no',serial_no)order by serial_no,
  case when coalesce((r->>'is_replacement')::boolean,false)then 1 else 0 end,n),'[]')from source join groups using(g);
$$;
revoke all on function greenloop_private.aid_rows(jsonb),greenloop_private.cl_number_rows(jsonb)from public,anon,authenticated;
insert into cl_review values('greenloop_private.aid_rows(jsonb)'),('greenloop_private.cl_number_rows(jsonb)'),('greenloop_private.cl_base_aid_rows(jsonb)'),('greenloop_private.cl_allocate_replacement(uuid)'),('greenloop_private.cl_replacement_job()');
do $$declare id regprocedure:='greenloop_private.aid_report(jsonb,integer,integer,text,text,boolean,text)'::regprocedure;s text;begin
 s:=pg_get_functiondef(id);
 if strpos(s,'ordered:=greenloop_private.cl_number_rows(ordered);')=0 then
  if strpos(s,'token:=md5(ordered::text);')=0 then raise exception 'Accounts numbering boundary differs.';end if;
  s:=replace(s,'token:=md5(ordered::text);','ordered:=greenloop_private.cl_number_rows(ordered);token:=md5(ordered::text);');execute s;
 end if;
 insert into cl_review values(id::text)on conflict do nothing;
end;$$;

-- Remove business selection caps; existing validation, locks, pending balances,
-- Office Only and issue permissions remain. Clients send large selections in
-- transport batches, keeping every request for the same phone together.
do $$declare id regprocedure;s text;before text;begin
 select to_regprocedure(implementation)into id from greenloop_private.office_routines where to_regprocedure(identity)='public.prepare_parts_picking_v1(jsonb)'::regprocedure;
 s:=pg_get_functiondef(id);before:=s;
 if strpos(s,'jsonb_array_length(p_groups)not between 1 and 50')>0 then
  s:=replace(s,'jsonb_array_length(p_groups)not between 1 and 50','jsonb_array_length(p_groups)<1');
  s:=replace(s,'Select up to 50 valid report lines.','Select valid pending report lines.');
  s:=replace(s,'if jsonb_array_length(result->''rows'')>200 then raise exception ''Select fewer report lines; each bulk issue supports up to 200 requests.''using errcode=''22023'';end if;','');
 elsif strpos(s,'jsonb_array_length(p_groups)<1')=0 then raise exception 'Parts picking selection boundary differs.';end if;
 if s<>before then execute s;end if;insert into cl_review values(id::text)on conflict do nothing;
 select to_regprocedure(implementation)into id from greenloop_private.office_routines where to_regprocedure(identity)='public.issue_parts_picking_v1(jsonb)'::regprocedure;
 s:=pg_get_functiondef(id);before:=s;
 if strpos(s,'jsonb_array_length(p_lines)not between 1 and 200')>0 then
  s:=replace(s,'jsonb_array_length(p_lines)not between 1 and 200','jsonb_array_length(p_lines)<1');
  s:=replace(s,'Select 1 to 200 pending part requests.','Select pending part requests.');
 elsif strpos(s,'jsonb_array_length(p_lines)<1')=0 then raise exception 'Parts picking issue boundary differs.';end if;
 if s<>before then execute s;end if;insert into cl_review values(id::text)on conflict do nothing;
end;$$;
do $seal$declare ids regprocedure[]:=array(select identity::regprocedure from cl_review);t record;begin
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
  execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using ids;
 end loop;
end;$seal$;
create table if not exists greenloop_private.complete_stock_lists_installation(identity text primary key,hash text not null);
alter table greenloop_private.complete_stock_lists_installation enable row level security;
revoke all on greenloop_private.complete_stock_lists_installation from public,anon,authenticated;
create or replace function public.get_complete_stock_lists_version()returns text
language sql stable security definer set search_path=pg_catalog,public as $$select case when
 public.get_stock_bulk_search_version()='20261105-stock-bulk-search-1'
 and(select count(*)=9 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.complete_stock_lists_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.srp_phone_links'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.srp_phone_links','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('authenticated','greenloop_private.srp_phone_links','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_trigger where tgrelid='public.jobs'::regclass and tgname='cl_replacement_job'and tgenabled='O'and tgfoid='greenloop_private.cl_replacement_job()'::regprocedure)
 and exists(select 1 from pg_trigger where tgrelid='greenloop_private.srp_phone_links'::regclass and tgname='srp_phone_links_immutable'and tgenabled='O'and tgfoid='greenloop_private.srp_immutable()'::regprocedure)
 then '20261105-complete-stock-lists-1'end;$$;
revoke all on function public.get_complete_stock_lists_version()from public;
grant execute on function public.get_complete_stock_lists_version()to anon,authenticated;
insert into greenloop_private.complete_stock_lists_installation select identity,md5(pg_get_functiondef(identity::regprocedure))from cl_review on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.complete_stock_lists_installation values('public.get_complete_stock_lists_version()',md5(pg_get_functiondef('public.get_complete_stock_lists_version()'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_complete_stock_lists_version()is distinct from '20261105-complete-stock-lists-1'then raise exception 'Complete Stock Lists verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_complete_stock_lists_version()installed_complete_stock_lists_version;
