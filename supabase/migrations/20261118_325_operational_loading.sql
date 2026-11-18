-- Preserve complete work queues; reuse each Lab visit calculation within a fresh read.
do $install$
declare sig text;old text;updated text;src text;api text;api_oid oid;target_oid oid;matches integer;n integer;t record;b record;c record;verified boolean;reviewed jsonb:='[]';sealed text[]:='{}';
begin
 perform set_config('search_path','pg_catalog,public',true);
 if to_regprocedure('public.get_operational_loading_version()')is not null then
  if public.get_operational_loading_version()is distinct from '20261118-operational-loading-1'then raise exception 'Existing operational loading integrity differs. Nothing installed.';end if;return;
 end if;
 if public.get_chaman_bulk_return_version()is distinct from '20261118-chaman-bulk-return-1'then raise exception 'Install the verified Chaman / Bulk / Return prerequisite first.';end if;
 if not exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))then raise exception 'Permission rules integrity differs.';end if;
 create table greenloop_private.operational_loading_installation(identity text primary key,hash text not null);
 alter table greenloop_private.operational_loading_installation enable row level security;
 revoke all on greenloop_private.operational_loading_installation from public,anon,authenticated;
sig:=$token$greenloop_private.pf_plan(uuid)$token$;old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='identity'and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='hash'and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where to_regprocedure(identity)=to_regprocedure($1)and hash=$2)',t.name)into verified using sig,md5(old);exit when verified;end loop;
if not verified then raise exception 'Lab source integrity receipt differs: %',sig;end if;
sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,$token$FUNCTION\s*greenloop_private\.pf_plan\(p_step\s*uuid\)$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$FUNCTION\s*greenloop_private\.pf_plan\(p_step\s*uuid\)$token$,$replacement$FUNCTION greenloop_private.ol_pf_plan(p_step uuid, c integer, v_start timestamp with time zone)$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$v_start\s*timestamptz;$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$v_start\s*timestamptz;$token$,$replacement$$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$select\s*max\(entered_at\)into\s*v_start\s*from\s*greenloop_private\.lab_stays_v1\(d\)where\s*job_id=j;$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$select\s*max\(entered_at\)into\s*v_start\s*from\s*greenloop_private\.lab_stays_v1\(d\)where\s*job_id=j;$token$,$replacement$$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$greenloop_private\.pf_cycle\(j\)$token$,'g');if n<>3 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$greenloop_private\.pf_cycle\(j\)$token$,$replacement$c$replacement$,'g');
execute updated;
revoke all on function greenloop_private.ol_pf_plan(uuid,integer,timestamp with time zone) from public,anon,authenticated;sealed:=array_append(sealed,$token$greenloop_private.ol_pf_plan(uuid,integer,timestamp with time zone)$token$);
sig:=$token$greenloop_private.ps_service_state(uuid)$token$;old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='identity'and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='hash'and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where to_regprocedure(identity)=to_regprocedure($1)and hash=$2)',t.name)into verified using sig,md5(old);exit when verified;end loop;
if not verified then raise exception 'Lab source integrity receipt differs: %',sig;end if;
sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,$token$FUNCTION\s*greenloop_private\.ps_service_state\(p_step\s*uuid\)$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$FUNCTION\s*greenloop_private\.ps_service_state\(p_step\s*uuid\)$token$,$replacement$FUNCTION greenloop_private.ol_service_state(p_step uuid, c integer, v_start timestamp with time zone)$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$c\s*integer;v_start\s*timestamptz;$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$c\s*integer;v_start\s*timestamptz;$token$,$replacement$$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$c:=greenloop_private\.pf_cycle\(j\);$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$c:=greenloop_private\.pf_cycle\(j\);$token$,$replacement$$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$select\s*max\(entered_at\)into\s*v_start\s*from\s*greenloop_private\.lab_stays_v1\(d\)where\s*job_id=j;$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$select\s*max\(entered_at\)into\s*v_start\s*from\s*greenloop_private\.lab_stays_v1\(d\)where\s*job_id=j;$token$,$replacement$$replacement$,'g');
execute updated;
revoke all on function greenloop_private.ol_service_state(uuid,integer,timestamp with time zone) from public,anon,authenticated;sealed:=array_append(sealed,$token$greenloop_private.ol_service_state(uuid,integer,timestamp with time zone)$token$);
sig:=$token$greenloop_private.pp_plan(uuid)$token$;old:=pg_get_functiondef(to_regprocedure(sig));verified:=false;
for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='identity'and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname='hash'and atttypid='text'::regtype)loop
 execute format('select exists(select 1 from %s where to_regprocedure(identity)=to_regprocedure($1)and hash=$2)',t.name)into verified using sig,md5(old);exit when verified;end loop;
if not verified then raise exception 'Lab source integrity receipt differs: %',sig;end if;
sealed:=array_append(sealed,sig);updated:=old;
select count(*)into n from regexp_matches(updated,$token$FUNCTION\s*greenloop_private\.pp_plan\(p_step\s*uuid\)$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$FUNCTION\s*greenloop_private\.pp_plan\(p_step\s*uuid\)$token$,$replacement$FUNCTION greenloop_private.ol_plan(p_step uuid)$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$declare\s*p\s*jsonb;$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$declare\s*p\s*jsonb;$token$,$replacement$declare c integer;v_start timestamptz;entered timestamptz;j uuid;d uuid;p jsonb;$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$p:=greenloop_private\.ps_plan\(p_step\);$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$p:=greenloop_private\.ps_plan\(p_step\);$token$,$replacement$select w.job_id,w.device_id into j,d from public.job_work_order_steps st join public.job_work_orders w on w.id=st.work_order_id where st.id=p_step;
if j is null or d is null then return null;end if;
select count(*)::integer,max(entered_at),max(entered_at)filter(where ongoing)into c,v_start,entered from greenloop_private.lab_stays_v1(d)where job_id=j;
p:=greenloop_private.ol_pf_plan(p_step,c,v_start)||greenloop_private.ol_service_state(p_step,c,v_start);$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$return\s*p\|\|jsonb_build_object\('parts',parts$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$return\s*p\|\|jsonb_build_object\('parts',parts$token$,$replacement$return p||jsonb_build_object('_ol_lab_entered_at',entered,'parts',parts$replacement$,'g');
execute updated;
revoke all on function greenloop_private.ol_plan(uuid) from public,anon,authenticated;sealed:=array_append(sealed,$token$greenloop_private.ol_plan(uuid)$token$);
api:=$token$public.get_lab_workbench_v1(uuid,text)$token$;api_oid:=to_regprocedure(api);
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
 if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous Office implementation for %',api;end if;
 if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Office implementation integrity differs for %',api;end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Office implementation for %',api;end if;
 sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
 reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);sealed:=array_append(sealed,api);
select count(*)into n from regexp_matches(updated,$token$greenloop_private\.pp_plan\(\(row\->>'step_id'\)::uuid\)$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$greenloop_private\.pp_plan\(\(row\->>'step_id'\)::uuid\)$token$,$replacement$greenloop_private.ol_plan((row->>'step_id')::uuid)$replacement$,'g');
execute updated;
api:=$token$public.get_lab_workbench_timing_v1(uuid,text)$token$;api_oid:=to_regprocedure(api);
select count(distinct to_regprocedure(implementation)::oid),min(to_regprocedure(implementation)::oid)into matches,target_oid from greenloop_private.office_routines where to_regprocedure(identity)=api_oid;
 if matches<>1 or target_oid is null then raise exception 'Missing or ambiguous Office implementation for %',api;end if;
 if not exists(select 1 from pg_proc p join pg_proc a on a.oid=api_oid where p.oid=target_oid and p.pronamespace='greenloop_private'::regnamespace and p.prosecdef and p.proargtypes=a.proargtypes and p.prorettype=a.prorettype)or not exists(select 1 from greenloop_private.office_routines where to_regprocedure(identity)=api_oid and to_regprocedure(implementation)=target_oid and original_hash=md5(pg_get_functiondef(target_oid))and wrapped_hash=md5(pg_get_functiondef(api_oid)))then raise exception 'Office implementation integrity differs for %',api;end if;
 if position((select 'greenloop_private.'||proname||'('from pg_proc where oid=target_oid)in regexp_replace(replace(pg_get_functiondef(api_oid),'"',''),'\s','','g'))=0 then raise exception 'Disconnected Office implementation for %',api;end if;
 sig:=target_oid::regprocedure::text;old:=pg_get_functiondef(target_oid);updated:=old;
 reviewed:=reviewed||jsonb_build_array(jsonb_build_object('identity',sig,'hash',md5(old)));sealed:=array_append(sealed,sig);sealed:=array_append(sealed,api);
select count(*)into n from regexp_matches(updated,$token$r\.value\|\|jsonb_build_object\('lab_entered_at',stay\.entered_at$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$r\.value\|\|jsonb_build_object\('lab_entered_at',stay\.entered_at$token$,$replacement$r.value||jsonb_build_object('pf_plan',(r.value->'pf_plan')-'_ol_lab_entered_at','lab_entered_at',nullif(r.value->'pf_plan'->>'_ol_lab_entered_at','')::timestamptz$replacement$,'g');
select count(*)into n from regexp_matches(updated,$token$left\s*join\s*lateral\(select\s*t\.entered_at\s*from\s*greenloop_private\.lab_stays_v1\(j\.device_id\)t\s*where\s*t\.job_id=j\.id\s*and\s*t\.ongoing\s*order\s*by\s*t\.entered_at\s*desc\s*limit\s*1\)stay\s*on\s*true$token$,'g');if n<>1 then raise exception 'Reviewed loading boundary changed: %',sig;end if;
updated:=regexp_replace(updated,$token$left\s*join\s*lateral\(select\s*t\.entered_at\s*from\s*greenloop_private\.lab_stays_v1\(j\.device_id\)t\s*where\s*t\.job_id=j\.id\s*and\s*t\.ongoing\s*order\s*by\s*t\.entered_at\s*desc\s*limit\s*1\)stay\s*on\s*true$token$,$replacement$$replacement$,'g');
execute updated;

-- Labels are independent of current inventory balances. Keep replacement intake
-- IDs private and resolve only their original receipt labels/quantities.
create or replace function public.get_operational_receipt_labels_v1(p_page text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $labels$
declare data jsonb;names boolean;
begin
 perform greenloop_private.require_office_network();
 if p_page is null or p_page not in('initial_qc','qc_issuance','lab_glass','final_qc','frame_department')then raise exception 'Choose an allowed operational page.'using errcode='42501';end if;
 perform greenloop_private.pf_cap(p_page,'view');names:=coalesce(public.get_my_partner_name_access(),false);
 if exists(select 1 from greenloop_private.srp_receipts group by replacement_batch_id having count(distinct original_batch_id)>1)then raise exception 'Original stock receipt linkage needs review.';end if;
 select coalesce(jsonb_agg(jsonb_build_object('batch_id',b.id,'parent_batch_id',parent.id,'supplier_id',b.supplier_id,'supplier_code',s.supplier_code,'supplier_name',case when names then s.company_name end,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'received_at',b.received_at,'received_quantity',b.planned_quantity,'labels_only',true)order by b.received_at,b.id),'[]')into data
 from public.receiving_batches b left join public.suppliers s on s.id=b.supplier_id
 left join lateral(select original_batch_id id from greenloop_private.srp_receipts where replacement_batch_id=b.id order by original_batch_id limit 1)parent on true;
 return jsonb_build_object('version','20261118-operational-loading-1','rows',data);
end;$labels$;
revoke all on function public.get_operational_receipt_labels_v1(text)from public,anon;grant execute on function public.get_operational_receipt_labels_v1(text)to authenticated;
insert into greenloop_private.capability_rpc_rules values('get_operational_receipt_labels_v1','{"dynamic":"filter_source","parameter":"p_page","initial_qc":{"page":"initial_qc","capability":"view","read":true},"qc_issuance":{"page":"qc_issuance","capability":"view","read":true},"lab_glass":{"page":"lab_glass","capability":"view","read":true},"final_qc":{"page":"final_qc","capability":"view","read":true},"frame_department":{"page":"frame_department","capability":"view","read":true}}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
sealed:=array_append(sealed,'public.get_operational_receipt_labels_v1(text)');
-- Update only intact receipts for the two reviewed implementation edits.
for b in select *from jsonb_to_recordset(reviewed)as r(identity text,hash text)loop
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
 for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%\_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
 execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using b.identity,b.hash;
 end loop;end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(b.identity)))where to_regprocedure(implementation)=to_regprocedure(b.identity)and original_hash=b.hash;
end loop;
create or replace function public.get_operational_loading_version()returns text language sql stable security definer set search_path=pg_catalog,public as $version$
select case when public.get_chaman_bulk_return_version()='20261118-chaman-bulk-return-1'
and(select count(*)=12 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.operational_loading_installation)
and not exists(select 1 from greenloop_private.operational_loading_installation where identity like 'greenloop_private.%'and(has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
and exists(select 1 from pg_class where oid='greenloop_private.operational_loading_installation'::regclass and relrowsecurity)
and not has_table_privilege('anon','greenloop_private.operational_loading_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.operational_loading_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
and exists(select 1 from greenloop_private.page_capability_installation where identity='rules'and hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r))
then '20261118-operational-loading-1'end;$version$;
revoke all on function public.get_operational_loading_version()from public;grant execute on function public.get_operational_loading_version()to anon,authenticated;
sealed:=array_append(sealed,'public.get_operational_loading_version()');
insert into greenloop_private.operational_loading_installation select identity,md5(pg_get_functiondef(to_regprocedure(identity)))from unnest(sealed)identity;
if public.get_operational_loading_version()is distinct from '20261118-operational-loading-1'then raise exception 'Operational loading verification failed. Nothing installed.';end if;
notify pgrst,'reload schema';
end;$install$;
select public.get_operational_loading_version()as installed_operational_loading_version;
