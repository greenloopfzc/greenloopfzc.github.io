-- Ready Stock quantity drill-down; read-only and matched to the native summary eligibility.
begin;
do $$begin if public.get_workbench_performance_version()is distinct from '20261027-performance-1'then raise exception 'Verified Performance update is required.';end if;if to_regprocedure('public.get_ready_stock_imeis_version()')is not null then if public.get_ready_stock_imeis_version()is distinct from '20261028-ready-stock-imeis-1'then raise exception 'Existing Ready Stock IMEI list needs review.';end if;end if;end;$$;
create index if not exists ready_stock_qc_pass_lookup on public.final_qc_inspections(job_id,inspected_at desc)where result='pass';
create or replace function public.get_ready_stock_imeis_v1(p_groups jsonb,p_date_from date default null,p_date_to date default null,p_offset integer default 0,p_limit integer default 50)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare result jsonb;begin
 perform greenloop_private.pf_cap('ready_stock','view');
 if not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'You do not have permission to view Ready Stock.'using errcode='42501';end if;
 if(p_date_from is null)<>(p_date_to is null)or(p_date_from is not null and p_date_from>p_date_to)then raise exception 'Select a valid date range.'using errcode='22023';end if;
 if p_date_from is not null then perform greenloop_private.pf_cap('ready_stock','search');end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Choose a valid phone list page.'using errcode='22023';end if;
 if p_groups is null or jsonb_typeof(p_groups)<>'array'then raise exception 'Choose a Ready Stock quantity.'using errcode='22023';end if;
 if jsonb_array_length(p_groups)not between 1 and 10000 or exists(select 1 from jsonb_array_elements(p_groups)x where jsonb_typeof(x)<>'object'or jsonb_typeof(x->'m')is distinct from 'string'or jsonb_typeof(x->'g')is distinct from 'string'or length(x->>'m')not between 1 and 1000 or length(x->>'g')not between 1 and 200)then raise exception 'Choose valid stock groups.'using errcode='22023';end if;
 with eligible as materialized(

    select
      job.id as job_id,
      job.job_type,
      concat_ws(
        ' ',
        coalesce(nullif(btrim(device.model), ''), 'Unknown model'),
        case when device.storage_gb is null then null else device.storage_gb::text || ' GB' end
      ) as model_label,
      coalesce(nullif(btrim(final_pass.final_grade), ''), 'Unspecified') as final_grade,
      final_pass.latest_passed_at
    from public.jobs as job
    join public.devices as device on device.id = job.device_id
    cross join lateral (
      select inspection.inspected_at as latest_passed_at, inspection.final_grade
      from public.final_qc_inspections as inspection
      where inspection.job_id = job.id
        and inspection.result = 'pass'
        and (
          p_date_from is null
          or timezone('Asia/Dubai', inspection.inspected_at)::date between p_date_from and p_date_to
        )
      order by inspection.inspected_at desc
      limit 1
    ) as final_pass
    where job.deleted_at is null
      and job.current_status in (
        'qc_passed', 'production_pending', 'production_completed',
        'ready_for_packing', 'ready_for_shipment'
      )

 ),selected as materialized(select e.*from eligible e where exists(select 1 from jsonb_array_elements(p_groups)g where btrim(e.model_label)=g->>'m'and lower(regexp_replace(btrim(e.final_grade),'[[:space:]]+',' ','g'))=g->>'g'))
 select jsonb_build_object('total',(select count(*)from selected),'offset',p_offset,'limit',p_limit,'rows',coalesce((select jsonb_agg(to_jsonb(q)order by q.imei nulls last,q.device_number,q.job_id)from(
 select s.job_id,d.id device_id,d.imei_1 imei,d.device_number,d.model,d.storage_gb,d.color,s.final_grade,s.latest_passed_at,sup.supplier_code,b.batch_number
 from selected s join public.jobs j on j.id=s.job_id join public.devices d on d.id=j.device_id left join public.suppliers sup on sup.id=j.supplier_id left join public.receiving_batches b on b.id=j.receiving_batch_id
 order by d.imei_1 nulls last,d.device_number,s.job_id offset p_offset limit p_limit)q),'[]'::jsonb))into result;
 return result;
end;$$;
insert into greenloop_private.capability_rpc_rules values('get_ready_stock_imeis_v1','{"page":"ready_stock","capability":"view","read":true}'::jsonb)on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
do $wrap$declare f record;impl text;impl_identity text;args text;body text;begin
 for f in select p.*,pg_get_functiondef(p.oid)ddl,p.oid::regprocedure::text signature from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_ready_stock_imeis_v1')loop
 impl:='office_impl_'||f.oid;execute regexp_replace(f.ddl,'FUNCTION public\.'||f.proname||'\(','FUNCTION greenloop_private.'||impl||'(');impl_identity:='greenloop_private.'||impl||'('||oidvectortypes(f.proargtypes)||')';execute format('revoke all on function %s from public,anon,authenticated',impl_identity);select coalesce(string_agg('$'||i,','order by i),'')into args from generate_series(1,f.pronargs)i;
 body:=E'begin\n -- greenloop-office-wrapper-196\n perform greenloop_private.require_office_network();\n return greenloop_private.'||impl||'('||args||E');\nend;';execute format('create or replace function public.%I(%s)returns %s language plpgsql %s security definer set search_path=pg_catalog,public as %L',f.proname,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),case f.provolatile when 's'then 'stable'else 'volatile'end,body);execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to authenticated',f.signature);insert into greenloop_private.office_routines values(f.signature,impl_identity,md5(pg_get_functiondef(impl_identity::regprocedure)),md5(pg_get_functiondef(f.oid)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
end;$wrap$;
create table if not exists greenloop_private.ready_stock_imeis_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.ready_stock_imeis_installation enable row level security;revoke all on greenloop_private.ready_stock_imeis_installation from public,anon,authenticated;
insert into greenloop_private.ready_stock_imeis_installation select 'function',p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_ready_stock_imeis_v1'on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.ready_stock_imeis_installation values('index','public.ready_stock_qc_pass_lookup',md5(pg_get_indexdef('public.ready_stock_qc_pass_lookup'::regclass)))on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_ready_stock_imeis_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_workbench_performance_version()='20261027-performance-1'
 and(select count(*)=2 and bool_and(coalesce(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else md5(pg_get_indexdef(to_regclass(identity)))end,false))from greenloop_private.ready_stock_imeis_installation)
 and not has_table_privilege('authenticated','greenloop_private.ready_stock_imeis_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.ready_stock_imeis_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261028-ready-stock-imeis-1'end;$$;
revoke all on function public.get_ready_stock_imeis_version()from public;grant execute on function public.get_ready_stock_imeis_version()to anon,authenticated;
do $$begin if public.get_ready_stock_imeis_version()is distinct from '20261028-ready-stock-imeis-1'then raise exception 'Ready Stock IMEI list verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_ready_stock_imeis_version()as installed_ready_stock_imeis_version;
