-- Inclusive UAE date ranges for the Ready Stock activity cards and their details.
begin;
set local search_path=pg_catalog,public;

do $require$
begin
  if public.get_stock_activity_reports_version() is distinct from '20261117-stock-activity-reports-1' then
    raise exception 'The verified Stock Activity Reports release is required.';
  end if;
end;
$require$;

create or replace function public.get_stock_activity_range_v1(
  p_from date,p_to date,p_kind text default null,p_expected text default null,
  p_view text default 'groups',p_group jsonb default null,p_model text default null,
  p_cell jsonb default null,p_offset integer default 0,p_show_color boolean default false,
  p_model_snapshot text default null
) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $function$
declare
  facts jsonb;
  receipts jsonb;
  summary jsonb;
  payload jsonb;
  token text;
  names boolean;
  scope jsonb;
begin
  perform greenloop_private.rpta_access(p_to,true);
  if p_from is null or p_from<date '1900-01-01' or p_from>p_to then
    raise exception 'Choose a valid From and To date.' using errcode='22023';
  end if;
  if p_offset is null or p_offset<0 or p_offset%50<>0
    or (p_kind is not null and p_kind not in ('ready','export','received')) then
    raise exception 'Choose a stock activity report and a valid 50-row page.' using errcode='22023';
  end if;

  names:=coalesce(public.get_my_partner_name_access(),false);
  select coalesce(jsonb_agg(to_jsonb(f) order by f.kind,f.activity_day,f.device_id),'[]'),
    jsonb_build_object('ready',count(*) filter(where f.kind='ready'),
      'export',count(*) filter(where f.kind='export'))
  into facts,summary from greenloop_private.rpta_facts(p_from,p_to) f;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.receipt_day,r.batch_id),'[]'),
    summary||jsonb_build_object('received',coalesce(sum(r.quantity),0))
  into receipts,summary from greenloop_private.rsr_receipts(p_from,p_to) r;

  token:=md5(jsonb_build_array(p_from,p_to,facts,receipts,names)::text);
  scope:=jsonb_build_object('range_from',p_from,'range_to',p_to,'activity_snapshot',token,'kind',p_kind);
  if p_kind is null then
    return scope||jsonb_build_object('reports',summary,'timezone','Asia/Dubai','as_of',now());
  end if;
  if p_expected is distinct from token then
    raise exception 'Stock activity changed. Refresh the reports and try again.' using errcode='40001';
  end if;

  if p_kind='received' then
    if p_view is distinct from 'receipts' then
      raise exception 'Choose the received stock list.' using errcode='22023';
    end if;
    with page as (
      select b.id batch_id,b.batch_number,b.invoice_number,b.received_at,
        r.quantity,b.planned_quantity,s.supplier_code,case when names then s.company_name end supplier_name
      from jsonb_to_recordset(receipts) r(batch_id uuid,quantity bigint)
      join public.receiving_batches b on b.id=r.batch_id
      left join public.suppliers s on s.id=b.supplier_id
      order by b.received_at,b.id offset p_offset limit 50
    )
    select jsonb_build_object('view','receipts','offset',p_offset,'limit',50,
      'total',jsonb_array_length(receipts),'quantity',summary->'received',
      'rows',coalesce(jsonb_agg(to_jsonb(p) order by p.received_at,p.batch_id),'[]'))
    into payload from page p;
  elsif p_view='groups' and p_model is null and p_cell is null and p_model_snapshot is null then
    payload:=greenloop_private.rpta_groups(p_kind,p_to,null,p_from,p_to,p_group,p_offset,50,p_show_color,facts);
  elsif p_view in ('models','breakdown','phones') and p_group is null then
    payload:=greenloop_private.rpta_models(p_kind,p_to,null,p_from,p_to,p_view,p_model,p_cell,
      p_offset,50,p_model_snapshot,facts);
  else
    raise exception 'Choose a valid activity group or model.' using errcode='22023';
  end if;
  return payload||scope;
end;
$function$;

revoke all on function public.get_stock_activity_range_v1(date,date,text,text,text,jsonb,text,jsonb,integer,boolean,text)
 from public,anon,authenticated;
grant execute on function public.get_stock_activity_range_v1(date,date,text,text,text,jsonb,text,jsonb,integer,boolean,text)
 to authenticated;

insert into greenloop_private.capability_rpc_rules(rpc_name,rule) values
 ('get_stock_activity_range_v1','{"page":"ready_stock","capability":"search","read":true}'),
 ('get_stock_activity_range_version','{"read":true}')
 on conflict(rpc_name) do update set rule=excluded.rule;
update greenloop_private.page_capability_installation
 set hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r)
 where identity='rules';

create table if not exists greenloop_private.stock_activity_range_installation(identity text primary key,hash text not null);
alter table greenloop_private.stock_activity_range_installation enable row level security;
revoke all on greenloop_private.stock_activity_range_installation from public,anon,authenticated;

create or replace function public.get_stock_activity_range_version() returns text
language sql stable security definer set search_path=pg_catalog,public as $function$
 select case when public.get_stock_activity_reports_version()='20261117-stock-activity-reports-1'
   and exists (
     select 1 from greenloop_private.stock_activity_range_installation
     where identity='public.get_stock_activity_range_v1(date,date,text,text,text,jsonb,text,jsonb,integer,boolean,text)'
       and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
       and has_function_privilege('authenticated',identity,'EXECUTE')
       and not has_function_privilege('anon',identity,'EXECUTE')
   )
   and exists (
     select 1 from greenloop_private.capability_rpc_rules where rpc_name='get_stock_activity_range_v1'
       and rule='{"page":"ready_stock","capability":"search","read":true}'
   )
 then '20261124-stock-activity-range-1' end;
$function$;

revoke all on function public.get_stock_activity_range_version() from public;
grant execute on function public.get_stock_activity_range_version() to anon,authenticated;
insert into greenloop_private.stock_activity_range_installation
select s,md5(pg_get_functiondef(to_regprocedure(s)))
from (values ('public.get_stock_activity_range_v1(date,date,text,text,text,jsonb,text,jsonb,integer,boolean,text)')) signature(s)
on conflict(identity) do update set hash=excluded.hash;

do $verify$
begin
  if public.get_stock_activity_range_version() is distinct from '20261124-stock-activity-range-1' then
    raise exception 'Stock activity date range could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_stock_activity_range_version() as installed_stock_activity_range_version;

