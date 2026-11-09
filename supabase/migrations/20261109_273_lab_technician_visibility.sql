-- Lab workbench card visibility only. Employee status, assignments and history are untouched.
-- One atomic statement, compatible with Supabase SQL Editor transaction pooling.
do $ltv_install$begin
do $$begin
 if public.get_stock_receipt_correction_version()is distinct from '20261109-stock-receipt-correction-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified page and office permissions are required.';end if;
 if to_regprocedure('public.get_lab_technician_visibility_version()')is not null then
  if public.get_lab_technician_visibility_version()is distinct from '20261109-lab-technician-visibility-1'then raise exception 'Existing Lab card visibility integrity differs.';end if;
 end if;
end;$$;
create table if not exists greenloop_private.lab_technician_visibility(
 employee_id uuid primary key references public.technician_roster(id)on delete cascade,hidden boolean not null,
 changed_by uuid not null,changed_at timestamptz not null default clock_timestamp());
alter table greenloop_private.lab_technician_visibility enable row level security;
revoke all on greenloop_private.lab_technician_visibility from public,anon,authenticated;
create or replace function greenloop_private.ltv_require(write_access boolean default false)returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.require_office_network();
 if auth.uid()is null or not coalesce(public.is_active_staff(),false)or greenloop_private.damage_tv_only(auth.uid())
 or not coalesce(public.has_page_capability_v1('lab_glass','view'),false)
 or(write_access and(not coalesce(public.has_page_capability_v1('lab_glass','manage_options'),false)
 or not exists(select 1 from public.user_page_permissions where user_id=auth.uid()and page_key='lab_glass'and access_level='edit')))
 then raise exception 'Lab & Glass Manage Options permission is required to hide or show technician cards.'using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.ltv_get()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.ltv_require();
 return jsonb_build_object('hidden_ids',coalesce((select jsonb_agg(employee_id order by employee_id)from greenloop_private.lab_technician_visibility where hidden),'[]'));
end;$$;
create or replace function greenloop_private.ltv_set(p_employee_id uuid,p_hidden boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.ltv_require(true);
 if p_employee_id is null or p_hidden is null or p_employee_id='00000000-0000-0000-0000-000000000000'::uuid
 or not exists(select 1 from public.technician_roster where id=p_employee_id)
 then raise exception 'Select a saved technician. Unassigned phones cannot be hidden.'using errcode='22023';end if;
 insert into greenloop_private.lab_technician_visibility(employee_id,hidden,changed_by)values(p_employee_id,p_hidden,auth.uid())
 on conflict(employee_id)do update set hidden=excluded.hidden,changed_by=excluded.changed_by,changed_at=clock_timestamp()
 where lab_technician_visibility.hidden is distinct from excluded.hidden;
 return greenloop_private.ltv_get();
end;$$;
create or replace function public.get_lab_technician_visibility_v1()returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.ltv_get();end;$$;
create or replace function public.set_lab_technician_visibility_v1(p_employee_id uuid,p_hidden boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.ltv_set(p_employee_id,p_hidden);end;$$;
insert into greenloop_private.capability_rpc_rules values
 ('get_lab_technician_visibility_v1','{"page":"lab_glass","capability":"view","read":true}'),
 ('set_lab_technician_visibility_v1','{"page":"lab_glass","capability":"manage_options"}')on conflict(rpc_name)do update set rule=excluded.rule;
do $permissions$declare f record;begin
 for f in select *from(values
 ('public.get_lab_technician_visibility_v1()','greenloop_private.ltv_get()'),
 ('public.set_lab_technician_visibility_v1(uuid,boolean)','greenloop_private.ltv_set(uuid,boolean)'))x(sig,impl)loop
  execute format('revoke all on function %s from public,anon,authenticated',f.sig);execute format('grant execute on function %s to authenticated',f.sig);
  insert into greenloop_private.office_routines values(f.sig,f.impl,md5(pg_get_functiondef(f.impl::regprocedure)),md5(pg_get_functiondef(f.sig::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
 end loop;
 for f in select oid from pg_proc where pronamespace='greenloop_private'::regnamespace and proname in('ltv_require','ltv_get','ltv_set')loop execute format('revoke all on function %s from public,anon,authenticated',f.oid::regprocedure);end loop;
end;$permissions$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.lab_visibility_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_visibility_installation enable row level security;revoke all on greenloop_private.lab_visibility_installation from public,anon,authenticated;
create or replace function public.get_lab_technician_visibility_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_visibility_installation)
 and not has_table_privilege('authenticated','greenloop_private.lab_technician_visibility','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.lab_technician_visibility','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.ltv_set(uuid,boolean)','EXECUTE')and not has_function_privilege('anon','public.set_lab_technician_visibility_v1(uuid,boolean)','EXECUTE')
 and has_function_privilege('authenticated','public.set_lab_technician_visibility_v1(uuid,boolean)','EXECUTE')
 and exists(select 1 from pg_class where oid='greenloop_private.lab_technician_visibility'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='set_lab_technician_visibility_v1'and rule='{"page":"lab_glass","capability":"manage_options"}'::jsonb)
 then '20261109-lab-technician-visibility-1'end;$$;
revoke all on function public.get_lab_technician_visibility_version()from public;grant execute on function public.get_lab_technician_visibility_version()to anon,authenticated;
insert into greenloop_private.lab_visibility_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where
 p.pronamespace='greenloop_private'::regnamespace and p.proname in('ltv_require','ltv_get','ltv_set')
 or p.pronamespace='public'::regnamespace and p.proname in('get_lab_technician_visibility_v1','set_lab_technician_visibility_v1','get_lab_technician_visibility_version')on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_lab_technician_visibility_version()is distinct from '20261109-lab-technician-visibility-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Lab card visibility verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$ltv_install$;
select public.get_lab_technician_visibility_version()as installed_lab_technician_visibility_version;
