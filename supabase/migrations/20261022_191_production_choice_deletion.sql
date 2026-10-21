-- Remove choices completely from Daily Production selection/management.
-- Referenced identities stay private so existing entries and Restore remain valid.
begin;
do $$begin if public.get_production_delete_all_version() is distinct from '20261021-production-delete-all-1' then raise exception 'Install verified Production Delete All first.';end if;end;$$;

create table if not exists greenloop_private.production_option_deletions(
 id bigint generated always as identity primary key,option_id uuid not null,
 kind text not null,name text not null,removed_at timestamptz not null default clock_timestamp(),
 removed_by uuid,source text not null,retained_identity boolean not null
);
alter table greenloop_private.production_option_deletions enable row level security;
revoke all on greenloop_private.production_option_deletions from public,anon,authenticated;
revoke all on sequence greenloop_private.production_option_deletions_id_seq from public,anon,authenticated;
create index if not exists production_option_deletions_option on greenloop_private.production_option_deletions(option_id);
drop trigger if exists production_option_deletions_immutable on greenloop_private.production_option_deletions;
create trigger production_option_deletions_immutable before update or delete or truncate on greenloop_private.production_option_deletions for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();

-- Only active grades have selectable report permission ticks.
do $$declare definition text;begin
 definition:=pg_get_functiondef('greenloop_private.closing_stock_catalog()'::regprocedure);
 if strpos(definition,'where kind=''grade'' and active')=0 then
  definition:=replace(definition,'where kind=''grade'';','where kind=''grade'' and active;');
  if strpos(definition,'where kind=''grade'' and active')=0 then raise exception 'Unexpected grade catalog. Installation stopped.';end if;
 end if;
 definition:=replace(definition,'Add / remove Model, GB and Grade','Add / delete Model, GB and Grade');
 execute definition;
end;$$;

create or replace function greenloop_private.delete_production_option(p_id uuid,p_source text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare o greenloop_private.closing_stock_options;retained boolean;k text;ref record;used boolean;begin
 perform pg_advisory_xact_lock(17920261019);
 if p_id is null then raise exception 'Choose a Model, GB or Grade to delete.' using errcode='22023';end if;
 select * into o from greenloop_private.closing_stock_options where id=p_id for update;
 if not found then
  if exists(select 1 from greenloop_private.production_option_deletions where option_id=p_id) then return jsonb_build_object('deleted',true,'id',p_id,'replayed',true);end if;
  raise exception 'Choice not found. Refresh the page.' using errcode='22023';
 end if;
 if not o.active and exists(select 1 from greenloop_private.production_option_deletions where option_id=p_id) then return jsonb_build_object('deleted',true,'id',p_id,'replayed',true);end if;
 retained:=exists(select 1 from greenloop_private.closing_stock_audit where model_id=p_id or gb_id=p_id or grade_id=p_id)
  or exists(select 1 from greenloop_private.closing_stock_daily where model_id=p_id or gb_id=p_id or grade_id=p_id)
  or exists(select 1 from greenloop_private.closing_stock_correction_log where old_model_id=p_id or old_gb_id=p_id or old_grade_id=p_id or new_model_id=p_id or new_gb_id=p_id or new_grade_id=p_id)
  or exists(select 1 from greenloop_private.production_iphone_models_installation where option_id=p_id);
 if not retained then
  -- Also protect archived Stock Out or any other existing foreign-key reference.
  for ref in select c.conrelid,a.attname from pg_constraint c cross join lateral unnest(c.conkey) key(attnum) join pg_attribute a on a.attrelid=c.conrelid and a.attnum=key.attnum where c.contype='f' and c.confrelid='greenloop_private.closing_stock_options'::regclass loop
   execute format('select exists(select 1 from %s where %I=$1)',ref.conrelid::regclass,ref.attname) into used using p_id;
   if used then retained:=true;exit;end if;
  end loop;
 end if;
 insert into greenloop_private.production_option_deletions(option_id,kind,name,removed_by,source,retained_identity) values(o.id,o.kind,o.name,auth.uid(),p_source,retained);
 if retained then update greenloop_private.closing_stock_options set active=false where id=p_id;
 else delete from greenloop_private.closing_stock_options where id=p_id;end if;
 -- Installation cleanup has no signed-in actor; its immutable receipt is above.
 if auth.uid() is not null then insert into greenloop_private.closing_stock_option_audit(option_id,actor_id,action) values(p_id,auth.uid(),'delete');end if;
 if o.kind='grade' then
  k:=greenloop_private.closing_grade_key(p_id);
  update greenloop_private.user_page_capabilities u set capabilities=jsonb_set(u.capabilities,'{daily_production}',coalesce((select jsonb_agg(v order by ord) from jsonb_array_elements(u.capabilities->'daily_production') with ordinality t(v,ord) where v<>to_jsonb(k)),'[]'::jsonb)) where (u.capabilities->'daily_production')?k;
  perform greenloop_private.closing_stock_catalog();
 end if;
 return jsonb_build_object('deleted',true,'id',p_id,'name',o.name,'history_preserved',true);
end;$$;
create or replace function public.delete_production_option_v1(p_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.closing_stock_require('manage_options');
 return greenloop_private.delete_production_option(p_id,'manage_choices');
end;$$;
-- Cached clients get the same complete removal behavior.
create or replace function public.archive_closing_stock_option_v1(p_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.closing_stock_require('manage_options');
 perform greenloop_private.delete_production_option(p_id,'manage_choices');
end;$$;

-- Stop the explicitly removed grades from being added again by cached clients.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.save_closing_stock_option_v1(text,text)'::regprocedure);
 if strpos(definition,'Bulges A and Bulges B')=0 then
  definition:=replace(definition,'perform greenloop_private.closing_stock_require(''manage_options'');','perform greenloop_private.closing_stock_require(''manage_options'');
 if p_kind=''grade'' and regexp_replace(lower(n),''[^a-z0-9]'','''',''g'') in(''bulgesa'',''bulgesb'') then raise exception ''Bulges A and Bulges B have been removed from Daily Production.'' using errcode=''22023'';end if;');
  if strpos(definition,'Bulges A and Bulges B')=0 then raise exception 'Unexpected choice save function. Installation stopped.';end if;
  execute definition;
 end if;
end;$$;

-- Current and cached home endpoints expose active choices only.
do $$declare identity text;definition text;begin
 foreach identity in array array['public.get_period_stock_home_v1()','public.get_closing_stock_home_v1()'] loop
  definition:=pg_get_functiondef(identity::regprocedure);
  definition:=replace(definition,'from greenloop_private.closing_stock_options o;','from greenloop_private.closing_stock_options o where o.active;');
  definition:=replace(definition,'where o.kind=''grade'' and public.has_page_capability_v1','where o.kind=''grade'' and o.active and public.has_page_capability_v1');
  execute definition;
 end loop;
end;$$;

-- Snapshot existing effective permissions before removing only retired grade keys.
do $$declare u record;o record;begin
 for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
  insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
 end loop;
 for o in select id from greenloop_private.closing_stock_options where kind='grade' and regexp_replace(lower(name),'[^a-z0-9]','','g') in('bulgesa','bulgesb') loop
  perform greenloop_private.delete_production_option(o.id,'requested_bulges_cleanup');
 end loop;
end;$$;
select greenloop_private.closing_stock_catalog();
update greenloop_private.user_page_capabilities u set capabilities=jsonb_set(u.capabilities,'{daily_production}',coalesce((select jsonb_agg(v order by ord) from jsonb_array_elements(u.capabilities->'daily_production') with ordinality t(v,ord) where v#>>'{}' not like 'grade_%' or exists(select 1 from greenloop_private.page_capability_catalog c cross join lateral jsonb_array_elements(c.capabilities)x where c.page_key='daily_production' and x->>'key'=v#>>'{}')),'[]'::jsonb)) where jsonb_typeof(u.capabilities->'daily_production')='array';

-- Record the reviewed replacements in earlier verification receipts.
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity) in('greenloop_private.closing_stock_catalog()'::regprocedure,'public.save_closing_stock_option_v1(text,text)'::regprocedure,'public.archive_closing_stock_option_v1(uuid)'::regprocedure,'public.get_closing_stock_home_v1()'::regprocedure);
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.production_period_totals_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where to_regprocedure(identity)='public.get_period_stock_home_v1()'::regprocedure;

create table if not exists greenloop_private.production_choice_deletion_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_choice_deletion_installation enable row level security;
revoke all on greenloop_private.production_choice_deletion_installation from public,anon,authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','greenloop_private') and p.proname in('delete_production_option','delete_production_option_v1','archive_closing_stock_option_v1','save_closing_stock_option_v1','closing_stock_catalog','get_period_stock_home_v1','get_closing_stock_home_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
  insert into greenloop_private.production_choice_deletion_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$$;
insert into greenloop_private.production_choice_deletion_installation values('audit_trigger',(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='production_option_deletions_immutable' and tgrelid='greenloop_private.production_option_deletions'::regclass)) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_choice_deletion_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_delete_all_version()='20261021-production-delete-all-1'
 and (select count(*)=7 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.production_choice_deletion_installation where identity<>'audit_trigger')
 and exists(select 1 from greenloop_private.production_choice_deletion_installation where identity='audit_trigger' and hash=(select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgname='production_option_deletions_immutable' and tgrelid='greenloop_private.production_option_deletions'::regclass))
 and not exists(select 1 from greenloop_private.closing_stock_options where active and kind='grade' and regexp_replace(lower(name),'[^a-z0-9]','','g') in('bulgesa','bulgesb'))
 and not exists(select 1 from unnest(array['greenloop_private.production_choice_deletion_installation','greenloop_private.production_option_deletions'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or not(select relrowsecurity from pg_class where oid=t::regclass))
 then '20261022-production-choice-deletion-1' end;
$$;
revoke all on function public.get_production_choice_deletion_version() from public;
grant execute on function public.get_production_choice_deletion_version() to anon,authenticated;
do $$begin if public.get_production_choice_deletion_version() is distinct from '20261022-production-choice-deletion-1' then raise exception 'Production choice deletion verification failed.';end if;end;$$;
notify pgrst,'reload schema';
commit;
select public.get_production_choice_deletion_version() as installed_production_choice_deletion_version;
