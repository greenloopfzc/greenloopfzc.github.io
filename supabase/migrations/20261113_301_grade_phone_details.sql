-- Read-only phone lists behind the grade-analysis TOTAL cells. Atomic editor statement.
DO $grade_details_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_grade_glass_alias_version()is distinct from '20261112-grade-glass-alias-1'then raise exception 'Install the verified Grade Glass update first.';end if;end;$$;
create or replace function greenloop_private.sga_phone_details(f jsonb,metric text,start_row integer,analysis_snapshot text,detail_snapshot text)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare summary jsonb;allrows jsonb;token text;expected_count integer;begin
 perform greenloop_private.require_office_network();
 if metric is null or metric<>all(array['qty','a','b','d','glass','polish','other','pending','returned'])or start_row is null or start_row<0 or start_row%50<>0 then raise exception 'Choose a valid grade category and page.'using errcode='22023';end if;
 if analysis_snapshot is null or analysis_snapshot!~'^[0-9a-f]{32}$'or(detail_snapshot is not null and detail_snapshot!~'^[0-9a-f]{32}$')or(start_row>0 and detail_snapshot is null)then raise exception 'Refresh the stock analysis before opening these phones.'using errcode='22023';end if;
 -- Use the actual protected report reader, including its independent section-search grant.
 summary:=public.get_stock_grade_analysis_v1(coalesce(f,'{}'));
 if not(summary->>'selected')::boolean then raise exception 'Select supplier, stock / batch or invoice first.'using errcode='22023';end if;
 if summary->>'snapshot'is distinct from analysis_snapshot then raise exception 'The stock analysis changed. Refresh it before opening phone details.'using errcode='40001';end if;
 expected_count:=(summary->'totals'->>metric)::integer;
 with selected as materialized(
  select p.*from greenloop_private.sga_rows(f)p where case metric when 'qty'then true when 'a'then not p.qc_pending and p.grade='A'when 'b'then not p.qc_pending and p.grade='B'when 'd'then not p.qc_pending and p.grade='D'when 'other'then not p.qc_pending and p.grade not in('A','B','D')when 'pending'then p.qc_pending when 'glass'then p.glass when 'polish'then p.polish when 'returned'then p.returned else false end
 ),details as(
  select p.batch_id,p.device_id,d.imei_1 imei,p.model,d.storage_gb,d.color,d.battery_health,p.grade,p.qc_pending,p.glass,p.polish,p.returned,
   s->>'supplier_code'supplier_code,case when coalesce((summary->>'names_allowed')::boolean,false)then s->>'supplier_name'end supplier_name,
   (s->>'stock_quantity')::bigint receipt_quantity,s->>'batch_number'batch_number,s->>'invoice_number'invoice_number,s->>'received_at'received_at,j.current_status::text current_stage
  from selected p join public.devices d on d.id=p.device_id and d.deleted_at is null
  join lateral(select j.current_status from public.jobs j where j.device_id=p.device_id and j.receiving_batch_id=p.batch_id and j.deleted_at is null order by j.received_at desc,j.created_at desc,j.id desc limit 1)j on true
  join lateral(select value from jsonb_array_elements(summary->'stocks')where value->>'batch_id'=p.batch_id::text limit 1)stock(s)on true
 )select coalesce(jsonb_agg(to_jsonb(x)order by x.model,x.imei,x.batch_id,x.device_id),'[]')into allrows from details x;
 if jsonb_array_length(allrows)<>expected_count then raise exception 'The grade phone list does not match the analysis total. Refresh and retry.'using errcode='40001';end if;
 token:=md5(jsonb_build_object('filters',f,'metric',metric,'analysis',analysis_snapshot,'rows',allrows,'names_allowed',summary->'names_allowed')::text);
 if detail_snapshot is not null and detail_snapshot<>token then raise exception 'Phone details changed. Close this list and open its total again.'using errcode='40001';end if;
 return jsonb_build_object('metric',metric,'total',expected_count,'offset',start_row,'analysis_snapshot',analysis_snapshot,'snapshot',token,'names_allowed',summary->'names_allowed','rows',coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(allrows)with ordinality a(r,n)where n>start_row and n<=start_row+50),'[]'));
end;$$;
create or replace function public.get_stock_grade_phone_details_v1(p_filters jsonb default '{}',p_metric text default 'qty',p_offset integer default 0,p_expected_analysis text default null,p_expected_snapshot text default null)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$begin
 perform greenloop_private.require_office_network();return greenloop_private.sga_phone_details(p_filters,p_metric,p_offset,p_expected_analysis,p_expected_snapshot);
end;$$;
revoke all on function greenloop_private.sga_phone_details(jsonb,text,integer,text,text)from public,anon,authenticated;
revoke all on function public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)from public,anon;
grant execute on function public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)to authenticated;
create table if not exists greenloop_private.grade_phone_details_installation(identity text primary key,hash text not null);
alter table greenloop_private.grade_phone_details_installation enable row level security;
revoke all on greenloop_private.grade_phone_details_installation from public,anon,authenticated;
create or replace function public.get_grade_phone_details_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_grade_glass_alias_version()='20261112-grade-glass-alias-1'
 and(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.grade_phone_details_installation)
 and not has_function_privilege('authenticated','greenloop_private.sga_phone_details(jsonb,text,integer,text,text)','EXECUTE')
 and not has_function_privilege('anon','public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)','EXECUTE')
 and has_function_privilege('authenticated','public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.grade_phone_details_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261113-grade-phone-details-1'end;$$;
revoke all on function public.get_grade_phone_details_version()from public;grant execute on function public.get_grade_phone_details_version()to anon,authenticated;
insert into greenloop_private.grade_phone_details_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.sga_phone_details(jsonb,text,integer,text,text)','public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)','public.get_grade_phone_details_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_grade_phone_details_version()is distinct from '20261113-grade-phone-details-1'then raise exception 'Grade phone details verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$grade_details_install$;
select public.get_grade_phone_details_version()as installed_grade_phone_details_version;
