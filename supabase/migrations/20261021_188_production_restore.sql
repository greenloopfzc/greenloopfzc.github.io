-- Restore individual deleted box counts, retaining their original identity/date.
-- Installation does not restore, purge or rewrite any existing entry or history.
begin;
do $$begin if public.get_requested_rollback_version() is distinct from '20261021-requested-rollback-1' then raise exception 'Install the verified rollback retaining 6 PM dates and TV settings first.';end if;end;$$;

do $$declare u record;c jsonb;begin
 if not exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"production_restore"}]') then
  -- Freeze existing effective grants before introducing a new staff action.
  for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
   insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
  end loop;
  update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"production_restore","label":"Restore deleted Daily Production entries","write":true}]'::jsonb where page_key='reports';
  for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where not greenloop_private.damage_tv_only(p.id) and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p.id and r.role_key::text in('owner','super_admin')) loop
   c:=u.caps;if (c->'reports')?'view' and not(c->'reports')?'production_restore' then
    update greenloop_private.user_page_capabilities set capabilities=jsonb_set(c,'{reports}',(c->'reports')||'["production_restore"]') where user_id=u.id;
   end if;
  end loop;
 end if;
end;$$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';

alter table greenloop_private.closing_stock_correction_log drop constraint if exists closing_stock_correction_log_action_check;
alter table greenloop_private.closing_stock_correction_log add constraint closing_stock_correction_log_action_check check(action in('edit','delete','restore'));
drop trigger if exists closing_stock_correction_log_immutable on greenloop_private.closing_stock_correction_log;
create trigger closing_stock_correction_log_immutable before update or delete or truncate on greenloop_private.closing_stock_correction_log for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();

-- A Restore-only account may find the original entry and inspect its history.
do $$declare f record;definition text;begin
 for f in select p.oid from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('get_closing_stock_entries_v1','get_closing_stock_entry_changes_v1') loop
  definition:=pg_get_functiondef(f.oid);
  if strpos(definition,'production_restore')=0 then
   definition:=replace(definition,'or public.has_page_capability_v1(''reports'',''production_delete''))','or public.has_page_capability_v1(''reports'',''production_delete'') or public.has_page_capability_v1(''reports'',''production_restore''))');
   if strpos(definition,'production_restore')=0 then raise exception 'Unexpected production history reader. Installation stopped.';end if;
   execute definition;
  end if;
 end loop;
end;$$;

create or replace function public.restore_closing_stock_entry_v1(p_entry bigint,p_expected_revision integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.closing_stock_audit;begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not public.has_page_capability_v1('reports','production_restore') then raise exception 'Restore Daily Production permission required.' using errcode='42501';end if;
 if p_entry is null or p_expected_revision is null or p_expected_revision<0 then raise exception 'Choose a deleted entry and refresh its current revision.' using errcode='22023';end if;
 -- Use the same locks as normal saves, undo, edits and deletion.
 perform pg_advisory_xact_lock(17920261019);
 select * into a from greenloop_private.closing_stock_audit where id=p_entry for update;
 if not found then raise exception 'Entry not found. Refresh the report.' using errcode='22023';end if;
 if a.correction_revision<>p_expected_revision then raise exception 'This entry changed. Refresh before restoring.' using errcode='40001';end if;
 if a.undone_at is null then raise exception 'This entry is already active. It was not added again.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-pair:'||a.model_id||a.gb_id||a.grade_id,0));
 insert into greenloop_private.closing_stock_correction_log(entry_id,action,actor_id,actor_name,old_model_id,old_gb_id,old_grade_id,old_quantity,new_model_id,new_gb_id,new_grade_id,new_quantity)
 values(a.id,'restore',auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),a.model_id,a.gb_id,a.grade_id,a.count_quantity,a.model_id,a.gb_id,a.grade_id,a.count_quantity);
 update greenloop_private.closing_stock_audit set undone_at=null,correction_revision=correction_revision+1 where id=a.id;
 perform greenloop_private.recalculate_closing_pair_day(a.model_id,a.gb_id,a.grade_id,a.stock_date);
 return jsonb_build_object('saved',true,'entry_id',a.id,'action','restore','revision',a.correction_revision+1,'stock_date',a.stock_date);
end;$$;
revoke all on function public.restore_closing_stock_entry_v1(bigint,integer) from public,anon;
grant execute on function public.restore_closing_stock_entry_v1(bigint,integer) to authenticated;

create table if not exists greenloop_private.production_restore_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_restore_installation enable row level security;
revoke all on greenloop_private.production_restore_installation from public,anon,authenticated;
insert into greenloop_private.production_restore_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('restore_closing_stock_entry_v1','get_closing_stock_entries_v1','get_closing_stock_entry_changes_v1')
 on conflict(identity) do update set hash=excluded.hash;
insert into greenloop_private.production_restore_installation values('action_check',(select md5(pg_get_constraintdef(oid)) from pg_constraint where conrelid='greenloop_private.closing_stock_correction_log'::regclass and conname='closing_stock_correction_log_action_check')),('audit_trigger',(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='closing_stock_correction_log_immutable' and tgrelid='greenloop_private.closing_stock_correction_log'::regclass)) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_restore_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_requested_rollback_version()='20261021-requested-rollback-1'
 and (select count(*)=3 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')) from greenloop_private.production_restore_installation where identity not in('action_check','audit_trigger'))
 and exists(select 1 from greenloop_private.production_restore_installation where identity='action_check' and hash=(select md5(pg_get_constraintdef(oid)) from pg_constraint where conrelid='greenloop_private.closing_stock_correction_log'::regclass and conname='closing_stock_correction_log_action_check'))
 and exists(select 1 from greenloop_private.production_restore_installation where identity='audit_trigger' and hash=(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='closing_stock_correction_log_immutable' and tgrelid='greenloop_private.closing_stock_correction_log'::regclass))
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"production_restore","write":true}]')
 and not exists(select 1 from unnest(array['greenloop_private.production_restore_installation','greenloop_private.closing_stock_correction_log'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or not(select relrowsecurity from pg_class where oid=t::regclass))
 then '20261021-production-restore-1' end;
$$;
revoke all on function public.get_production_restore_version() from public;
grant execute on function public.get_production_restore_version() to anon,authenticated;
do $$begin if public.get_production_restore_version() is distinct from '20261021-production-restore-1' then raise exception 'Production Restore verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_restore_version() as installed_production_restore_version;
