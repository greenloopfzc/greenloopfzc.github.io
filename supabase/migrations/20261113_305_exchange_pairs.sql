-- One complete exchange per report row. Read-only; saved links and phone records stay unchanged.
DO $exchange_pairs_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_stock_report_links_version()is distinct from '20261113-stock-report-links-1'then raise exception 'Verify Stock Report Links before installing Exchange Pairs.';end if;if to_regprocedure('public.get_supplier_exchange_pairs_version()')is not null then if public.get_supplier_exchange_pairs_version()is distinct from '20261113-exchange-pairs-1'then raise exception 'Existing exchange report integrity needs review.';end if;end if;end;$$;
create or replace function greenloop_private.sex_pairs(p_rows jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare pairs jsonb;begin
 if exists(select 1 from jsonb_array_elements(p_rows)r where r->>'kind'='returned'and nullif(r->>'return_id','')is null)or exists(select 1 from jsonb_array_elements(p_rows)r group by r->>'return_id',r->>'kind'having count(*)>1)then raise exception 'Exchange identity could not be verified. Refresh before using this report.'using errcode='40001';end if;
 select coalesce(jsonb_agg(jsonb_build_object('exchange_id',sr.id,'returned',p.r,'replacement',child.replacement,'batch_id',b.batch_id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'received_quantity',b.received_quantity,'supplier_code',b.supplier_code,'supplier_name',case when public.get_my_partner_name_access()then b.supplier_name end,'return_number',sr.return_number,'return_reference',coalesce(sr.slip_reference,p.r->>'return_reference'),'returned_at',coalesce(sr.handed_over_at,sr.requested_at),'replacement_received_at',link.x->'received_at','status',case when child.replacement is not null then case when coalesce((link.x->>'entered')::boolean,false)then 'Replacement received'else 'Intake pending'end when sr.settlement_type is not null then 'Settled: '||initcap(sr.settlement_type::text)else 'Replacement pending'end,'reason',greenloop_private.srr_display_reason(sr.reason::text,sr.notes))order by p.n),'[]')into pairs
 from jsonb_array_elements(p_rows)with ordinality p(r,n)join public.supplier_returns sr on sr.id=(p.r->>'return_id')::uuid
 join greenloop_private.sc_receipts()b on b.parent_batch_id is null and sr.batch_id=any(b.descendant_ids)
 left join lateral(select children.value as replacement from jsonb_array_elements(p_rows)as children(value)where children.value->>'kind'='replacement'and children.value->>'return_id'=p.r->>'return_id')child on true
 left join lateral(select x from greenloop_private.srd_links(sr.id)x)link on true where p.r->>'kind'='returned';
 if jsonb_array_length(pairs)<>(select count(*)from jsonb_array_elements(p_rows)r where r->>'kind'='returned')then raise exception 'The complete original stock for these exchanges could not be verified.'using errcode='40001';end if;
 return pairs;
end;$$;
create or replace function greenloop_private.sex_details(p_record text,p_batch uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare sr public.supplier_returns%rowtype;b record;od public.devices%rowtype;link jsonb;cap jsonb;phone jsonb;replacement boolean;rid uuid;begin
 perform greenloop_private.srp_access('replacement_view');
 if p_record is null or p_record!~*'^(return|replacement):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'or p_batch is null then raise exception 'Choose one valid exchange.'using errcode='22023';end if;
 replacement:=split_part(p_record,':',1)='replacement';rid:=split_part(p_record,':',2)::uuid;
 select *into sr from public.supplier_returns where id=rid and archived_at is null and status='returned';
 select *into b from greenloop_private.sc_receipts()where batch_id=p_batch and parent_batch_id is null and sr.batch_id=any(descendant_ids);
 if sr.id is null or b.batch_id is null then raise exception 'This exchange is no longer in this original stock. Refresh and retry.'using errcode='40001';end if;
 select x into link from greenloop_private.srd_links(rid)x;
 if replacement and link is null then raise exception 'No linked replacement is recorded for this return.'using errcode='40001';end if;
 select *into od from public.devices where id=sr.device_id;select capture into cap from greenloop_private.gl4_return_phone_details where return_id=rid;
 phone:=jsonb_build_object('record_key',p_record,'batch_id',b.batch_id,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'receipt_quantity',b.received_quantity,'received_at',b.received_at,'supplier_code',b.supplier_code,'supplier_name',case when public.get_my_partner_name_access()then b.supplier_name end,'imei',case when replacement then link->>'new_imei'else coalesce(sr.imei_1,od.imei_1)end,'model',case when replacement then link->>'model'else coalesce(nullif(sr.model,''),od.model,cap->>'model')end,'storage_gb',case when replacement then link->'storage_gb'else coalesce(to_jsonb(od.storage_gb),case when sr.source_snapshot->>'storage_gb'~'^[0-9]{1,5}$'then(sr.source_snapshot->>'storage_gb')::jsonb end,case when cap->>'storage_gb'~'^[0-9]{1,5}$'then(cap->>'storage_gb')::jsonb end)end,'color',case when replacement then link->>'color'else coalesce(od.color,sr.source_snapshot->>'color',cap->>'color')end,'initial_grade',case when replacement then link->>'grade'else coalesce(od.gc_grade::text,od.original_grade::text)end,'stage',case when replacement then link->>'stage'else 'Returned to supplier'end,'returned',not replacement,'return_id',rid,'returned_at',coalesce(sr.handed_over_at,sr.requested_at),'return_number',sr.return_number,'return_reason',sr.reason::text,'return_notes',sr.notes);
 return jsonb_build_object('version','20261113-exchange-pairs-1','requested_record_key',p_record,'phone',phone,'links',case when link is null then '[]'::jsonb else jsonb_build_array(link)end,'names_allowed',coalesce(public.get_my_partner_name_access(),false),'generated_at',statement_timestamp());
end;$$;
revoke all on function greenloop_private.sex_pairs(jsonb),greenloop_private.sex_details(text,uuid)from public,anon,authenticated;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;begin
 foreach sig in array array['greenloop_private.gl4_history(jsonb,boolean,text,integer)','greenloop_private.srd_details(text,text,uuid)']loop
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);updated:=old;
 if sig like '%gl4_history%'then
  if position('greenloop_private.sex_pairs('in old)=0 then
   if position('token text;begin'in old)=0 or position('token:=md5(allrows::text);'in old)=0 or position('return data||jsonb_build_object(''phone_rows'''in old)=0 then raise exception 'Replacement report boundary changed. Review before installing.';end if;
   updated:=replace(updated,'token text;begin','token text;pairs jsonb;begin');
   updated:=replace(updated,'token:=md5(allrows::text);','pairs:=greenloop_private.sex_pairs(allrows);token:=md5(allrows::text);');
   updated:=replace(updated,'return data||jsonb_build_object(''phone_rows''',$pairs$return data||jsonb_build_object('exchange_version','20261113-exchange-pairs-1','exchange_total',jsonb_array_length(pairs),'exchange_snapshot',md5(pairs::text),'exchange_rows',coalesce((select jsonb_agg(x.r order by x.n)from jsonb_array_elements(pairs)with ordinality x(r,n)where p_download or(x.n>greatest(0,p_offset)and x.n<=greatest(0,p_offset)+50)),'[]'),'phone_rows'$pairs$);
  end if;
 else
  if position('greenloop_private.sex_details('in old)=0 then
   if position('if p_page=''accounts''then'in old)=0 then raise exception 'Stock details access boundary changed.';end if;
   updated:=replace(updated,'if p_page=''accounts''then','if p_page=''supplier_returns''then return greenloop_private.sex_details(p_record,p_batch);end if; if p_page=''accounts''then');
  end if;
 end if;
 if updated<>old then execute updated;end if;
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;
end;$patch$;
create or replace function public.get_supplier_exchange_report_v1(p_filters jsonb default '{}',p_download boolean default false,p_expected_snapshot text default null,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare data jsonb;begin
 perform greenloop_private.require_office_network();if p_offset is null or p_offset<0 or p_offset%50<>0 or p_download is null then raise exception 'Choose a valid exchange report page.'using errcode='22023';end if;
 data:=greenloop_private.gl4_history(p_filters,p_download,null,p_offset);
 if p_expected_snapshot is not null and p_expected_snapshot is distinct from data->>'exchange_snapshot'then raise exception 'Exchange details changed. Refresh before downloading.'using errcode='40001';end if;
 return data||jsonb_build_object('total',data->'exchange_total','snapshot',data->'exchange_snapshot');
end;$$;
revoke all on function public.get_supplier_exchange_report_v1(jsonb,boolean,text,integer)from public,anon;grant execute on function public.get_supplier_exchange_report_v1(jsonb,boolean,text,integer)to authenticated;
create table if not exists greenloop_private.exchange_pairs_installation(identity text primary key,hash text not null);alter table greenloop_private.exchange_pairs_installation enable row level security;revoke all on greenloop_private.exchange_pairs_installation from public,anon,authenticated;
create or replace function public.get_supplier_exchange_pairs_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_stock_report_links_version()='20261113-stock-report-links-1'and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.exchange_pairs_installation)and not has_function_privilege('anon','public.get_supplier_exchange_report_v1(jsonb,boolean,text,integer)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.sex_details(text,uuid)','EXECUTE')and not has_table_privilege('authenticated','greenloop_private.exchange_pairs_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261113-exchange-pairs-1'end;$$;
revoke all on function public.get_supplier_exchange_pairs_version()from public;grant execute on function public.get_supplier_exchange_pairs_version()to anon,authenticated;
insert into greenloop_private.exchange_pairs_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.sex_pairs(jsonb)','greenloop_private.sex_details(text,uuid)','greenloop_private.gl4_history(jsonb,boolean,text,integer)','greenloop_private.srd_details(text,text,uuid)','public.get_supplier_exchange_report_v1(jsonb,boolean,text,integer)','public.get_supplier_exchange_pairs_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_supplier_exchange_pairs_version()is distinct from '20261113-exchange-pairs-1'then raise exception 'Exchange report verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$exchange_pairs_install$;
select public.get_supplier_exchange_pairs_version()as installed_exchange_pairs_version;
