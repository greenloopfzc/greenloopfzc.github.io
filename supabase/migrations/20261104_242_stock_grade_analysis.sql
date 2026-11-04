-- Initial QC grade and required Glass / Polish analysis. Read-only business data.
begin;
do $$begin
 if public.get_stock_replacement_version()is distinct from '20261104-stock-replacement-1'then raise exception 'Install and verify Stock Replacement first.';end if;
 if to_regprocedure('public.get_stock_grade_analysis_version()')is not null then if public.get_stock_grade_analysis_version()is distinct from '20261104-stock-grade-analysis-1'then raise exception 'Existing Stock Grade Analysis requires review.';end if;end if;
end;$$;
do $$declare u record;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @> '[{"key":"stock_grade_analysis"}]')then
  for u in select id,greenloop_private.user_capabilities(id)caps from public.user_profiles loop insert into greenloop_private.user_page_capabilities(user_id,capabilities)values(u.id,u.caps)on conflict(user_id)do nothing;end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"stock_grade_analysis","label":"View Stock Grade & Work Analysis","write":false},{"key":"stock_grade_download","label":"Stock Grade Analysis: PDF View / Download","write":false}]'where page_key='reports';
  update greenloop_private.user_page_capabilities c set capabilities=jsonb_set(capabilities,'{reports}',(capabilities->'reports')||'["stock_grade_analysis","stock_grade_download"]')where capabilities->'reports'?'view'and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=c.user_id and r.role_key::text in('owner','super_admin'));
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';

create or replace function greenloop_private.sga_key(v text)returns text language sql immutable set search_path=pg_catalog as $$select regexp_replace(lower(coalesce(btrim(v),'')),'[^a-z0-9]','','g');$$;
create or replace function greenloop_private.sga_access(f jsonb,download boolean)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('reports','view');perform greenloop_private.pf_cap('reports','stock_grade_analysis');
 if download then perform greenloop_private.pf_cap('reports','stock_grade_download');end if;
 if jsonb_typeof(f)is distinct from 'object'or exists(select 1 from jsonb_each(f)e where e.key<>all(array['supplier_id','batch_id','invoice_number'])or jsonb_typeof(e.value)not in('string','null')or length(e.value#>>'{}')>200)then raise exception 'Choose valid supplier, batch or invoice filters.'using errcode='22023';end if;
 if f<>'{}'then perform greenloop_private.pf_cap('reports','search');end if;
 if nullif(f->>'supplier_id','')is not null then perform(f->>'supplier_id')::uuid;end if;
 if nullif(f->>'batch_id','')is not null then perform(f->>'batch_id')::uuid;end if;
 if download and not exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null)then raise exception 'Select stock before creating its PDF.'using errcode='22023';end if;
end;$$;
create or replace function greenloop_private.sga_rows(f jsonb)returns table(batch_id uuid,device_id uuid,model text,grade text,qc_pending boolean,glass boolean,polish boolean,returned boolean)language sql stable security definer set search_path=pg_catalog,public as $$
 with phones as materialized(
  select distinct on(j.receiving_batch_id,j.device_id)j.id job_id,j.device_id,j.receiving_batch_id batch_id,j.current_status,d.imei_1,coalesce(nullif(btrim(d.model),''),'Not recorded')model,
   nullif(regexp_replace(upper(btrim(d.gc_grade)),'^GRADE\s+','','i'),'')grade
  from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null join public.receiving_batches b on b.id=j.receiving_batch_id
  where j.deleted_at is null and(nullif(f->>'supplier_id','')is null or b.supplier_id=(f->>'supplier_id')::uuid)and(nullif(f->>'batch_id','')is null or b.id=(f->>'batch_id')::uuid)and(nullif(f->>'invoice_number','')is null or b.invoice_number=f->>'invoice_number')
  order by j.receiving_batch_id,j.device_id,j.received_at desc,j.created_at desc,j.id desc
 )select p.batch_id,p.device_id,p.model,case when q.id is not null then p.grade end,q.id is null or p.grade is null,
  exists(select 1 from public.initial_qc_findings z where z.inspection_id=q.id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly']))
   or exists(select 1 from public.initial_qc_part_requirements z where z.inspection_id=q.id and z.quantity_required>0 and z.status<>'not_required'and greenloop_private.sga_key(z.part_name)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly'])),
  exists(select 1 from public.initial_qc_findings z where z.inspection_id=q.id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['polish','polishing','bodypolish','bodypolishing','framepolish','framepolishing','polishservice','polishingservice'])),
  p.current_status::text='returned_to_supplier'or exists(select 1 from public.supplier_returns r where r.archived_at is null and r.status='returned'and r.batch_id=p.batch_id and(r.device_id=p.device_id or r.job_id=p.job_id or r.device_id is null and r.imei_1=p.imei_1))
 from phones p left join lateral(
  select z.id from public.initial_qc_inspections z join public.jobs j on j.id=z.job_id where z.device_id=p.device_id and j.receiving_batch_id=p.batch_id and j.deleted_at is null order by z.inspected_at desc,z.created_at desc,z.id desc limit 1
 )q on true;
$$;
create or replace function greenloop_private.sga_report(f jsonb,download boolean,expected text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);catalogue jsonb;stocks jsonb;rows jsonb;totals jsonb;other jsonb;selected boolean;result jsonb;snapshot text;
begin
 selected:=exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null);
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity stock_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id)
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by received_at desc,batch_id)from b),'[]'))into catalogue;
 select coalesce(jsonb_agg(b order by b->>'batch_number'),'[]')into stocks from jsonb_array_elements(catalogue->'batches')b where selected and(nullif(f->>'supplier_id','')is null or b->>'supplier_id'=f->>'supplier_id')and(nullif(f->>'batch_id','')is null or b->>'batch_id'=f->>'batch_id')and(nullif(f->>'invoice_number','')is null or b->>'invoice_number'=f->>'invoice_number');
 if selected and jsonb_array_length(stocks)=0 then raise exception 'No stock matches this supplier, batch and invoice. Refresh the selection.'using errcode='22023';end if;
 if selected then
  with p as materialized(select *from greenloop_private.sga_rows(f)),groups as(
   select p.model,count(*)qty,count(*)filter(where not qc_pending and grade='A')a,count(*)filter(where not qc_pending and grade='B')b,count(*)filter(where not qc_pending and grade='D')d,
    count(*)filter(where not qc_pending and grade not in('A','B','D'))other,count(*)filter(where qc_pending)pending,count(*)filter(where glass)glass,count(*)filter(where polish)polish,count(*)filter(where returned)returned
   from p group by p.model
  )select coalesce((select jsonb_agg(to_jsonb(g)order by model)from groups g),'[]'),jsonb_build_object('qty',count(*),'a',count(*)filter(where not qc_pending and grade='A'),'b',count(*)filter(where not qc_pending and grade='B'),'d',count(*)filter(where not qc_pending and grade='D'),'other',count(*)filter(where not qc_pending and grade not in('A','B','D')),'pending',count(*)filter(where qc_pending),'glass',count(*)filter(where glass),'polish',count(*)filter(where polish),'returned',count(*)filter(where returned)),
   coalesce((select jsonb_agg(to_jsonb(x)order by grade)from(select grade,count(*)qty from p where not qc_pending and grade not in('A','B','D')group by grade)x),'[]')into rows,totals,other from p;
 else rows:='[]';totals:='{"qty":0,"a":0,"b":0,"d":0,"other":0,"pending":0,"glass":0,"polish":0,"returned":0}';other:='[]';end if;
 totals:=totals||jsonb_build_object('stock_quantity',coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0),'unentered',greatest(0,coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0)-(totals->>'qty')::bigint));
 result:=jsonb_build_object('selected',selected,'filters',f,'stocks',stocks,'rows',rows,'totals',totals,'other_grades',other,'names_allowed',names);
 snapshot:=md5(result::text);
 if download and(expected is null or expected is distinct from snapshot)then raise exception 'The stock analysis changed. Refresh it before creating the PDF.'using errcode='40001';end if;
 return result||jsonb_build_object('catalogue',catalogue,'snapshot',snapshot,'generated_at',now());
end;$$;
create or replace function public.get_stock_grade_analysis_v1(p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.sga_access(coalesce(p_filters,'{}'),false);return greenloop_private.sga_report(coalesce(p_filters,'{}'),false,null);end;$$;
create or replace function public.export_stock_grade_analysis_v1(p_filters jsonb default '{}',p_expected_snapshot text default null)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin perform greenloop_private.sga_access(coalesce(p_filters,'{}'),true);return greenloop_private.sga_report(coalesce(p_filters,'{}'),true,p_expected_snapshot);end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_stock_grade_analysis_v1','{"all":[{"page":"reports","capability":"view"},{"page":"reports","capability":"stock_grade_analysis"}],"read":true}'),
 ('export_stock_grade_analysis_v1','{"all":[{"page":"reports","capability":"view"},{"page":"reports","capability":"stock_grade_analysis"},{"page":"reports","capability":"stock_grade_download"}],"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;sig text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_stock_grade_analysis_v1','export_stock_grade_analysis_v1')loop
  impl:='office_impl_'||f.oid;sig:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute replace(f.ddl,'FUNCTION public.'||f.proname||'(','FUNCTION greenloop_private.'||impl||'(');execute format('revoke all on function %s from public,anon,authenticated',sig);
  select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';
  execute format('create or replace function public.%I(%s)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set lock_timeout=''5s'' set statement_timeout=''120s'' as %L',f.proname,pg_get_function_arguments(f.oid),body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
  insert into greenloop_private.office_routines values(f.signature,sig,md5(pg_get_functiondef(sig::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
revoke all on function greenloop_private.sga_key(text),greenloop_private.sga_access(jsonb,boolean),greenloop_private.sga_rows(jsonb),greenloop_private.sga_report(jsonb,boolean,text)from public,anon,authenticated;
create table if not exists greenloop_private.sga_installation(identity text primary key,hash text not null);alter table greenloop_private.sga_installation enable row level security;revoke all on greenloop_private.sga_installation from public,anon,authenticated;
create or replace function public.get_stock_grade_analysis_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_stock_replacement_version()='20261104-stock-replacement-1'
 and(select count(*)=9 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.sga_installation)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports'and capabilities @> '[{"key":"stock_grade_analysis","write":false},{"key":"stock_grade_download","write":false}]')
 and exists(select 1 from pg_class where oid='greenloop_private.sga_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.sga_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.sga_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.sga_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from greenloop_private.sga_installation i join pg_proc p on p.oid=to_regprocedure(i.identity)where p.pronamespace='public'::regnamespace and p.proname<>'get_stock_grade_analysis_version'and(has_function_privilege('anon',p.oid,'EXECUTE')or not has_function_privilege('authenticated',p.oid,'EXECUTE')))
 then '20261104-stock-grade-analysis-1'end;$$;
revoke all on function public.get_stock_grade_analysis_version()from public;grant execute on function public.get_stock_grade_analysis_version()to anon,authenticated;
insert into greenloop_private.sga_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname in('sga_key','sga_access','sga_rows','sga_report')or p.pronamespace='public'::regnamespace and p.proname in('get_stock_grade_analysis_v1','export_stock_grade_analysis_v1','get_stock_grade_analysis_version')or p.oid in(select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_stock_grade_analysis_v1(jsonb)'::regprocedure,'public.export_stock_grade_analysis_v1(jsonb,text)'::regprocedure))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_stock_grade_analysis_version()is distinct from '20261104-stock-grade-analysis-1'then raise exception 'Stock Grade Analysis verification failed. Changes rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_stock_grade_analysis_version()as installed_stock_grade_analysis_version;
