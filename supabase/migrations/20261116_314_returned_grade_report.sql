-- Returned supplier phones remain historical stock; never actionable QC exceptions.
DO $returned_grade_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_initial_grade_report_version()is distinct from '20261116-initial-grade-report-1'then raise exception 'Install and verify Initial Grade Report first.';end if;
if to_regprocedure('public.get_returned_grade_report_version()')is not null then if public.get_returned_grade_report_version()is distinct from '20261116-returned-grade-report-1'then raise exception 'Existing Returned Grade Report integrity needs review.';end if;end if;end;$$;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;begin
foreach sig in array array['greenloop_private.sgc_rows(jsonb)','greenloop_private.sga_report(jsonb,boolean,text)','greenloop_private.sga_phone_details(jsonb,text,integer,text,text)']loop
old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);
if sig='greenloop_private.sgc_rows(jsonb)'then execute $rows$
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
 ),classified as materialized(select p.*,(p.current_status='returned_to_supplier'or exists(select 1 from public.supplier_returns z where z.archived_at is null and z.status='returned'and z.batch_id=p.batch_id and(z.device_id=p.device_id or z.job_id=p.job_id or z.device_id is null and z.imei_1=p.imei_1)))was_returned from resolved p)select p.batch_id,p.device_id,p.model,p.resolved_grade,not p.was_returned and(p.inspection_id is null or p.resolved_grade is null),
 exists(select 1 from public.initial_qc_findings z where z.inspection_id=p.inspection_id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly']))or exists(select 1 from public.initial_qc_part_requirements z where z.inspection_id=p.inspection_id and z.quantity_required>0 and z.status not in('not_required','cancelled')and greenloop_private.sga_key(z.part_name)=any(array['glass','frontglass','screenglass','glassreplacement','frontglassreplacement','glasschange','glassonly'])),
 exists(select 1 from public.initial_qc_findings z where z.inspection_id=p.inspection_id and z.issue_found and greenloop_private.sga_key(z.check_item)=any(array['polish','polishing','bodypolish','bodypolishing','framepolish','framepolishing','polishservice','polishingservice'])),
 p.was_returned,p.job_id,
 not p.was_returned and p.inspection_id is null and p.current_status in('received','initial_qc_pending'),not p.was_returned and p.inspection_id is not null and p.resolved_grade is null,not p.was_returned and p.inspection_id is null and p.current_status not in('received','initial_qc_pending'),p.resolved_source,
 case when p.was_returned and p.inspection_id is null then 'Returned to supplier; Initial QC was not recorded'when p.was_returned and p.resolved_grade is null then 'Returned to supplier; GL Grade was not recorded'when p.inspection_id is null and p.current_status in('received','initial_qc_pending')then 'Initial QC not yet recorded'when p.inspection_id is null then 'Initial QC record not found for this job'when p.resolved_grade is null and p.evidence_source='Reports GL Grade'then 'GL Grade cleared in Reports'when p.resolved_grade is null then 'Initial QC completed without a recorded GL Grade'else ''end,
 p.current_grade is null and p.resolved_grade is not null,p.current_status from classified p;
$$;
$rows$;
else
updated:=old;
if sig='greenloop_private.sga_report(jsonb,boolean,text)'and position('returned_ungraded'in old)=0 then
 if position('count(*)filter(where saved_grade_used)saved_grade_used'in old)=0 or position('''saved_grade_used'',count(*)filter(where saved_grade_used)'in old)=0 or position('"saved_grade_used":0'in old)=0 then raise exception 'Grade report boundary changed; review before installing.';end if;
 updated:=replace(updated,'count(*)filter(where saved_grade_used)saved_grade_used','count(*)filter(where saved_grade_used)saved_grade_used,count(*)filter(where returned and grade is null)returned_ungraded');
 updated:=replace(updated,'''saved_grade_used'',count(*)filter(where saved_grade_used)','''saved_grade_used'',count(*)filter(where saved_grade_used),''returned_ungraded'',count(*)filter(where returned and grade is null)');
 updated:=replace(updated,'"saved_grade_used":0','"saved_grade_used":0,"returned_ungraded":0');
end if;
if position('''grading_version'',''20261116-initial-grade-report-1'''in updated)=0 and position('''grading_version'',''20261116-returned-grade-report-1'''in updated)=0 then raise exception 'Grade reader version boundary changed; review before installing.';end if;
updated:=replace(updated,'''grading_version'',''20261116-initial-grade-report-1''','''grading_version'',''20261116-returned-grade-report-1''');
if sig='greenloop_private.sga_report(jsonb,boolean,text)'and position('returned_ungraded'in updated)=0 then raise exception 'Returned grade totals were not applied.';end if;
execute updated;
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
revoke all on function greenloop_private.sgc_rows(jsonb),greenloop_private.sga_report(jsonb,boolean,text),greenloop_private.sga_phone_details(jsonb,text,integer,text,text)from public,anon,authenticated;
insert into greenloop_private.capability_rpc_rules values('get_returned_grade_report_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.returned_grade_report_installation(identity text primary key,hash text not null);alter table greenloop_private.returned_grade_report_installation enable row level security;revoke all on greenloop_private.returned_grade_report_installation from public,anon,authenticated;
create or replace function public.get_returned_grade_report_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_initial_grade_report_version()='20261116-initial-grade-report-1'and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.returned_grade_report_installation)and not exists(select 1 from greenloop_private.returned_grade_report_installation i where i.identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))and exists(select 1 from pg_class where oid='greenloop_private.returned_grade_report_installation'::regclass and relrowsecurity)and not has_table_privilege('authenticated','greenloop_private.returned_grade_report_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261116-returned-grade-report-1'end;$$;
revoke all on function public.get_returned_grade_report_version()from public;grant execute on function public.get_returned_grade_report_version()to anon,authenticated;
insert into greenloop_private.returned_grade_report_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.sgc_rows(jsonb)','greenloop_private.sga_report(jsonb,boolean,text)','greenloop_private.sga_phone_details(jsonb,text,integer,text,text)','public.get_returned_grade_report_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_returned_grade_report_version()is distinct from '20261116-returned-grade-report-1'then raise exception 'Returned Grade Report verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$returned_grade_install$;
select public.get_returned_grade_report_version()as installed_returned_grade_report_version;
