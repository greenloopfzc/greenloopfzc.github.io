-- Private, grouped completion of missing issued-part prices. Installs no prices.
begin;
do $$begin if public.get_lab_bulk_transfer_version()is distinct from '20261030-lab-bulk-transfer-1'then raise exception 'Install and verify Bulk Lab Transfer first.';end if;end;$$;
-- These append-only provenance/audit ledgers deliberately have no operational
-- foreign keys: original deletion/audit preservation rules remain unchanged.
create table if not exists greenloop_private.parts_issue_sources(id bigint generated always as identity primary key,issue_id uuid not null,source text not null check(source in('local','china')),actor uuid not null,created_at timestamptz not null default now());
create index if not exists parts_issue_sources_latest on greenloop_private.parts_issue_sources(issue_id,id desc);
create table if not exists greenloop_private.parts_pricing_commands(user_id uuid not null,request_id uuid not null,action text not null,command jsonb not null,response jsonb not null,created_at timestamptz not null default now(),primary key(user_id,request_id));
alter table greenloop_private.parts_issue_sources enable row level security;alter table greenloop_private.parts_pricing_commands enable row level security;
revoke all on greenloop_private.parts_issue_sources,greenloop_private.parts_pricing_commands from public,anon,authenticated;
revoke all on sequence greenloop_private.parts_issue_sources_id_seq from public,anon,authenticated;
create or replace function greenloop_private.ppp_immutable()returns trigger language plpgsql set search_path=pg_catalog,public as $$begin raise exception 'Issued part source and pricing history are permanent.'using errcode='55000';end;$$;
drop trigger if exists ppp_immutable on greenloop_private.parts_issue_sources;create trigger ppp_immutable before update or delete on greenloop_private.parts_issue_sources for each row execute function greenloop_private.ppp_immutable();
drop trigger if exists ppp_immutable on greenloop_private.parts_pricing_commands;create trigger ppp_immutable before update or delete on greenloop_private.parts_pricing_commands for each row execute function greenloop_private.ppp_immutable();
create or replace function greenloop_private.ppp_norm(v text)returns text language sql immutable set search_path=pg_catalog as $$select lower(regexp_replace(btrim(coalesce(v,'')),'\s+',' ','g'));$$;
create or replace function greenloop_private.ppp_access(p_write boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())or not coalesce(public.has_page_access('parts'),false)or not coalesce(public.has_page_capability_v1('parts',case when p_write then 'issue'else 'view'end),false)or(p_write and not coalesce(public.has_page_edit_access('parts'),false))then raise exception 'Parts view or Issue parts permission is required for this action.'using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.ppp_record_source(p_issue uuid,p_source text)returns void language plpgsql security definer set search_path=pg_catalog,public as $$begin
 if p_source not in('local','china')or p_source is null then raise exception 'Choose Local or China as the part source.'using errcode='22023';end if;
 if p_source is distinct from(select source from greenloop_private.parts_issue_sources where issue_id=p_issue order by id desc limit 1)then insert into greenloop_private.parts_issue_sources(issue_id,source,actor)values(p_issue,p_source,auth.uid());end if;
end;$$;
create or replace function greenloop_private.ppp_units()returns setof jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with base as(
 select i.id issue_id,i.part_request_id request_id,o.id order_id,o.job_id,d.id device_id,d.imei_1 imei,
  coalesce(b.supplier_id,j.supplier_id)::text supplier_id,coalesce(s.supplier_code,'Not recorded')supplier_code,
  coalesce(b.id::text,'legacy:'||j.id::text)batch_id,coalesce(b.batch_number,'Legacy phone '||d.imei_1)batch_number,coalesce(nullif(btrim(b.invoice_number),''),'Not recorded')invoice_number,
  coalesce(nullif(btrim(d.model),''),'Unspecified')model,d.storage_gb,
  case when d.storage_gb in(1024,2048)then(d.storage_gb/1024)::text||' TB'when d.storage_gb is not null then d.storage_gb::text||' GB'else 'Not recorded'end storage_label,
  coalesce(nullif(btrim(d.color),''),'Not recorded')color,r.part_name,
  i.quantity_issued::integer quantity,i.quantity_returned::integer returned_quantity,i.issued_at,timezone('Asia/Dubai',i.issued_at)::date::text issued_day,
  coalesce(src.source,'unrecorded')source,coalesce(src.id,0)source_revision,coalesce(p.currency,'AED')currency,
  p.issue_id price_record_id
 from public.part_issue_transactions i join public.job_part_requests r on r.id=i.part_request_id
 join greenloop_private.parts_flow_requests m on m.request_id=r.id join greenloop_private.parts_flow_orders o on o.id=m.order_id
 join public.jobs j on j.id=o.job_id and j.deleted_at is null join public.devices d on d.id=o.device_id and d.deleted_at is null
 left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers s on s.id=coalesce(b.supplier_id,j.supplier_id)
 left join greenloop_private.parts_flow_prices p on p.issue_id=i.id
 left join lateral(select source,id from greenloop_private.parts_issue_sources where issue_id=i.id order by id desc limit 1)src on true
 where i.quantity_issued>0 and p.unit_price is null and(p.issue_id is not null or i.unit_cost is null or i.issue_notes like 'Issued by Parts Flow;%')
 ), keyed as(select to_jsonb(b)||jsonb_build_object('model_key',regexp_replace(greenloop_private.ppp_norm(model),'^(apple\s+)?iphone\s*','',''),'color_key',greenloop_private.ppp_norm(color),'part_key',greenloop_private.ppp_norm(part_name))u from base b)
 select u||jsonb_build_object('group_id',md5(jsonb_build_array(u->'supplier_id',u->'batch_id',u->'invoice_number',u->'model_key',u->'storage_gb',u->'color_key',u->'part_key',u->'source',u->'currency')::text))from keyed;
$$;
create or replace function greenloop_private.ppp_matches(u jsonb,f jsonb)returns boolean language plpgsql immutable set search_path=pg_catalog,public as $$declare k text;v text;actual text;begin
 for k,v in select key,value#>>'{}'from jsonb_each(f)loop
  if v is null or v=''or k in('quantity','phones','returned_quantity')then continue;end if;
  if k='query'then if strpos(greenloop_private.ppp_norm(concat_ws(' ',u->>'supplier_code',u->>'batch_number',u->>'invoice_number',u->>'model',u->>'storage_label',u->>'color',u->>'part_name',u->>'source')),greenloop_private.ppp_norm(v))=0 then return false;end if;continue;end if;
  actual:=case k when 'model'then u->>'model_key'when 'color'then u->>'color_key'when 'part_name'then u->>'part_key'else coalesce(u->>k,'Not recorded')end;
  if actual is distinct from v then return false;end if;
 end loop;return true;
end;$$;
create or replace function greenloop_private.ppp_report(p_filters jsonb,p_group text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare f jsonb:=coalesce(p_filters,'{}');units jsonb;matched jsonb;groups jsonb;selected jsonb;facets jsonb:='{}';k text;value_key text;label_key text;options jsonb;result jsonb;
begin
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['query','supplier_id','batch_id','invoice_number','model','storage_gb','color','part_name','source','currency','issued_day','quantity','phones','returned_quantity'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Use valid pending-price filters.'using errcode='22023';end if;
 if p_group is not null and p_group!~'^[a-f0-9]{32}$'then raise exception 'Select a current pending-price group.'using errcode='22023';end if;
 select coalesce(jsonb_agg(u order by u->>'issue_id'),'[]')into units from greenloop_private.ppp_units()u;
 select coalesce(jsonb_agg(u order by u->>'issue_id'),'[]')into matched from jsonb_array_elements(units)u where greenloop_private.ppp_matches(u,f);
 select coalesce(jsonb_agg(to_jsonb(g)order by g.supplier_code,g.batch_number,g.model,g.storage_gb,g.color,g.part_name,g.source),'[]')into groups from(
 select u->>'group_id'group_id,min(u->>'supplier_id')supplier_id,min(u->>'supplier_code')supplier_code,min(u->>'batch_id')batch_id,min(u->>'batch_number')batch_number,min(u->>'invoice_number')invoice_number,
  min(u->>'model')model,min(u->>'model_key')model_key,min((u->>'storage_gb')::integer)storage_gb,min(u->>'storage_label')storage_label,min(u->>'color')color,min(u->>'color_key')color_key,min(u->>'part_name')part_name,min(u->>'part_key')part_key,min(u->>'source')source,min(u->>'currency')currency,
  sum((u->>'quantity')::integer)::integer quantity,sum((u->>'returned_quantity')::integer)::integer returned_quantity,count(distinct u->>'device_id')::integer phones,count(*)::integer issue_count,
  min(u->>'issued_day')first_issued_day,max(u->>'issued_day')last_issued_day,
  md5(jsonb_agg(u order by u->>'issue_id')::text)selection_token
 from jsonb_array_elements(matched)u group by u->>'group_id')g;
 select coalesce(jsonb_agg(g),'[]')into selected from jsonb_array_elements(groups)g where(coalesce(f->>'quantity','')=''or g->>'quantity'=f->>'quantity')and(coalesce(f->>'phones','')=''or g->>'phones'=f->>'phones')and(coalesce(f->>'returned_quantity','')=''or g->>'returned_quantity'=f->>'returned_quantity');
 foreach k in array array['supplier_id','batch_id','invoice_number','model','storage_gb','color','part_name','source','currency','issued_day','quantity','phones','returned_quantity']loop
  value_key:=case k when 'model'then 'model_key'when 'color'then 'color_key'when 'part_name'then 'part_key'else k end;
  label_key:=case k when 'supplier_id'then 'supplier_code'when 'batch_id'then 'batch_number'when 'storage_gb'then 'storage_label'else k end;
  select coalesce(jsonb_agg(jsonb_build_object('value',v,'label',label)order by label),'[]')into options from(
   select coalesce(u->>value_key,'Not recorded')v,min(coalesce(u->>label_key,'Not recorded'))label from jsonb_array_elements(case when k in('quantity','phones','returned_quantity')then groups else units end)u group by coalesce(u->>value_key,'Not recorded'))x;
  if k='source'then options:='[{"value":"local","label":"Local"},{"value":"china","label":"China"},{"value":"unrecorded","label":"Not recorded"}]';end if;
  facets:=facets||jsonb_build_object(k,options);
 end loop;
 result:=jsonb_build_object('rows',selected,'facets',facets,'generated_at',now(),'overall_summary',jsonb_build_object('phones',(select count(distinct u->>'device_id')from jsonb_array_elements(units)u),'quantity',(select coalesce(sum((u->>'quantity')::integer),0)from jsonb_array_elements(units)u)), 'summary',jsonb_build_object('groups',jsonb_array_length(selected),
  'phones',(select count(distinct u->>'device_id')from jsonb_array_elements(matched)u where exists(select 1 from jsonb_array_elements(selected)g where g->>'group_id'=u->>'group_id')),
  'quantity',(select coalesce(sum((g->>'quantity')::integer),0)from jsonb_array_elements(selected)g),
  'returned_quantity',(select coalesce(sum((g->>'returned_quantity')::integer),0)from jsonb_array_elements(selected)g)),
  'details',case when p_group is null then '[]'::jsonb else coalesce((select jsonb_agg(u order by u->>'imei',u->>'issued_at',u->>'issue_id')from jsonb_array_elements(matched)u where u->>'group_id'=p_group and exists(select 1 from jsonb_array_elements(selected)g where g->>'group_id'=p_group)),'[]')end);
 return result;
end;$$;
create or replace function public.get_pending_parts_prices_v1(p_filters jsonb default '{}',p_group text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.ppp_access(false);if coalesce(p_filters,'{}')<>'{}'::jsonb and not coalesce(public.has_page_capability_v1('parts','search'),false)then raise exception 'Parts Search permission is required to filter this report.'using errcode='42501';end if;return greenloop_private.ppp_report(p_filters,p_group);end;$$;
create or replace function public.save_pending_parts_prices_v1(p_group text,p_filters jsonb,p_selection_token text,p_unit_price numeric,p_source text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare command jsonb:=jsonb_build_object('group',p_group,'filters',p_filters,'selection_token',p_selection_token,'unit_price',p_unit_price,'source',p_source);saved greenloop_private.parts_pricing_commands%rowtype;report jsonb;g jsonb;ids uuid[];u jsonb;n integer;result jsonb;
begin
 perform greenloop_private.ppp_access(true);
 if p_request_id is null then raise exception 'A safe retry key is required.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('parts-price:'||auth.uid()::text||p_request_id::text,0));
 select *into saved from greenloop_private.parts_pricing_commands where user_id=auth.uid()and request_id=p_request_id;
 if found then if saved.action<>'price'or saved.command<>command then raise exception 'This retry key belongs to a different pricing action.'using errcode='22023';end if;return saved.response;end if;
 if p_unit_price is null or p_unit_price<0 or p_unit_price>9999999999.99 or p_unit_price<>round(p_unit_price,2)or p_unit_price::text in('NaN','Infinity','-Infinity')then raise exception 'Enter a non-negative price per part with at most two decimal places.'using errcode='22023';end if;
 if p_source is null or p_source not in('local','china')then raise exception 'Choose Local or China before saving the price.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(19920261026);report:=greenloop_private.ppp_report(p_filters,p_group);select value into g from jsonb_array_elements(report->'rows')where value->>'group_id'=p_group;
 if g is null or g->>'selection_token'is distinct from p_selection_token then raise exception 'The pending issue group changed. Refresh and review it before saving. No prices were changed.'using errcode='40001';end if;
 if g->>'source'<>'unrecorded'and g->>'source'<>p_source then raise exception 'Use phone details to assign a different source before saving its price.'using errcode='22023';end if;
 select array_agg((value->>'issue_id')::uuid)into ids from jsonb_array_elements(report->'details');
 if cardinality(ids)not between 1 and 5000 then raise exception 'Select a pending group of 1 to 5000 issue records.'using errcode='22023';end if;
 perform 1 from public.part_issue_transactions where id=any(ids)order by id for update;
 perform 1 from greenloop_private.parts_flow_prices where issue_id=any(ids)order by issue_id for update;
 if(report#>'{details}')is distinct from(greenloop_private.ppp_report(p_filters,p_group)->'details')then raise exception 'The issue details changed. Refresh before saving.'using errcode='40001';end if;
 for u in select value from jsonb_array_elements(report->'details')loop
  perform greenloop_private.ppp_record_source((u->>'issue_id')::uuid,p_source);
  insert into greenloop_private.parts_flow_prices(issue_id,order_id,unit_price,currency)values((u->>'issue_id')::uuid,(u->>'order_id')::uuid,p_unit_price,u->>'currency')on conflict(issue_id)do update set unit_price=excluded.unit_price,recorded_at=now()where parts_flow_prices.unit_price is null;
  get diagnostics n=row_count;if n<>1 then raise exception 'An issue already has a price. No prices were changed.'using errcode='40001';end if;
 end loop;
 result:=jsonb_build_object('request_id',p_request_id,'priced_issues',cardinality(ids),'phones',(g->>'phones')::integer,'quantity',(g->>'quantity')::integer,'unit_price',p_unit_price,'total_value',p_unit_price*(g->>'quantity')::integer,'source',p_source,'currency',g->>'currency','issues',report->'details');
 insert into greenloop_private.parts_pricing_commands(user_id,request_id,action,command,response)values(auth.uid(),p_request_id,'price',command,result);return result;
end;$$;
create or replace function public.assign_pending_parts_source_v1(p_group text,p_filters jsonb,p_selection_token text,p_issue_ids uuid[],p_source text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$
declare command jsonb:=jsonb_build_object('group',p_group,'filters',p_filters,'selection_token',p_selection_token,'issue_ids',p_issue_ids,'source',p_source);saved greenloop_private.parts_pricing_commands%rowtype;report jsonb;g jsonb;i uuid;result jsonb;
begin
 perform greenloop_private.ppp_access(true);if p_request_id is null or p_source is null or p_source not in('local','china')or cardinality(p_issue_ids)is null or cardinality(p_issue_ids)not between 1 and 5000 then raise exception 'Select issue records and choose Local or China.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('parts-price:'||auth.uid()::text||p_request_id::text,0));select *into saved from greenloop_private.parts_pricing_commands where user_id=auth.uid()and request_id=p_request_id;
 if found then if saved.action<>'source'or saved.command<>command then raise exception 'This retry key belongs to a different source action.'using errcode='22023';end if;return saved.response;end if;
 perform pg_advisory_xact_lock(19920261026);report:=greenloop_private.ppp_report(p_filters,p_group);select value into g from jsonb_array_elements(report->'rows')where value->>'group_id'=p_group;
 if g is null or g->>'selection_token'is distinct from p_selection_token then raise exception 'The pending issue group changed. Refresh before setting the source.'using errcode='40001';end if;
 if(select count(distinct x)from unnest(p_issue_ids)x)<>cardinality(p_issue_ids)or exists(select 1 from unnest(p_issue_ids)x where x is null or not exists(select 1 from jsonb_array_elements(report->'details')u where u->>'issue_id'=x::text))then raise exception 'Choose only issue records in the reviewed group.'using errcode='22023';end if;
 perform 1 from public.part_issue_transactions where id=any(p_issue_ids)order by id for update;
 for i in select x from unnest(p_issue_ids)x order by x loop perform greenloop_private.ppp_record_source(i,p_source);end loop;
 result:=jsonb_build_object('request_id',p_request_id,'assigned_issues',cardinality(p_issue_ids),'source',p_source,'issue_ids',p_issue_ids);
 insert into greenloop_private.parts_pricing_commands(user_id,request_id,action,command,response)values(auth.uid(),p_request_id,'source',command,result);return result;
end;$$;
-- Compatible wrappers capture an optional source without changing the old issuers.
create or replace function public.issue_parts_with_source_v1(p_order_id uuid,p_revision integer,p_request_id uuid,p_quantity integer,p_unit_price numeric default null,p_stock_id uuid default null,p_source text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.ppp_access(true);if p_source is not null and p_source not in('local','china')then raise exception 'Choose Local or China, or leave the source unrecorded.'using errcode='22023';end if;
 result:=public.issue_parts_flow_v1(p_order_id,p_revision,p_request_id,p_quantity,p_unit_price,p_stock_id);if p_source is not null then perform greenloop_private.ppp_record_source((result->>'issue_id')::uuid,p_source);end if;return result;
end;$$;
create or replace function public.issue_parts_picking_with_source_v1(p_lines jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare cleaned jsonb;result jsonb;u jsonb;source text;begin
 perform greenloop_private.ppp_access(true);if jsonb_typeof(p_lines)is distinct from 'array'or exists(select 1 from jsonb_array_elements(p_lines)x where x?'part_source'and x->>'part_source'is not null and x->>'part_source'not in('local','china'))then raise exception 'Choose Local or China for the supplied part source.'using errcode='22023';end if;
 select jsonb_agg(value-'part_source'order by ordinality)into cleaned from jsonb_array_elements(p_lines)with ordinality;result:=public.issue_parts_picking_v1(cleaned);
 for u in select value from jsonb_array_elements(result->'results')loop select value->>'part_source'into source from jsonb_array_elements(p_lines)where value->>'request_id'=u->>'request_id';if source is not null then perform greenloop_private.ppp_record_source((u->>'issue_id')::uuid,source);end if;end loop;return result;
end;$$;
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_pending_parts_prices_v1','save_pending_parts_prices_v1','assign_pending_parts_source_v1','issue_parts_with_source_v1','issue_parts_picking_with_source_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select string_agg('$'||i,','order by i)into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql %s security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
do $$declare f record;begin for f in select oid::regprocedure sig from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'ppp_%'loop execute format('revoke all on function %s from public,anon,authenticated',f.sig);end loop;end;$$;
create table if not exists greenloop_private.pending_parts_prices_installation(identity text primary key,hash text not null);alter table greenloop_private.pending_parts_prices_installation enable row level security;revoke all on greenloop_private.pending_parts_prices_installation from public,anon,authenticated;
create or replace function public.get_pending_parts_prices_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_lab_bulk_transfer_version()='20261030-lab-bulk-transfer-1'
 and(select count(*)=18 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.pending_parts_prices_installation)
 and not exists(select 1 from greenloop_private.pending_parts_prices_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from unnest(array['public.get_pending_parts_prices_v1(jsonb,text)','public.save_pending_parts_prices_v1(text,jsonb,text,numeric,text,uuid)','public.assign_pending_parts_source_v1(text,jsonb,text,uuid[],text,uuid)','public.issue_parts_with_source_v1(uuid,integer,uuid,integer,numeric,uuid,text)','public.issue_parts_picking_with_source_v1(jsonb)'])f where has_function_privilege('anon',to_regprocedure(f),'EXECUTE')or not has_function_privilege('authenticated',to_regprocedure(f),'EXECUTE'))
 and not exists(select 1 from unnest(array['greenloop_private.parts_issue_sources','greenloop_private.parts_pricing_commands','greenloop_private.pending_parts_prices_installation'])t where not exists(select 1 from pg_class where oid=to_regclass(t)and relrowsecurity)or has_table_privilege('anon',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')or has_table_privilege('authenticated',to_regclass(t),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and(select count(*)=2 from pg_trigger where tgname='ppp_immutable'and tgenabled='O'and tgrelid in('greenloop_private.parts_issue_sources'::regclass,'greenloop_private.parts_pricing_commands'::regclass))then '20261030-pending-parts-prices-1'end;$$;
revoke all on function public.get_pending_parts_prices_version()from public;grant execute on function public.get_pending_parts_prices_version()to anon,authenticated;
insert into greenloop_private.pending_parts_prices_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname like 'ppp_%'or p.pronamespace='public'::regnamespace and p.proname in('get_pending_parts_prices_version','get_pending_parts_prices_v1','save_pending_parts_prices_v1','assign_pending_parts_source_v1','issue_parts_with_source_v1','issue_parts_picking_with_source_v1')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_pending_parts_prices_v1(jsonb,text)'::regprocedure,'public.save_pending_parts_prices_v1(text,jsonb,text,numeric,text,uuid)'::regprocedure,'public.assign_pending_parts_source_v1(text,jsonb,text,uuid[],text,uuid)'::regprocedure,'public.issue_parts_with_source_v1(uuid,integer,uuid,integer,numeric,uuid,text)'::regprocedure,'public.issue_parts_picking_with_source_v1(jsonb)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_pending_parts_prices_version()is distinct from '20261030-pending-parts-prices-1'then raise exception 'Pending Parts Prices verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_pending_parts_prices_version()as installed_pending_parts_prices_version;
