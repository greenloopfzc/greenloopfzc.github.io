-- Read all permanent phone-linked correction sources; no operational/audit writes.
DO $correction_sources_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_imei_qc_corrections_version()is distinct from '20261114-imei-qc-corrections-1'then raise exception 'Verify IMEI QC / Corrections first.';end if;if to_regprocedure('public.get_imei_correction_sources_version()')is not null then if public.get_imei_correction_sources_version()is distinct from '20261114-imei-correction-sources-1'then raise exception 'Existing correction source integrity needs review.';end if;end if;end;$$;
create or replace function greenloop_private.itc_bulk_values(v jsonb)returns jsonb language sql immutable set search_path=pg_catalog,public as $$select case when jsonb_typeof(v)='object'then (v-array['initial_bh','final_bh','batch_id'])||case when v?'initial_bh'then jsonb_build_object('battery_health',v->'initial_bh')else '{}'::jsonb end||case when v?'final_bh'then jsonb_build_object('final_battery_health',v->'final_bh')else '{}'::jsonb end||case when v?'batch_id'then jsonb_build_object('receiving_batch_id',v->'batch_id')else '{}'::jsonb end else '{}'::jsonb end;$$;
revoke all on function greenloop_private.itc_bulk_values(jsonb)from public,anon,authenticated;
do $patch$declare sig text;before_hash text;old text;updated text;t record;c record;begin
 foreach sig in array array['greenloop_private.itc_history(uuid,integer,integer)','greenloop_private.itc_enrich(jsonb,uuid,uuid)']loop
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);
 if sig like '%itc_history%'then execute $history$
create or replace function greenloop_private.itc_history(dev uuid,p_offset integer,p_limit integer)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 with access as materialized(select coalesce(public.get_my_partner_name_access(),false)names,coalesce(public.has_page_capability_v1('parts','view'),false)prices),audits as materialized(
 select 'data:'||h.id id,h.changed_at at,h.changed_by actor,h.change_reason reason,
 greenloop_private.itc_changes(coalesce((select jsonb_object_agg(key,value->'old')from jsonb_each(case when jsonb_typeof(h.changed_fields)='object'then h.changed_fields else '{}'::jsonb end)where jsonb_typeof(value)='object'),'{}'),coalesce((select jsonb_object_agg(key,value->'new')from jsonb_each(case when jsonb_typeof(h.changed_fields)='object'then h.changed_fields else '{}'::jsonb end)where jsonb_typeof(value)='object'),'{}'),'IMEI details',a.names,a.prices)changes
 from public.data_change_history h cross join access a where h.device_id=dev and not(h.changed_fields?'full_workflow'and exists(select 1 from greenloop_private.workflow_correction_audit w where w.device_id=dev and position(w.id::text in(h.changed_fields->'full_workflow'->>'new'))>0))
 union all
 select 'workflow:'||w.id,w.changed_at,w.actor,w.reason,coalesce((select jsonb_agg(c order by n,c->>'key')from jsonb_array_elements(w.changes)with ordinality z(x,n)cross join lateral jsonb_array_elements(greenloop_private.itc_changes(greenloop_private.wf_public_values(x->>'kind',x->'before',a.prices),greenloop_private.wf_public_values(x->>'kind',x->'after',a.prices),initcap(replace(x->>'kind','_',' ')),a.names,a.prices))c),'[]')
 from greenloop_private.workflow_correction_audit w cross join access a where w.device_id=dev
 union all
 select 'bulk:'||b.request_id,b.changed_at,b.actor,b.reason,greenloop_private.itc_changes(greenloop_private.itc_bulk_values(x->'before'),greenloop_private.itc_bulk_values(x->'after'),'Bulk IMEI Correction',a.names,a.prices)
 from greenloop_private.bulk_imei_audit b cross join access a cross join lateral jsonb_array_elements(b.changes)x where x->>'device_id'=dev::text
 union all
 select 'receipt:'||h.request_id,h.created_at,h.actor,h.reason,greenloop_private.itc_changes(jsonb_build_object('received_quantity',h.old_quantity),jsonb_build_object('received_quantity',h.new_quantity),'Stock Receipt Correction',a.names,a.prices)
 from greenloop_private.receipt_quantity_audit h cross join access a where exists(select 1 from public.jobs j join greenloop_private.sc_receipts()s on j.receiving_batch_id=any(s.descendant_ids)where j.device_id=dev and j.deleted_at is null and s.batch_id=h.batch_id)
 union all
 select 'chaman:'||h.id,h.created_at,h.actor,h.reason,greenloop_private.itc_changes(jsonb_build_object('transfer_date',h.before_data->'document'->'created_at','transfer_notes',h.before_data->'document'->'notes','included_in_transfer',true,'shop_received_at',l->'shop_received_at','company_received_at',l->'company_received_at','phase',l->'phase','voided_at',l->'voided_at'),jsonb_build_object('transfer_date',h.after_data->'document'->'created_at','transfer_notes',h.after_data->'document'->'notes','included_in_transfer',after_line is not null,'shop_received_at',after_line->'shop_received_at','company_received_at',after_line->'company_received_at','phase',after_line->'phase','voided_at',after_line->'voided_at'),'Chaman Transfer Correction',a.names,a.prices)
 from greenloop_private.chaman_audit h cross join access a cross join lateral jsonb_array_elements(h.before_data->'lines')l left join lateral(select x after_line from jsonb_array_elements(coalesce(h.after_data->'lines','[]'))x where x->>'id'=l->>'id'limit 1)newline on true where l->>'device_id'=dev::text
 union all
 select 'event:'||e.id,e.created_at,e.actor_id,coalesce(e.event_data->>'reason',e.event_title),greenloop_private.itc_changes(greenloop_private.itc_bulk_values(e.event_data->'before'),greenloop_private.itc_bulk_values(e.event_data->'after'),'Saved correction event',a.names,a.prices)
 from public.device_events e cross join access a where e.device_id=dev and e.event_type~'(^|_)(corrected|correction)$'and jsonb_typeof(e.event_data->'before')='object'and jsonb_typeof(e.event_data->'after')='object'
 and not exists(select 1 from public.data_change_history h where h.device_id=dev and h.id::text=coalesce(e.event_data->>'audit_id',e.event_data->>'change_id',e.event_data->>'history_id'))
 and not exists(select 1 from greenloop_private.workflow_correction_audit h where h.device_id=dev and h.id::text=e.event_data->>'audit_id')
 and not exists(select 1 from greenloop_private.bulk_imei_audit h cross join lateral jsonb_array_elements(h.changes)x where h.request_id::text=e.event_data->>'audit_id'and x->>'device_id'=dev::text)
 ),shaped as materialized(select a.id,a.at occurred_at,coalesce(u.full_name,'Recorded user')actor,a.reason,case split_part(a.id,':',1)when 'bulk'then 'Bulk IMEI Correction'when 'workflow'then 'IMEI Workflow Correction'when 'data'then 'IMEI Data Correction'when 'receipt'then 'Stock Receipt Correction'when 'chaman'then 'Chaman Transfer Correction'else 'Saved correction event'end source,a.changes from audits a left join public.user_profiles u on u.id=a.actor),payload as(select coalesce(jsonb_agg(to_jsonb(s)order by occurred_at desc,id),'[]')all_rows from shaped s)
 select jsonb_build_object('version','20261114-imei-qc-corrections-1','sources_version','20261114-imei-correction-sources-1','offset',p_offset,'limit',p_limit,'total',jsonb_array_length(all_rows),'snapshot',md5(all_rows::text),'rows',coalesce((select jsonb_agg(x order by n)from jsonb_array_elements(all_rows)with ordinality z(x,n)where n>p_offset and n<=p_offset+p_limit),'[]'))from payload;
$$;
$history$;
 else
  updated:=regexp_replace(old,$p$e\s*\.\s*event_type\s+in\s*\(\s*'imei_data_corrected'[^)]*\)$p$,$v$e.event_type~'(^|_)(corrected|correction)$'$v$);
  if updated=old and position('e.event_type~''(^|_)(corrected|correction)$'''in old)=0 then raise exception 'Correction event boundary changed. Review before installing.';end if;if updated<>old then execute updated;end if;
 end if;
 -- Reseal only receipts whose existing reviewed before-hash matches.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;end;$patch$;
revoke all on function greenloop_private.itc_history(uuid,integer,integer),greenloop_private.itc_enrich(jsonb,uuid,uuid)from public,anon,authenticated;
insert into greenloop_private.capability_rpc_rules values('get_imei_correction_sources_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.imei_correction_sources_installation(identity text primary key,hash text not null);alter table greenloop_private.imei_correction_sources_installation enable row level security;revoke all on greenloop_private.imei_correction_sources_installation from public,anon,authenticated;
create or replace function public.get_imei_correction_sources_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_imei_qc_corrections_version()='20261114-imei-qc-corrections-1'and(select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.imei_correction_sources_installation)and not exists(select 1 from pg_proc where pronamespace='greenloop_private'::regnamespace and proname in('itc_history','itc_enrich','itc_bulk_values')and(has_function_privilege('anon',oid,'EXECUTE')or has_function_privilege('authenticated',oid,'EXECUTE')))and exists(select 1 from pg_class where oid='greenloop_private.imei_correction_sources_installation'::regclass and relrowsecurity)and not has_table_privilege('authenticated','greenloop_private.imei_correction_sources_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261114-imei-correction-sources-1'end;$$;
revoke all on function public.get_imei_correction_sources_version()from public;grant execute on function public.get_imei_correction_sources_version()to anon,authenticated;
insert into greenloop_private.imei_correction_sources_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.itc_bulk_values(jsonb)','greenloop_private.itc_history(uuid,integer,integer)','greenloop_private.itc_enrich(jsonb,uuid,uuid)','public.get_imei_correction_sources_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_imei_correction_sources_version()is distinct from '20261114-imei-correction-sources-1'then raise exception 'Correction source verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$correction_sources_install$;
select public.get_imei_correction_sources_version()as installed_imei_correction_sources_version;
