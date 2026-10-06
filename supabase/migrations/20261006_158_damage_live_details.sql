-- Read-only complete incident details for Live Damage Report headlines.
-- Existing card functions, records, corrections and permissions are preserved.
begin;
do $preflight$ begin
 if public.get_manual_damage_export_version() is distinct from '20261006-damage-report-pdf-1' then
  raise exception 'Install the verified Damage Report PDF update first.' using errcode='55000';
 end if;
 if to_regprocedure('public.get_damage_live_details_version()') is not null then
  if public.get_damage_live_details_version() is distinct from '20261006-damage-live-details-1' then
   raise exception 'Existing Live Damage Details update differs. Nothing installed.' using errcode='55000';
  end if;
 elsif to_regprocedure('public.get_manual_damage_cards_v3(integer,integer,integer)') is not null
 or to_regclass('greenloop_private.damage_live_details_installation') is not null then
  raise exception 'Unexpected Live Damage Details objects. Nothing installed.' using errcode='55000';
 end if;
end; $preflight$;

create or replace function public.get_manual_damage_cards_v3(
 p_offset integer default 0,p_limit integer default 4,p_row_limit integer default 6
)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $cards$
declare v_board jsonb; v_activity jsonb;
begin
 if not greenloop_private.damage_report_access() then
  raise exception 'Damage Report view permission is required.' using errcode='42501';
 end if;
 v_board:=public.get_manual_damage_cards_v2(p_offset,p_limit,p_row_limit);
 -- Enrich exactly the same latest incident IDs within this statement's snapshot.
 -- Explicit public-facing fields exclude request IDs and internal user IDs.
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'damaged_by',r.damaged_by,'model',r.model,'identifier',r.identifier,
  'part_name',r.part_name,'quantity',r.quantity,'price_amount',r.price_amount,
  'currency',r.currency,'part_source',r.part_source,'reason',r.reason,
  'occurred_at',r.occurred_at,'reported_by',r.reported_by,'created_at',r.created_at
 ) order by r.created_at desc,r.id desc),'[]'::jsonb) into v_activity
 from greenloop_private.manual_damage_effective r
 where r.id in (select (entry->>'id')::uuid from jsonb_array_elements(v_board->'activity') entry);
 return jsonb_set(v_board,'{activity}',v_activity);
end;
$cards$;
revoke all on function public.get_manual_damage_cards_v3(integer,integer,integer) from public,anon;
grant execute on function public.get_manual_damage_cards_v3(integer,integer,integer) to authenticated;

create table if not exists greenloop_private.damage_live_details_installation(
 singleton boolean primary key default true check(singleton),definition_hash text not null);
alter table greenloop_private.damage_live_details_installation enable row level security;
revoke all on greenloop_private.damage_live_details_installation from public,anon,authenticated;
insert into greenloop_private.damage_live_details_installation(singleton,definition_hash)
 values(true,md5(pg_get_functiondef('public.get_manual_damage_cards_v3(integer,integer,integer)'::regprocedure)))
 on conflict(singleton) do update set definition_hash=excluded.definition_hash;
create or replace function public.get_damage_live_details_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
 select case when public.get_manual_damage_export_version()='20261006-damage-report-pdf-1'
 and exists(select 1 from greenloop_private.damage_live_details_installation
  where definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v3(integer,integer,integer)'::regprocedure)))
 and not has_function_privilege('anon','public.get_manual_damage_cards_v3(integer,integer,integer)','EXECUTE')
 and has_function_privilege('authenticated','public.get_manual_damage_cards_v3(integer,integer,integer)','EXECUTE')
 then '20261006-damage-live-details-1' else null end;
$version$;
revoke all on function public.get_damage_live_details_version() from public;
grant execute on function public.get_damage_live_details_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_damage_live_details_version() as installed_damage_live_details_version;
