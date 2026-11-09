-- Independent Lab & Glass Issuance permissions. Existing business records are untouched.
do $qcia_install$begin
do $$declare component text;probe jsonb;begin
 if to_regprocedure('public.get_issuance_access_version()')is not null then
  if public.get_issuance_access_version()is distinct from '20261109-issuance-access-1'then raise exception 'Existing Issuance access integrity differs.';end if;
 end if;
 if public.get_installation_component_engine_version()is distinct from '20261107-installation-components-1'then raise exception 'Verified component support is required.';end if;
 foreach component in array array['get_complete_stock_lists_version','get_qc_issuance_edit_version','get_sidebar_counts_version','get_qc_work_options_version','get_qc_duplicate_stage_version']loop
 probe:=public.get_installation_component_version(component);if probe#>>'{result,ok}'is distinct from 'true'then raise exception 'Existing required component could not be verified: %',component;end if;end loop;
end;$$;
create or replace function greenloop_private.qcia_require(write_access boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('qc_issuance',case when write_access then 'entry'else 'view'end);
end;$$;
revoke all on function greenloop_private.qcia_require(boolean)from public,anon,authenticated;
create or replace function pg_temp.qcia_patch(sig text,needle text,replacement text)returns void language plpgsql as $$declare id regprocedure:=to_regprocedure(sig);body text;begin
 if id is null then raise exception 'Issuance permission routine missing: %',sig;end if;body:=replace(pg_get_functiondef(id),chr(13),'');
 if position(replacement in body)>0 then return;end if;
 if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Issuance permission boundary differs: %',sig;end if;
 execute replace(body,needle,replacement);
end;$$;
do $patch$declare f record;sig text;definition text;begin
 for f in select *from(values
 ('public.get_stock_receipt_catalog_v1(text)',$n$'imei_entry','initial_qc','lab_glass'$n$,$n$'imei_entry','initial_qc','qc_issuance','lab_glass'$n$),
 ('public.get_qc_issuance_options_v1()','greenloop_private.qcis_require()','greenloop_private.qcia_require()'),
 ('public.get_qc_issuance_rows_v1(text[],date,date,integer,integer)','greenloop_private.qcis_require()','greenloop_private.qcia_require()'),
 ('public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)','greenloop_private.qcis_require(true)','greenloop_private.qcia_require(true)'),
 ('public.get_qc_work_options_v1(text)', $n$p_page not in('initial_qc','lab_glass')$n$,$n$p_page not in('initial_qc','lab_glass','qc_issuance')$n$)
 )x(public_sig,needle,replacement)loop
  select implementation into strict sig from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure(f.public_sig);
  perform pg_temp.qcia_patch(sig,f.needle,f.replacement);
 end loop;
 select implementation into strict sig from greenloop_private.office_routines where to_regprocedure(identity)='public.get_qc_issuance_rows_v1(text[],date,date,integer,integer)'::regprocedure;
 perform pg_temp.qcia_patch(sig,$n$pf_cap('initial_qc','search')$n$,$n$pf_cap('qc_issuance','search')$n$);
 select implementation into strict sig from greenloop_private.office_routines where to_regprocedure(identity)='public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure;
 perform pg_temp.qcia_patch(sig,$n$greenloop_require_entry(array['initial_qc']::text[])$n$,$n$greenloop_require_entry(array['qc_issuance']::text[])$n$);
 perform pg_temp.qcia_patch('greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)','greenloop_private.qcis_require(true)','greenloop_private.qcia_require(true)');
 perform pg_temp.qcia_patch('greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)',$n$greenloop_require_entry(array['initial_qc']::text[])$n$,$n$greenloop_require_entry(array['qc_issuance']::text[])$n$);
 perform pg_temp.qcia_patch('greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)','catalog:=public.get_ranked_qc_dropdowns_v1()','catalog:=public.get_qc_issuance_choices_v1()');
 perform pg_temp.qcia_patch('greenloop_private.qdr_stock_selection(text,jsonb,integer,integer)','perform greenloop_private.qcis_require();', $n$if p_stage='issuance'then perform greenloop_private.qcia_require();else perform greenloop_private.qcis_require();end if;$n$);
 perform pg_temp.qcia_patch('greenloop_private.qdr_stock_selection(text,jsonb,integer,integer)',$n$pf_cap('initial_qc','search')$n$,$n$pf_cap(case when p_stage='issuance'then 'qc_issuance'else 'initial_qc'end,'search')$n$);
 select oid::regprocedure::text into strict sig from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'cap_impl_%'and position('v_allowed_pages' in prosrc)>0 and position('p_user_id' in prosrc)>0;
 perform pg_temp.qcia_patch(sig,$n$'imei_search','initial_qc','lab_glass'$n$,$n$'imei_search','initial_qc','qc_issuance','lab_glass'$n$);
 -- Supplier-return lookup accepts this new operational page, retaining all existing restrictions.
 select implementation into strict sig from greenloop_private.office_routines where to_regprocedure(identity)='public.get_imei_duplicate_stage_v1(text)'::regprocedure;
 if position($n$'stock_received','imei_entry','initial_qc','lab_glass'$n$ in pg_get_functiondef(sig::regprocedure))>0 then
 perform pg_temp.qcia_patch(sig,$n$'stock_received','imei_entry','initial_qc','lab_glass'$n$,$n$'stock_received','imei_entry','initial_qc','qc_issuance','lab_glass'$n$);end if;
end;$patch$;
-- Extend just the page-key constraint; access levels and all other constraints stay unchanged.
do $$declare clause text;begin
 select pg_get_constraintdef(oid)into strict clause from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check';
 if position('qc_issuance' in clause)=0 then
  alter table public.user_page_permissions drop constraint user_page_permissions_page_key_check;
  execute 'alter table public.user_page_permissions add constraint user_page_permissions_page_key_check check (page_key=''qc_issuance'' or '||substring(clause from 7)||')';
 end if;
end;$$;
insert into greenloop_private.page_capability_catalog values('qc_issuance','[{"key":"view","label":"View page","write":false},{"key":"search","label":"Search & stock filters","write":false},{"key":"entry","label":"Edit Parts / Services, assign & transfer phones","write":true}]')on conflict(page_key)do update set capabilities=excluded.capabilities;
-- One-time copy of effective Initial QC access preserves who can already use Issuance.
do $$begin if to_regprocedure('public.get_issuance_access_version()')is null then
 insert into public.user_page_permissions(user_id,page_key,access_level,assigned_by)
 select user_id,'qc_issuance',case when caps?'entry'then 'edit'else 'view'end,null from (select p.id user_id,greenloop_private.user_capabilities(p.id)->'initial_qc' caps from public.user_profiles p) e where caps?'view' on conflict(user_id,page_key)do nothing;
 update greenloop_private.user_page_capabilities u set capabilities=u.capabilities||jsonb_build_object('qc_issuance',coalesce((select jsonb_agg(v)from jsonb_array_elements_text(e.caps)v where v in('view','search','entry')),'[]'))from (select p.id user_id,greenloop_private.user_capabilities(p.id)->'initial_qc' caps from public.user_profiles p) e where u.user_id=e.user_id and not u.capabilities?'qc_issuance';
end if;end;$$;
create or replace function greenloop_private.qcia_choices()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.qcia_require();return greenloop_private.rank_work_options(public.get_qc_work_options_v1('qc_issuance'),greenloop_private.qc_work_usage_v1());end;$$;
revoke all on function greenloop_private.qcia_choices()from public,anon,authenticated;
create or replace function public.get_qc_issuance_choices_v1()returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.qcia_choices();end;$$;
revoke all on function public.get_qc_issuance_choices_v1()from public,anon,authenticated;grant execute on function public.get_qc_issuance_choices_v1()to authenticated;
insert into greenloop_private.office_routines values('public.get_qc_issuance_choices_v1()','greenloop_private.qcia_choices()',md5(pg_get_functiondef('greenloop_private.qcia_choices()'::regprocedure)),md5(pg_get_functiondef('public.get_qc_issuance_choices_v1()'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_options_v1','{"page":"qc_issuance","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_rows_v1','{"page":"qc_issuance","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_issuance_choices_v1','{"page":"qc_issuance","capability":"view","read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('issue_initial_qc_inspection_v1','{"page":"qc_issuance","capability":"entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('update_qc_issuance_requirements_v1','{"page":"qc_issuance","capability":"entry"}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_stock_selection_v1','{"dynamic":"filter_source","parameter":"p_stage","inspection":{"page":"initial_qc","capability":"view","read":true},"issuance":{"page":"qc_issuance","capability":"view","read":true}}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_qc_work_options_v1','{"dynamic":"filter_source","parameter":"p_page","initial_qc":{"page":"initial_qc","capability":"view","read":true},"lab_glass":{"page":"lab_glass","capability":"view","read":true},"qc_issuance":{"page":"qc_issuance","capability":"view","read":true}}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_stock_receipt_catalog_v1','{"dynamic":"filter_source","parameter":"p_page","overview":{"page":"overview","capability":"view","read":true},"stock_received":{"page":"stock_received","capability":"view","read":true},"imei_entry":{"page":"imei_entry","capability":"view","read":true},"initial_qc":{"page":"initial_qc","capability":"view","read":true},"lab_glass":{"page":"lab_glass","capability":"view","read":true},"parts":{"page":"parts","capability":"view","read":true},"final_qc":{"page":"final_qc","capability":"view","read":true},"frame_department":{"page":"frame_department","capability":"view","read":true},"ready_stock":{"page":"ready_stock","capability":"view","read":true},"export_boxes":{"page":"export_boxes","capability":"view","read":true},"stock_exported":{"page":"stock_exported","capability":"view","read":true},"ready_stock_journey":{"page":"ready_stock_journey","capability":"view","read":true},"imei_search":{"page":"imei_search","capability":"view","read":true},"accounts":{"page":"accounts","capability":"view","read":true},"supplier_returns":{"page":"supplier_returns","capability":"view","read":true},"supplier_return_approval":{"page":"supplier_return_approval","capability":"view","read":true},"supplier_return_handover":{"page":"supplier_return_handover","capability":"view","read":true},"reports":{"page":"reports","capability":"view","read":true},"qc_issuance":{"page":"qc_issuance","capability":"view","read":true}}')on conflict(rpc_name)do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_issuance_access_version','{"read":true}')on conflict(rpc_name)do update set rule=excluded.rule;
-- An independently authorized Issuance viewer receives its own pending badge.
do $$begin perform pg_temp.qcia_patch('greenloop_private.sbn_counts()',
 $n$if greenloop_private.sbn_can('lab_glass')then$n$,
 $n$if greenloop_private.sbn_can('qc_issuance')then
 select count(*)into n from greenloop_private.qcis_rows(null);result:=result||jsonb_build_object('qc_issuance',n);
 elsif not greenloop_private.sbn_can('initial_qc')then result:=result-'qc_issuance';end if;
 if greenloop_private.sbn_can('lab_glass')then$n$);end;$$;
-- Its prior marker seals the original Initial QC mapping; require the new independent mapping instead.
do $$declare original text;body text;newhash text;begin
 select md5(replace(replace(prosrc,chr(13)||chr(10),chr(10)),chr(13),chr(10)))into original from pg_proc where oid='public.get_qc_issuance_edit_version()'::regprocedure;
 perform pg_temp.qcia_patch('public.get_qc_issuance_edit_version()',$n${"page":"initial_qc","capability":"entry"}$n$,$n${"page":"qc_issuance","capability":"entry"}$n$);
 select md5(replace(replace(prosrc,chr(13)||chr(10),chr(10)),chr(13),chr(10)))into newhash from pg_proc where oid='public.get_qc_issuance_edit_version()'::regprocedure;
 if original<>newhash then
 body:=pg_get_functiondef('greenloop_private.vc2_catalog()'::regprocedure);
 if position(original in body)=0 then raise exception 'Issuance verifier marker is not the reviewed version.';end if;
 execute replace(body,original,newhash);
 update greenloop_private.installation_component_engine set hash=md5(pg_get_functiondef('greenloop_private.vc2_catalog()'::regprocedure))where identity='greenloop_private.vc2_catalog()';
 end if;
end;$$;
create or replace function pg_temp.qcia_ids()returns regprocedure[]language plpgsql as $ids$declare ids regprocedure[];core regprocedure;begin
 select array_agg(to_regprocedure(implementation))into ids from greenloop_private.office_routines where to_regprocedure(identity)=any(array[
 'public.get_stock_receipt_catalog_v1(text)'::regprocedure,'public.get_qc_issuance_options_v1()'::regprocedure,'public.get_qc_issuance_rows_v1(text[],date,date,integer,integer)'::regprocedure,'public.issue_initial_qc_inspection_v1(uuid,text,text,uuid,uuid)'::regprocedure,'public.get_qc_work_options_v1(text)'::regprocedure,'public.get_imei_duplicate_stage_v1(text)'::regprocedure]);
 if cardinality(ids)<>6 or array_position(ids,null)is not null then raise exception 'Issuance permission routines could not be resolved.';end if;
 select oid::regprocedure into strict core from pg_proc where pronamespace='greenloop_private'::regnamespace and proname like 'cap_impl_%'and position('v_allowed_pages' in prosrc)>0 and position('p_user_id' in prosrc)>0;
 return ids||array[core,'greenloop_private.qcie_save(uuid,text,jsonb,jsonb,uuid)'::regprocedure,'greenloop_private.qdr_stock_selection(text,jsonb,integer,integer)'::regprocedure,'greenloop_private.sbn_counts()'::regprocedure,'public.get_qc_issuance_edit_version()'::regprocedure];end;$ids$;
-- Reseal only the exact reviewed permission routines above.
do $seal$declare ids regprocedure[];t record;begin
 ids:=pg_temp.qcia_ids();
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where to_regprocedure(%I)=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col)using ids;end loop;
for t in select table_name from information_schema.columns where table_schema='greenloop_private'and table_name in('tv_damage_access_installation','supplier_return_installation')and column_name='object_kind'loop
 execute format($q$update greenloop_private.%I i set definition_hash=md5(pg_get_constraintdef(c.oid)||c.convalidated::text)from pg_constraint c where i.object_kind='constraint'and c.conrelid='public.user_page_permissions'::regclass and c.conname=i.object_identity and c.conname='user_page_permissions_page_key_check'$q$,t.table_name);
end loop;
end;$seal$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.issuance_access_installation(identity text primary key,hash text not null);alter table greenloop_private.issuance_access_installation enable row level security;revoke all on greenloop_private.issuance_access_installation from public,anon,authenticated;
create or replace function public.get_issuance_access_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)>=12 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.issuance_access_installation where identity like '%(%')
 and exists(select 1 from greenloop_private.issuance_access_installation where identity='catalog'and hash=(select md5(capabilities::text)from greenloop_private.page_capability_catalog where page_key='qc_issuance'))
 and exists(select 1 from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check'and position('qc_issuance' in pg_get_constraintdef(oid))>0)
 and not has_function_privilege('authenticated','greenloop_private.qcia_require(boolean)','EXECUTE')and not has_function_privilege('anon','public.get_qc_issuance_choices_v1()','EXECUTE')and has_function_privilege('authenticated','public.get_qc_issuance_choices_v1()','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.issuance_access_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261109-issuance-access-1'end;$$;
revoke all on function public.get_issuance_access_version()from public;grant execute on function public.get_issuance_access_version()to anon,authenticated;
insert into greenloop_private.issuance_access_installation select id::text,md5(pg_get_functiondef(id))from unnest(pg_temp.qcia_ids())id on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.issuance_access_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.qcia_require(boolean)','greenloop_private.qcia_choices()','public.get_qc_issuance_choices_v1()','public.get_issuance_access_version()'])s on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.issuance_access_installation values('catalog',(select md5(capabilities::text)from greenloop_private.page_capability_catalog where page_key='qc_issuance'))on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_issuance_access_version()is distinct from '20261109-issuance-access-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Issuance access installation failed. Transaction rolled back.';end if;end;$$;
notify pgrst,'reload schema';
end;$qcia_install$;
select public.get_issuance_access_version()as installed_issuance_access_version;
