-- Read-only Ready Stock daily arrivals and confirmed exports, 10 AM–9 PM UAE.
begin;
do $$begin
 if to_regprocedure('public.get_ready_stock_daily_activity_version()')is not null then if public.get_ready_stock_daily_activity_version()is distinct from '20261111-ready-stock-daily-1'then raise exception 'Existing Ready Stock Daily installation requires review.';end if;end if;
 if public.get_qc_direct_ready_version()is distinct from '20261105-qc-direct-ready-1'then raise exception 'Verified Direct Ready Stock support is required.';end if;
 if to_regprocedure('greenloop_private.jst_proofs(uuid)')is null then raise exception 'Verified export proof support is required.';end if;
end;$$;
create index if not exists ready_daily_movement_lookup on public.device_location_history(moved_at,to_location_id,device_id);
create index if not exists ready_daily_export_lookup on greenloop_private.box_workflow(verified_at,box_id)where state='exported';
create index if not exists ready_daily_dispatch_lookup on public.stock_out_records(dispatched_at,job_id)where dispatched_at is not null;
create or replace function greenloop_private.rsd_facts(p_date date)
returns table(kind text,job_id uuid,device_id uuid,occurred_at timestamptz,box_number text,export_grade text)
language sql stable security definer set search_path=pg_catalog,public as $$
 with bounds as(select(p_date+time '10:00')at time zone 'Asia/Dubai'lo,least((p_date+time '21:00')at time zone 'Asia/Dubai',now())hi),
 arrivals as(
  select 'ready'::text kind,h.job_id,h.device_id,h.moved_at occurred_at,null::text box_number,null::text export_grade,h.id tie
  from public.device_location_history h join public.locations l on l.id=h.to_location_id cross join bounds b
  where l.location_code in('PRODUCTION','READY','READY-STOCK')and h.from_location_id is distinct from h.to_location_id and h.moved_at>=b.lo and h.moved_at<=b.hi
 ), exports as(
  select 'export'::text,i.job_id,i.device_id,w.verified_at,bx.box_number,i.final_grade,i.id
  from greenloop_private.box_workflow w join public.export_boxes bx on bx.id=w.box_id join public.export_box_items i on i.box_id=w.box_id cross join bounds b
  where w.state='exported'and w.verified_at is not null and i.scanned_at<=w.verified_at and w.verified_at>=b.lo and w.verified_at<=b.hi
  union all
  select 'export',r.job_id,j.device_id,r.dispatched_at,null,null,r.id from public.stock_out_records r join public.jobs j on j.id=r.job_id cross join bounds b where r.dispatched_at is not null and r.dispatched_at>=b.lo and r.dispatched_at<=b.hi
 ), facts as(select *from arrivals union all select *from exports)
 select distinct on(f.kind,f.device_id)f.kind,f.job_id,f.device_id,f.occurred_at,f.box_number,f.export_grade from facts f
 join public.jobs j on j.id=f.job_id and j.device_id=f.device_id and j.deleted_at is null join public.devices d on d.id=f.device_id and d.deleted_at is null
 order by f.kind,f.device_id,f.occurred_at,f.tie;
$$;
revoke all on function greenloop_private.rsd_facts(date)from public,anon,authenticated;
create or replace function greenloop_private.rsd_read(p_date date,p_kind text,p_offset integer,p_limit integer)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare day date:=coalesce(p_date,(now()at time zone 'Asia/Dubai')::date);result jsonb;names boolean;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('ready_stock','view');
 if greenloop_private.damage_tv_only(auth.uid())or not public.has_role(array['super_admin','owner','manager','production','final_qc','shop_staff']::public.app_role_key[])then raise exception 'Ready Stock view permission is required.'using errcode='42501';end if;
 if day<>(now()at time zone 'Asia/Dubai')::date then perform greenloop_private.pf_cap('ready_stock','search');end if;
 if day>(now()at time zone 'Asia/Dubai')::date then raise exception 'Choose today or an earlier date.'using errcode='22023';end if;
 if p_kind is not null and p_kind not in('ready','export')then raise exception 'Choose daily Ready Stock or Export.'using errcode='22023';end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Choose a valid 50-phone page.'using errcode='22023';end if;
 names:=coalesce(public.get_my_partner_name_access(),false);
 with facts as materialized(select *from greenloop_private.rsd_facts(day)),
 selected as(select *from facts where kind=p_kind order by occurred_at,device_id offset p_offset limit p_limit),
 rows as(select jsonb_build_object('imei',d.imei_1,'device_number',d.device_number,'model',d.model,'storage_gb',d.storage_gb,'color',d.color,
  'grade',coalesce(s.export_grade,pass.final_grade),'supplier_code',sp.supplier_code,'supplier_name',case when names then sp.company_name end,'planned_quantity',b.planned_quantity,'batch_number',b.batch_number,'invoice_number',b.invoice_number,'occurred_at',s.occurred_at,'box_number',s.box_number)r,s.occurred_at,s.device_id
  from selected s join public.jobs j on j.id=s.job_id join public.devices d on d.id=s.device_id left join public.receiving_batches b on b.id=j.receiving_batch_id left join public.suppliers sp on sp.id=coalesce(j.supplier_id,b.supplier_id)
  left join lateral(select q.final_grade from greenloop_private.qdr_ready_outcomes q where q.job_id=j.id and q.inspected_at<=s.occurred_at order by q.inspected_at desc limit 1)pass on true)
 select jsonb_build_object('date',day,'timezone','Asia/Dubai','starts_at',(day+time '10:00')at time zone 'Asia/Dubai','ends_at',(day+time '21:00')at time zone 'Asia/Dubai','as_of',now(),
  'ready_count',(select count(*)from facts where kind='ready'),'export_count',(select count(*)from facts where kind='export'),'kind',p_kind,'offset',p_offset,'limit',p_limit,
  'total',(select count(*)from facts where kind=p_kind),'rows',coalesce((select jsonb_agg(r order by occurred_at,device_id)from rows),'[]'::jsonb))into result;
 return result;
end;$$;
revoke all on function greenloop_private.rsd_read(date,text,integer,integer)from public,anon,authenticated;
create or replace function public.get_ready_stock_daily_activity_v1(p_date date default null,p_kind text default null,p_offset integer default 0,p_limit integer default 50)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.rsd_read(p_date,p_kind,p_offset,p_limit);end;$$;
revoke all on function public.get_ready_stock_daily_activity_v1(date,text,integer,integer)from public,anon,authenticated;
grant execute on function public.get_ready_stock_daily_activity_v1(date,text,integer,integer)to authenticated;
insert into greenloop_private.office_routines select 'public.get_ready_stock_daily_activity_v1(date,text,integer,integer)','greenloop_private.rsd_read(date,text,integer,integer)',md5(pg_get_functiondef('greenloop_private.rsd_read(date,text,integer,integer)'::regprocedure)),md5(pg_get_functiondef('public.get_ready_stock_daily_activity_v1(date,text,integer,integer)'::regprocedure))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_ready_stock_daily_activity_v1','{"page":"ready_stock","capability":"view","read":true}'),('get_ready_stock_daily_activity_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.ready_daily_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.ready_daily_installation enable row level security;revoke all on greenloop_private.ready_daily_installation from public,anon,authenticated;
create or replace function public.get_ready_stock_daily_activity_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=7 and bool_and(coalesce(hash=case when kind='function'then md5(pg_get_functiondef(to_regprocedure(identity)))else md5(pg_get_indexdef(to_regclass(identity)))end,false))from greenloop_private.ready_daily_installation)
 and has_function_privilege('authenticated','public.get_ready_stock_daily_activity_v1(date,text,integer,integer)','EXECUTE')and not has_function_privilege('anon','public.get_ready_stock_daily_activity_v1(date,text,integer,integer)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsd_facts(date)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsd_facts(date)','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.rsd_read(date,text,integer,integer)','EXECUTE')and not has_function_privilege('anon','greenloop_private.rsd_read(date,text,integer,integer)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.ready_daily_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.ready_daily_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.ready_daily_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_ready_stock_daily_activity_v1'and rule='{"page":"ready_stock","capability":"view","read":true}'::jsonb)
 then '20261111-ready-stock-daily-1'end;
$$;
revoke all on function public.get_ready_stock_daily_activity_version()from public;grant execute on function public.get_ready_stock_daily_activity_version()to anon,authenticated;
insert into greenloop_private.ready_daily_installation select 'function',s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.rsd_facts(date)','greenloop_private.rsd_read(date,text,integer,integer)','public.get_ready_stock_daily_activity_v1(date,text,integer,integer)','public.get_ready_stock_daily_activity_version()'])s on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.ready_daily_installation select 'index',s,md5(pg_get_indexdef(s::regclass))from unnest(array['public.ready_daily_movement_lookup','greenloop_private.ready_daily_export_lookup','public.ready_daily_dispatch_lookup'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_ready_stock_daily_activity_version()is distinct from '20261111-ready-stock-daily-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Ready Stock Daily installation failed verification. No changes installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_ready_stock_daily_activity_version()as installed_ready_stock_daily_activity_version;
