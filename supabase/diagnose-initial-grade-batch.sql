-- Read-only; run in the project's Supabase SQL Editor after SQL313.
-- This reports actual records; it does not fill, reset or change grades.
with target as(select id from public.receiving_batches where batch_number='BATCH-2026-0004')
select p.current_status,p.grade_source,p.grade_issue,count(*)phones
from target t cross join lateral greenloop_private.sgc_rows(jsonb_build_object('batch_id',t.id))p
group by p.current_status,p.grade_source,p.grade_issue order by p.current_status,p.grade_source;
with target as(select id from public.receiving_batches where batch_number='BATCH-2026-0004')
select d.imei_1 imei,p.model,d.storage_gb,d.color,p.grade initial_qc_gl_grade,p.grade_source,
p.qc_waiting initial_qc_pending,p.grade_missing,p.qc_record_missing,p.current_status,p.grade_issue
from target t cross join lateral greenloop_private.sgc_rows(jsonb_build_object('batch_id',t.id))p
join public.devices d on d.id=p.device_id order by p.qc_pending desc,d.imei_1;
