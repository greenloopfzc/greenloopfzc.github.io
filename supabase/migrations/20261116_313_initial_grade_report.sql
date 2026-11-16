-- Initial QC report: canonical saved grade evidence and separate missing-data categories.
DO $initial_grade_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_grade_phone_details_version()is distinct from '20261113-grade-phone-details-1'or public.get_stock_units_version()is distinct from '20261113-stock-units-1'then raise exception 'Verify Grade Phone Details and original Stock Units first.';end if;if to_regprocedure('public.get_initial_grade_report_version()')is not null then if public.get_initial_grade_report_version()is distinct from '20261116-initial-grade-report-1'then raise exception 'Existing Initial Grade Report integrity needs review.';end if;end if;end;$$;
create or replace function greenloop_private.sgc_rows(f jsonb)returns table(batch_id uuid,device_id uuid,model text,grade text,qc_pending boolean,glass boolean,polish boolean,returned boolean,job_id uuid,qc_waiting boolean,grade_missing boolean,qc_record_missing boolean,grade_source text,grade_issue text,saved_grade_used boolean,current_status text)language sql stable security definer set search_path=pg_catalog,public as $$
 with phones as materialized(
 select distinct on(j.receiving_batch_id,j.device_id)j.id job_id,j.device_id,j.receiving_batch_id batch_id,j.current_status::text current_status,d.imei_1,coalesce(nullif(btrim(d.model),''),'Not recorded')model,nullif(regexp_replace(upper(btrim(d.gc_grade)),'^GRADE\s+','','i'),'')current_grade
 from public.jobs j join public.devices d on d.id=j.device_id and d.deleted_at is null join public.receiving_batches b on b.id=j.receiving_batch_id
 where j.deleted_at is null and not exists(select 1 from greenloop_private.srp_phone_links replacement where replacement.replacement_job_id=j.id) /* su-original-grade-units */ and(nullif(f->>'supplier_id','')is null or b.supplier_id=(f->>'supplier_id')::uuid)and(nullif(f->>'batch_id','')is null or b.id=(f->>'batch_id')::uuid)and(nullif(f->>'invoice_number','')is null or b.invoice_number=f->>'invoice_number')
 order by j.receiving_batch_id,j.device_id,j.received_at desc,j.created_at desc,j.id desc
 ),inspected as materialized(
 select p.*,q.id inspection_id,q.inspected_at,q.created_at qc_recorded_at from phones p left join lateral(select z.id,z.inspected_at,z.created_at from public.initial_qc_inspections z where z.job_id=p.job_id and z.device_id=p.device_id order by z.inspected_at desc,z.created_at desc,z.id desc limit 1)q on true
 ),needed as materialized(select *from inspected where current_grade is null and inspection_id is not null),bulk_records as materialized(
 select b.changed_at,b.request_id,x from greenloop_private.bulk_imei_audit b cross join lateral jsonb_array_elements(b.changes)x where b.changed_at>=(select min(qc_recorded_at)from needed)and x->'after'?'gl_grade'and x->'before'->'gl_grade'is distinct from x->'after'->'gl_grade'
 ),evidence as materialized(
 select p.device_id,p.job_id,e.created_at at,1 priority,e.id::text id,case when e.event_data?'gl_grade'then e.event_data->'gl_grade'else e.event_data->'gc_grade'end value,'Saved Initial QC'::text source
 from needed p join public.device_events e on e.device_id=p.device_id and e.job_id=p.job_id and e.event_data->>'inspection_id'=p.inspection_id::text where e.event_type in('initial_qc_saved','initial_qc_resaved','initial_qc_completed')and(e.event_data?'gl_grade'or e.event_data?'gc_grade')
 union all
 select p.device_id,p.job_id,h.changed_at,2,h.id::text,case when h.changed_fields?'gc_grade'then h.changed_fields->'gc_grade'->'new'else h.changed_fields->'initial_grade'->'new'end,'Reports GL Grade'
 from needed p join public.data_change_history h on h.device_id=p.device_id and(h.job_id is null or h.job_id=p.job_id)and h.changed_at>=p.qc_recorded_at where(h.changed_fields->'gc_grade'?'new'or h.changed_fields->'initial_grade'?'new')
 union all
 select p.device_id,p.job_id,w.changed_at,2,w.id::text,x->'after'->'gc_grade','Reports GL Grade'
 from needed p join greenloop_private.workflow_correction_audit w on w.device_id=p.device_id and w.changed_at>=p.qc_recorded_at cross join lateral jsonb_array_elements(w.changes)x where x->>'kind'='device'and x->'after'?'gc_grade'and x->'before'->'gc_grade'is distinct from x->'after'->'gc_grade'
 union all
 select p.device_id,p.job_id,b.changed_at,2,b.request_id::text,b.x->'after'->'gl_grade','Reports GL Grade'
 from needed p join bulk_records b on b.changed_at>=p.qc_recorded_at and b.x->>'device_id'=p.device_id::text and b.x->>'job_id'=p.job_id::text
 ),resolved as materialized(
 select p.*,case when p.inspection_id is not null then coalesce(p.current_grade,case when jsonb_typeof(e.value)='string'then nullif(regexp_replace(upper(btrim(e.value#>>'{}')),'^GRADE\s+','','i'),'')end)end resolved_grade,
 case when p.inspection_id is null then 'Not recorded'when p.current_grade is not null then 'Current GL Grade'when jsonb_typeof(e.value)='string'and nullif(btrim(e.value#>>'{}'),'')is not null then e.source else 'Not recorded'end resolved_source,
 e.id evidence_id,e.source evidence_source,e.value evidence_value
 from inspected p left join lateral(select *from evidence e where e.device_id=p.device_id and e.job_id=p.job_id order by e.at desc,e.priority desc,e.id desc limit 1)e on true
 )select p.batch_id,p.device_id,p.model,p.resolved_grade,p.inspection_id is null or p.resolved_grade is null,
 exists(select 1 from public.initial_qc_findings z where z.inspection_id=p.inspection_id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly']))or exists(select 1 from public.initial_qc_part_requirements z where z.inspection_id=p.inspection_id and z.quantity_required>0 and z.status not in('not_required','cancelled')and greenloop_private.sga_key(z.part_name)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly'])),
 exists(select 1 from public.initial_qc_findings z where z.inspection_id=p.inspection_id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['polish','polishing','bodypolish','bodypolishing','framepolish','framepolishing','polishservice','polishingservice'])),
 p.current_status='returned_to_supplier'or exists(select 1 from public.supplier_returns z where z.archived_at is null and z.status='returned'and z.batch_id=p.batch_id and(z.device_id=p.device_id or z.job_id=p.job_id or z.device_id is null and z.imei_1=p.imei_1)),p.job_id,
 p.inspection_id is null and p.current_status in('received','initial_qc_pending'),p.inspection_id is not null and p.resolved_grade is null,p.inspection_id is null and p.current_status not in('received','initial_qc_pending'),p.resolved_source,
 case when p.inspection_id is null and p.current_status in('received','initial_qc_pending')then 'Initial QC not yet recorded'when p.inspection_id is null then 'Initial QC record not found for this job'when p.resolved_grade is null and p.evidence_source='Reports GL Grade'then 'GL Grade cleared in Reports'when p.resolved_grade is null then 'Initial QC completed without a recorded GL Grade'else ''end,
 p.current_grade is null and p.resolved_grade is not null,p.current_status from resolved p;
$$;
revoke all on function greenloop_private.sgc_rows(jsonb)from public,anon,authenticated;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;qc_sig text;begin
 select implementation into strict qc_sig from greenloop_private.office_routines where to_regprocedure(identity)='public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure;
 foreach sig in array array['greenloop_private.sga_rows(jsonb)','greenloop_private.sga_report(jsonb,boolean,text)','greenloop_private.sga_phone_details(jsonb,text,integer,text,text)',qc_sig]loop
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);
 if sig='greenloop_private.sga_rows(jsonb)'then execute $rows$
create or replace function greenloop_private.sga_rows(f jsonb)returns table(batch_id uuid,device_id uuid,model text,grade text,qc_pending boolean,glass boolean,polish boolean,returned boolean)language sql stable security definer set search_path=pg_catalog,public as $$select batch_id,device_id,model,grade,qc_pending,glass,polish,returned from greenloop_private.sgc_rows(f);$$;
$rows$;
 elsif sig='greenloop_private.sga_report(jsonb,boolean,text)'then execute $report$
CREATE OR REPLACE FUNCTION greenloop_private.sga_report(f jsonb, download boolean, expected text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare names boolean:=coalesce(public.get_my_partner_name_access(),false);catalogue jsonb;stocks jsonb;rows jsonb;totals jsonb;other jsonb;selected boolean;result jsonb;snapshot text;phone_snapshot text;
begin
 selected:=exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null);
 with b as(select b.id batch_id,b.supplier_id,b.batch_number,b.invoice_number,b.received_at,b.planned_quantity stock_quantity,coalesce(s.supplier_code,'Not recorded')supplier_code,case when names then s.company_name end supplier_name from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id where not exists(select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id))
 select jsonb_build_object('suppliers',coalesce((select jsonb_agg(to_jsonb(s)order by supplier_code,supplier_id)from(select distinct supplier_id,supplier_code,supplier_name from b where supplier_id is not null)s),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(b)order by received_at desc,batch_id)from b),'[]'))into catalogue;
 select coalesce(jsonb_agg(b order by b->>'batch_number'),'[]')into stocks from jsonb_array_elements(catalogue->'batches')b where selected and(nullif(f->>'supplier_id','')is null or b->>'supplier_id'=f->>'supplier_id')and(nullif(f->>'batch_id','')is null or b->>'batch_id'=f->>'batch_id')and(nullif(f->>'invoice_number','')is null or b->>'invoice_number'=f->>'invoice_number');
 if selected and jsonb_array_length(stocks)=0 then raise exception 'No stock matches this supplier, batch and invoice. Refresh the selection.'using errcode='22023';end if;
 if selected then
  with p as materialized(select *from greenloop_private.sgc_rows(f)),groups as(
   select p.model,count(*)qty,count(*)filter(where not qc_pending and grade='A')a,count(*)filter(where not qc_pending and grade='B')b,count(*)filter(where not qc_pending and grade='D')d,
    count(*)filter(where not qc_pending and grade not in('A','B','D'))other,count(*)filter(where qc_pending)pending,count(*)filter(where glass)glass,count(*)filter(where polish)polish,count(*)filter(where returned)returned,count(*)filter(where qc_waiting)qc_waiting,count(*)filter(where grade_missing)grade_missing,count(*)filter(where qc_record_missing)qc_record_missing,count(*)filter(where saved_grade_used)saved_grade_used
   from p group by p.model
  )select coalesce((select jsonb_agg(to_jsonb(g)order by model)from groups g),'[]'),jsonb_build_object('qty',count(*),'a',count(*)filter(where not qc_pending and grade='A'),'b',count(*)filter(where not qc_pending and grade='B'),'d',count(*)filter(where not qc_pending and grade='D'),'other',count(*)filter(where not qc_pending and grade not in('A','B','D')),'pending',count(*)filter(where qc_pending),'glass',count(*)filter(where glass),'polish',count(*)filter(where polish),'returned',count(*)filter(where returned),'qc_waiting',count(*)filter(where qc_waiting),'grade_missing',count(*)filter(where grade_missing),'qc_record_missing',count(*)filter(where qc_record_missing),'saved_grade_used',count(*)filter(where saved_grade_used)),
   coalesce((select jsonb_agg(to_jsonb(x)order by grade)from(select grade,count(*)qty from p where not qc_pending and grade not in('A','B','D')group by grade)x),'[]'),coalesce((select md5(jsonb_agg(to_jsonb(p)order by batch_id,device_id)::text)from p),md5('[]'))into rows,totals,other,phone_snapshot from p;
 else rows:='[]';totals:='{"qty":0,"a":0,"b":0,"d":0,"other":0,"pending":0,"qc_waiting":0,"grade_missing":0,"qc_record_missing":0,"saved_grade_used":0,"glass":0,"polish":0,"returned":0}';other:='[]';phone_snapshot:=md5('[]');end if;
 totals:=totals||jsonb_build_object('stock_quantity',coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0),'unentered',greatest(0,coalesce((select sum((s->>'stock_quantity')::bigint)from jsonb_array_elements(stocks)s),0)-(totals->>'qty')::bigint));
 result:=jsonb_build_object('grading_version','20261116-initial-grade-report-1','phone_snapshot',phone_snapshot,'receipt_summary',greenloop_private.sc_summary(array(select(s->>'batch_id')::uuid from jsonb_array_elements(stocks)s)),'selected',selected,'filters',f,'stocks',stocks,'rows',rows,'totals',totals,'other_grades',other,'names_allowed',names);
 snapshot:=md5(result::text);
 if download and(expected is null or expected is distinct from snapshot)then raise exception 'The stock analysis changed. Refresh it before creating the PDF.'using errcode='40001';end if;
 return result||jsonb_build_object('catalogue',catalogue,'snapshot',snapshot,'generated_at',now());
end;$function$
$report$;
 elsif sig='greenloop_private.sga_phone_details(jsonb,text,integer,text,text)'then execute $details$
CREATE OR REPLACE FUNCTION greenloop_private.sga_phone_details(f jsonb, metric text, start_row integer, analysis_snapshot text, detail_snapshot text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare summary jsonb;allrows jsonb;token text;expected_count integer;begin
 perform greenloop_private.require_office_network();
 if metric is null or metric<>all(array['qty','a','b','d','glass','polish','other','pending','returned','qc_waiting','grade_missing','qc_record_missing'])or start_row is null or start_row<0 or start_row%50<>0 then raise exception 'Choose a valid grade category and page.'using errcode='22023';end if;
 if analysis_snapshot is null or analysis_snapshot!~'^[0-9a-f]{32}$'or(detail_snapshot is not null and detail_snapshot!~'^[0-9a-f]{32}$')or(start_row>0 and detail_snapshot is null)then raise exception 'Refresh the stock analysis before opening these phones.'using errcode='22023';end if;
 -- Use the actual protected report reader, including its independent section-search grant.
 summary:=public.get_stock_grade_analysis_v1(coalesce(f,'{}'));
 if not(summary->>'selected')::boolean then raise exception 'Select supplier, stock / batch or invoice first.'using errcode='22023';end if;
 if summary->>'snapshot'is distinct from analysis_snapshot then raise exception 'The stock analysis changed. Refresh it before opening phone details.'using errcode='40001';end if;
 expected_count:=(summary->'totals'->>metric)::integer;
 with selected as materialized(
  select p.*from greenloop_private.sgc_rows(f)p where case metric when 'qty'then true when 'a'then not p.qc_pending and p.grade='A'when 'b'then not p.qc_pending and p.grade='B'when 'd'then not p.qc_pending and p.grade='D'when 'other'then not p.qc_pending and p.grade not in('A','B','D')when 'pending'then p.qc_pending when 'qc_waiting'then p.qc_waiting when 'grade_missing'then p.grade_missing when 'qc_record_missing'then p.qc_record_missing when 'glass'then p.glass when 'polish'then p.polish when 'returned'then p.returned else false end
 ),details as(
  select p.batch_id,p.device_id,d.imei_1 imei,p.model,d.storage_gb,d.color,d.battery_health,p.grade,p.qc_pending,p.glass,p.polish,p.returned,p.qc_waiting,p.grade_missing,p.qc_record_missing,p.grade_source,p.grade_issue,
   s->>'supplier_code'supplier_code,case when coalesce((summary->>'names_allowed')::boolean,false)then s->>'supplier_name'end supplier_name,
   (s->>'stock_quantity')::bigint receipt_quantity,s->>'batch_number'batch_number,s->>'invoice_number'invoice_number,s->>'received_at'received_at,j.current_status::text current_stage
  from selected p join public.devices d on d.id=p.device_id and d.deleted_at is null
  join public.jobs j on j.id=p.job_id and j.deleted_at is null
  join lateral(select value from jsonb_array_elements(summary->'stocks')where value->>'batch_id'=p.batch_id::text limit 1)stock(s)on true
 )select coalesce(jsonb_agg(to_jsonb(x)order by x.model,x.imei,x.batch_id,x.device_id),'[]')into allrows from details x;
 if jsonb_array_length(allrows)<>expected_count then raise exception 'The grade phone list does not match the analysis total. Refresh and retry.'using errcode='40001';end if;
 token:=md5(jsonb_build_object('filters',f,'metric',metric,'analysis',analysis_snapshot,'rows',allrows,'names_allowed',summary->'names_allowed')::text);
 if detail_snapshot is not null and detail_snapshot<>token then raise exception 'Phone details changed. Close this list and open its total again.'using errcode='40001';end if;
 return jsonb_build_object('grading_version','20261116-initial-grade-report-1','metric',metric,'total',expected_count,'offset',start_row,'analysis_snapshot',analysis_snapshot,'snapshot',token,'names_allowed',summary->'names_allowed','rows',coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(allrows)with ordinality a(r,n)where n>start_row and n<=start_row+50),'[]'));
end;$function$
$details$;
 else
 if not exists(select 1 from greenloop_private.office_routines where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash and wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity))))then raise exception 'Initial QC save integrity differs. Review before installing.';end if;
 if position('sgc-stock-grade-required'in old)=0 then
 updated:=regexp_replace(old,$boundary$(if\s+dev\s+is\s+null\s+then\s+raise\s+exception\s+'This phone is not waiting for Initial QC\.'[\s\S]*?end\s+if;)$boundary$,$guard$\1
  -- sgc-stock-grade-required: a new company-stock inspection needs its actual GL grade.
  if gl is null and exists(select 1 from public.jobs j where j.id=p_job_id and j.ownership_type::text='company_owned'and j.receiving_batch_id is not null)then raise exception 'Choose a GL Grade before saving this stock phone for issuance.'using errcode='22023';end if;
$guard$);
 if updated=old or position('sgc-stock-grade-required'in updated)=0 then raise exception 'Initial QC save boundary changed. Review before installing.';end if;execute updated;
 end if;
 end if;
 -- Reseal only the matching previously verified function receipts.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;end;$patch$;
revoke all on function greenloop_private.sga_rows(jsonb),greenloop_private.sga_report(jsonb,boolean,text),greenloop_private.sga_phone_details(jsonb,text,integer,text,text)from public,anon,authenticated;
insert into greenloop_private.capability_rpc_rules values('get_initial_grade_report_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.initial_grade_report_installation(identity text primary key,hash text not null);alter table greenloop_private.initial_grade_report_installation enable row level security;revoke all on greenloop_private.initial_grade_report_installation from public,anon,authenticated;
create or replace function public.get_initial_grade_report_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_grade_phone_details_version()='20261113-grade-phone-details-1'and public.get_stock_units_version()='20261113-stock-units-1'and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.initial_grade_report_installation)and not exists(select 1 from greenloop_private.initial_grade_report_installation i where i.identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))and exists(select 1 from pg_class where oid='greenloop_private.initial_grade_report_installation'::regclass and relrowsecurity)and not has_table_privilege('authenticated','greenloop_private.initial_grade_report_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261116-initial-grade-report-1'end;$$;
revoke all on function public.get_initial_grade_report_version()from public;grant execute on function public.get_initial_grade_report_version()to anon,authenticated;
insert into greenloop_private.initial_grade_report_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.sgc_rows(jsonb)','greenloop_private.sga_rows(jsonb)','greenloop_private.sga_report(jsonb,boolean,text)','greenloop_private.sga_phone_details(jsonb,text,integer,text,text)','public.get_initial_grade_report_version()',(select implementation from greenloop_private.office_routines where to_regprocedure(identity)='public.save_initial_qc_inspection_v1(uuid,jsonb,jsonb,text,text,text,uuid)'::regprocedure)])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_initial_grade_report_version()is distinct from '20261116-initial-grade-report-1'then raise exception 'Initial Grade Report verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$initial_grade_install$;
select public.get_initial_grade_report_version()as installed_initial_grade_report_version,
(select jsonb_build_object('batch',b.batch_number,'entered',count(*),'initial_qc_pending',count(*)filter(where p.qc_waiting),'grade_missing_after_qc',count(*)filter(where p.grade_missing),'qc_record_missing',count(*)filter(where p.qc_record_missing),'saved_grades_used',count(*)filter(where p.saved_grade_used))from public.receiving_batches b cross join lateral greenloop_private.sgc_rows(jsonb_build_object('batch_id',b.id))p where b.batch_number='BATCH-2026-0004'group by b.id,b.batch_number limit 1)as batch_95_check;
