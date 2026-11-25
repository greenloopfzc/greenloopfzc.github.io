-- Count saved QC releases, excluding stock movements back from boxes or transfers.
begin;
set local lock_timeout='5s';

do $review$
begin
  if (
    select count(*) from greenloop_private.stock_activity_installation
    where to_regprocedure(identity) in (
      'greenloop_private.rpta_facts(date,date)'::regprocedure,
      'greenloop_private.rpta_first(text)'::regprocedure
    ) and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
  )<>2 then
    raise exception 'The installed Stock Activity readers could not be verified.';
  end if;
  if (select count(*) from greenloop_private.ready_daily_installation
      where kind='function' and to_regprocedure(identity) in (
        'greenloop_private.rsd_facts(date)'::regprocedure,
        'greenloop_private.rsd_read(date,text,integer,integer)'::regprocedure
      ) and hash=md5(pg_get_functiondef(to_regprocedure(identity))))<>2 then
    raise exception 'The installed daily stock-detail readers could not be verified.';
  end if;
end;
$review$;

create or replace function greenloop_private.rpta_ready_releases(
  p_from timestamptz,p_to timestamptz,p_limit integer
) returns table(job_id uuid,device_id uuid,occurred_at timestamptz,final_grade text,tie uuid)
language sql stable security definer set search_path=pg_catalog,public as $release$
  select h.job_id,h.device_id,h.moved_at,coalesce(nullif(btrim(q.grade),''),'Unspecified'),h.id
  from public.device_location_history h
  join public.locations dst on dst.id=h.to_location_id
  left join public.locations src on src.id=h.from_location_id
  join public.jobs j on j.id=h.job_id and j.device_id=h.device_id and j.deleted_at is null
  join public.devices d on d.id=h.device_id and d.deleted_at is null
  cross join lateral (
    select saved.grade from (
      select f.final_grade::text grade,1 source_order,f.id::text source_id
      from public.final_qc_inspections f
      where src.location_code='FINAL-QC' and f.job_id=h.job_id and f.device_id=h.device_id
        and f.inspected_at=h.moved_at and f.result='pass' and not coalesce(f.routed_to_frame,false)
      union all
      select r.final_grade,2,r.inspection_id::text
      from greenloop_private.qc_direct_ready r
      where h.movement_reason='Initial QC - no work required - directly to Ready Stock'
        and r.job_id=h.job_id and r.device_id=h.device_id and r.ready_at=h.moved_at
      union all
      select e.event_data->>'final_grade',3,e.id::text
      from public.device_events e
      where (src.location_code='FRAME' or h.movement_reason like 'Frame passed to Ready Stock%')
        and e.event_type='frame_passed_ready_stock' and e.job_id=h.job_id
        and e.device_id=h.device_id and e.created_at=h.moved_at
    ) saved
    order by saved.source_order,saved.source_id limit 1
  ) q
  where dst.location_code in ('PRODUCTION','READY','READY-STOCK')
    and h.from_location_id is distinct from h.to_location_id
    and (p_from is null or h.moved_at>=p_from)
    and (p_to is null or h.moved_at<p_to)
    and h.moved_at<=now()
    and (h.moved_at at time zone 'Asia/Dubai')::time between time '09:00' and time '21:00'
  order by h.moved_at,h.id limit p_limit;
$release$;
revoke all on function greenloop_private.rpta_ready_releases(timestamptz,timestamptz,integer)
from public,anon,authenticated;

create or replace function greenloop_private.rpta_facts(p_from date,p_to date)
returns table(kind text,activity_day date,job_id uuid,device_id uuid,occurred_at timestamptz,
  box_number text,export_grade text,final_grade text,model text,storage_gb integer,color text,batch_id uuid)
language sql stable security definer set search_path=pg_catalog,public as $facts$
  with bounds as (
    select p_from::timestamp at time zone 'Asia/Dubai' lo,(p_to+1)::timestamp at time zone 'Asia/Dubai' hi
  ), arrivals as (
    select 'ready'::text kind,r.job_id,r.device_id,r.occurred_at,null::text box_number,
      null::text export_grade,r.final_grade release_grade,r.tie
    from bounds b cross join lateral greenloop_private.rpta_ready_releases(b.lo,b.hi,null) r
  ), exports as (
    select 'export'::text kind,i.job_id,i.device_id,w.verified_at occurred_at,
      bx.box_number,i.final_grade export_grade,null::text release_grade,i.id tie
    from greenloop_private.box_workflow w
    join public.export_boxes bx on bx.id=w.box_id
    join public.export_box_items i on i.box_id=w.box_id
    cross join bounds b
    where w.state='exported' and w.verified_at is not null and i.scanned_at<=w.verified_at
      and w.verified_at>=b.lo and w.verified_at<b.hi and w.verified_at<=now()
    union all
    select 'export',r.job_id,j.device_id,r.dispatched_at,null,null,null,r.id
    from public.stock_out_records r join public.jobs j on j.id=r.job_id cross join bounds b
    where r.dispatched_at>=b.lo and r.dispatched_at<b.hi and r.dispatched_at<=now()
  ), selected as (
    select distinct on (f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.device_id) f.*
    from (select * from arrivals union all select * from exports) f
    join public.jobs j on j.id=f.job_id and j.device_id=f.device_id and j.deleted_at is null
    join public.devices d on d.id=f.device_id and d.deleted_at is null
    where f.kind='ready' or (f.occurred_at at time zone 'Asia/Dubai')::time between time '10:00' and time '21:00'
    order by f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.device_id,f.occurred_at,f.tie
  )
  select f.kind,(f.occurred_at at time zone 'Asia/Dubai')::date,f.job_id,f.device_id,f.occurred_at,
    f.box_number,f.export_grade,coalesce(f.release_grade,f.export_grade,q.final_grade,'Unspecified'),
    d.model,d.storage_gb,d.color,j.receiving_batch_id
  from selected f
  join public.jobs j on j.id=f.job_id
  join public.devices d on d.id=f.device_id
  left join lateral (
    select o.final_grade from greenloop_private.qdr_ready_outcomes o
    where f.kind='export' and o.job_id=f.job_id and o.inspected_at<=f.occurred_at
    order by o.inspected_at desc limit 1
  ) q on true;
$facts$;

-- Preserve the Export and Received branches of the existing earliest-date reader.
do $first$
declare
  definition text:=replace(pg_get_functiondef('greenloop_private.rpta_first(text)'::regprocedure),chr(13),'');
  revised text;
begin
  if strpos(definition,'greenloop_private.rpta_ready_releases(')>0 then return; end if;
  revised:=regexp_replace(definition,
    $old$(?s)(elsif[[:space:]]+p_kind[[:space:]]*=[[:space:]]*'ready'[[:space:]]*then).*?(elsif[[:space:]]+p_kind[[:space:]]*=[[:space:]]*'export'[[:space:]]*then)$old$,
    $new$\1
   select (r.occurred_at at time zone 'Asia/Dubai')::date into result
   from greenloop_private.rpta_ready_releases(null,null,1) r;
  \2$new$);
  if revised=definition then raise exception 'The first production date reader differs.';end if;
  execute revised;
end;
$first$;

update greenloop_private.stock_activity_installation
set hash=md5(pg_get_functiondef(to_regprocedure(identity)))
where to_regprocedure(identity) in (
  'greenloop_private.rpta_facts(date,date)'::regprocedure,
  'greenloop_private.rpta_first(text)'::regprocedure
);

-- The single-day groups and model views use the older daily adapter.
create or replace function greenloop_private.rsd_facts(p_date date)
returns table(kind text,job_id uuid,device_id uuid,occurred_at timestamptz,box_number text,export_grade text)
language sql stable security definer set search_path=pg_catalog,public as $day$
  select f.kind,f.job_id,f.device_id,f.occurred_at,f.box_number,
    case when f.kind='ready' then f.final_grade else f.export_grade end
  from greenloop_private.rpta_facts(p_date,p_date) f;
$day$;

do $daily_hours$
declare
  routine regprocedure:='greenloop_private.rsd_read(date,text,integer,integer)'::regprocedure;
  definition text:=pg_get_functiondef(routine);
  previous_hash text:=md5(definition);
  next_hash text;
  revised text;
begin
  if strpos(definition,'''export_starts_at''')>0 then return;end if;
  revised:=regexp_replace(definition,
    $old$'starts_at'[[:space:]]*,[[:space:]]*[(]day[[:space:]]*[+][[:space:]]*time '10:00'[)]$old$,
    $new$'export_starts_at',(day+time '10:00') at time zone 'Asia/Dubai',
          'starts_at',(day+case when p_kind='export' then time '10:00' else time '09:00' end)$new$);
  if revised=definition then raise exception 'The installed Daily Stock time label differs.';end if;
  execute revised;
  next_hash:=md5(pg_get_functiondef(routine));
  update greenloop_private.office_routines set original_hash=next_hash
    where to_regprocedure(implementation)=routine and original_hash=previous_hash;
end;
$daily_hours$;

update greenloop_private.ready_daily_installation
set hash=md5(pg_get_functiondef(to_regprocedure(identity)))
where kind='function' and to_regprocedure(identity) in (
  'greenloop_private.rsd_facts(date)'::regprocedure,
  'greenloop_private.rsd_read(date,text,integer,integer)'::regprocedure
);

create or replace function public.get_ready_production_count_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when
    not has_function_privilege('authenticated','greenloop_private.rpta_ready_releases(timestamptz,timestamptz,integer)','EXECUTE')
    and not has_function_privilege('anon','greenloop_private.rpta_ready_releases(timestamptz,timestamptz,integer)','EXECUTE')
    and (select count(*)=2 and bool_and(
      hash=md5(pg_get_functiondef(to_regprocedure(identity)))
      and strpos(pg_get_functiondef(to_regprocedure(identity)),'greenloop_private.rpta_ready_releases(')>0)
      from greenloop_private.stock_activity_installation where to_regprocedure(identity) in (
        'greenloop_private.rpta_facts(date,date)'::regprocedure,'greenloop_private.rpta_first(text)'::regprocedure
      ))
    and (select count(*)=2 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))))
      from greenloop_private.ready_daily_installation where kind='function' and to_regprocedure(identity) in (
        'greenloop_private.rsd_facts(date)'::regprocedure,'greenloop_private.rsd_read(date,text,integer,integer)'::regprocedure))
    and strpos(pg_get_functiondef('greenloop_private.rsd_facts(date)'::regprocedure),'greenloop_private.rpta_facts(')>0
    then '20261125-ready-production-count-1' end;
$version$;
revoke all on function public.get_ready_production_count_version() from public,anon,authenticated;
grant execute on function public.get_ready_production_count_version() to anon,authenticated;

do $verify$
begin
  if public.get_ready_production_count_version() is distinct from '20261125-ready-production-count-1' then
    raise exception 'The Ready Stock Production count could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_ready_production_count_version() as installed_ready_production_count_version;
