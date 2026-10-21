-- Reports-only bulk deletion of independent Daily Production box counts.
-- Installing this update never deletes records. Execution requires a separate
-- permission, a reviewed snapshot and explicit typed confirmation.
begin;
do $$begin if public.get_production_period_totals_version() is distinct from '20261021-production-period-totals-1' then raise exception 'Install verified Production Period Totals first.';end if;end;$$;

do $$declare u record;c jsonb;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"production_delete_all"}]') then
  for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
   insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
  end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"production_delete_all","label":"Delete all Daily Production data (all dates)","write":true}]'::jsonb where page_key='reports';
  for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where not greenloop_private.damage_tv_only(p.id) and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p.id and r.role_key::text in('owner','super_admin')) loop
   c:=u.caps;if (c->'reports')?'view' and not(c->'reports')?'production_delete_all' then
    update greenloop_private.user_page_capabilities set capabilities=jsonb_set(c,'{reports}',(c->'reports')||'["production_delete_all"]') where user_id=u.id;
   end if;
  end loop;
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';

-- A bulk-delete grant can open this report and inspect the affected history.
do $$declare f record;definition text;begin
 for f in select p.oid from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_closing_stock_entries_v1','get_closing_stock_entry_changes_v1') loop
  definition:=pg_get_functiondef(f.oid);
  if strpos(definition,'production_delete_all')=0 then
   definition:=replace(definition,'or public.has_page_capability_v1(''reports'',''production_restore''))','or public.has_page_capability_v1(''reports'',''production_restore'') or public.has_page_capability_v1(''reports'',''production_delete_all''))');
   if strpos(definition,'production_delete_all')=0 then raise exception 'Unexpected production history reader. Installation stopped.';end if;
   execute definition;
  end if;
 end loop;
end;$$;
update greenloop_private.production_restore_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity not in('action_check','audit_trigger');

create table if not exists greenloop_private.production_clear_batches(
 request_id uuid primary key,actor_id uuid not null,actor_name text not null,
 cleared_at timestamptz not null default clock_timestamp(),fingerprint text not null,
 entry_ids bigint[] not null,entries bigint not null,quantity bigint not null,
 first_day date,last_day date
);
alter table greenloop_private.production_clear_batches enable row level security;
revoke all on greenloop_private.production_clear_batches from public,anon,authenticated;
drop trigger if exists production_clear_batches_immutable on greenloop_private.production_clear_batches;
create trigger production_clear_batches_immutable before update or delete or truncate on greenloop_private.production_clear_batches for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();

create or replace function greenloop_private.production_clear_require()
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not public.has_page_capability_v1('reports','production_delete_all') then raise exception 'Delete all Daily Production permission required.' using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.production_clear_snapshot()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('entries',count(*),'quantity',coalesce(sum(count_quantity),0),
  'first_day',min(greenloop_private.production_period_day(recorded_at)-1),'last_day',max(greenloop_private.production_period_day(recorded_at)-1),
  'fingerprint',md5(coalesce(string_agg(id::text||':'||correction_revision::text,',' order by id),'')))
 from greenloop_private.closing_stock_audit where undone_at is null;
$$;
create or replace function public.review_all_production_deletion_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.production_clear_require();
 return greenloop_private.production_clear_snapshot()||jsonb_build_object('scope','all_daily_production','restorable',true);
end;$$;
create or replace function public.delete_all_production_entries_v1(p_request uuid,p_fingerprint text,p_confirmation text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare snapshot jsonb;ids bigint[];pair record;batch greenloop_private.production_clear_batches;who text;begin
 perform greenloop_private.production_clear_require();
 if p_request is null or p_confirmation is distinct from 'DELETE ALL' or p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{32}$' then raise exception 'Review the full Daily Production count and type DELETE ALL to confirm.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(17920261019);
 select * into batch from greenloop_private.production_clear_batches where request_id=p_request;
 if found then
  if batch.actor_id<>auth.uid() or batch.fingerprint<>p_fingerprint then raise exception 'This deletion request belongs to a different review.' using errcode='22023';end if;
  return jsonb_build_object('deleted',true,'entries',batch.entries,'quantity',batch.quantity,'replayed',true,'scope','all_daily_production');
 end if;
 snapshot:=greenloop_private.production_clear_snapshot();
 if snapshot->>'fingerprint'<>p_fingerprint then raise exception 'Daily Production entries changed. Review the updated totals before deleting.' using errcode='40001';end if;
 if (snapshot->>'entries')::bigint=0 then raise exception 'There are no active Daily Production entries to delete.' using errcode='22023';end if;
 select array_agg(id order by id) into ids from greenloop_private.closing_stock_audit where undone_at is null;
 who:=coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff');
 insert into greenloop_private.closing_stock_correction_log(entry_id,action,actor_id,actor_name,old_model_id,old_gb_id,old_grade_id,old_quantity)
 select id,'delete',auth.uid(),who,model_id,gb_id,grade_id,count_quantity from greenloop_private.closing_stock_audit where id=any(ids);
 update greenloop_private.closing_stock_audit set undone_at=clock_timestamp(),correction_revision=correction_revision+1 where id=any(ids);
 for pair in select distinct model_id,gb_id,grade_id,stock_date from greenloop_private.closing_stock_audit where id=any(ids) order by model_id,gb_id,grade_id,stock_date loop
  perform greenloop_private.recalculate_closing_pair_day(pair.model_id,pair.gb_id,pair.grade_id,pair.stock_date);
 end loop;
 insert into greenloop_private.production_clear_batches(request_id,actor_id,actor_name,fingerprint,entry_ids,entries,quantity,first_day,last_day)
 values(p_request,auth.uid(),who,p_fingerprint,ids,(snapshot->>'entries')::bigint,(snapshot->>'quantity')::bigint,(snapshot->>'first_day')::date,(snapshot->>'last_day')::date);
 return jsonb_build_object('deleted',true,'entries',(snapshot->>'entries')::bigint,'quantity',(snapshot->>'quantity')::bigint,'replayed',false,'scope','all_daily_production');
end;$$;

create table if not exists greenloop_private.production_delete_all_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_delete_all_installation enable row level security;
revoke all on greenloop_private.production_delete_all_installation from public,anon,authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','greenloop_private') and p.proname in('production_clear_require','production_clear_snapshot','review_all_production_deletion_v1','delete_all_production_entries_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
  insert into greenloop_private.production_delete_all_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$$;
insert into greenloop_private.production_delete_all_installation values('batch_trigger',(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='production_clear_batches_immutable' and tgrelid='greenloop_private.production_clear_batches'::regclass)) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_delete_all_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_period_totals_version()='20261021-production-period-totals-1'
 and (select count(*)=4 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(select pronamespace='public'::regnamespace from pg_proc where oid=to_regprocedure(identity))) from greenloop_private.production_delete_all_installation where identity<>'batch_trigger')
 and exists(select 1 from greenloop_private.production_delete_all_installation where identity='batch_trigger' and hash=(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='production_clear_batches_immutable' and tgrelid='greenloop_private.production_clear_batches'::regclass))
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"production_delete_all","write":true}]')
 and not exists(select 1 from unnest(array['greenloop_private.production_clear_batches','greenloop_private.production_delete_all_installation'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or not(select relrowsecurity from pg_class where oid=t::regclass))
 then '20261021-production-delete-all-1' end;
$$;
revoke all on function public.get_production_delete_all_version() from public;
grant execute on function public.get_production_delete_all_version() to anon,authenticated;
do $$begin if public.get_production_delete_all_version() is distinct from '20261021-production-delete-all-1' then raise exception 'Production Delete All verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_delete_all_version() as installed_production_delete_all_version;
