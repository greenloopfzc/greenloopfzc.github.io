-- Add one-request Box Entry paste without changing existing scan/stock rules.
begin;
do $$begin
 if to_regprocedure('public.get_box_bulk_entry_version()')is not null then if public.get_box_bulk_entry_version()is distinct from '20261109-box-bulk-portrait-1'then raise exception 'Existing Box Bulk installation integrity differs.';end if;end if;
 if public.get_installation_component_engine_version()is distinct from '20261107-installation-components-1' or public.get_installation_component_version('get_box_workflow_version')->'result'->>'version'is distinct from '20261010-box-workflow-1'then raise exception 'Verified Box Workflow support is required.';end if;
end;$$;
create or replace function greenloop_private.bb_scan(p_box_id uuid,p_revision integer,p_imeis text[])returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare b public.export_boxes%rowtype;w greenloop_private.box_workflow%rowtype;v text;r record;results jsonb:='[]';n integer:=0;seen text[]:='{}';snapshot jsonb;
begin
 perform greenloop_private.require_office_network();perform greenloop_private.pf_cap('export_boxes','scan');
 if not greenloop_private.box_access('export_boxes',true)then raise exception 'Box Entry permission required.'using errcode='42501';end if;
 if coalesce(cardinality(p_imeis),0)=0 then raise exception 'Paste at least one IMEI.'using errcode='22023';end if;
 -- Same serialization order as the existing single scanner; keep the entire
 -- batch in its reviewed current box, even when another scanner is active.
 perform pg_advisory_xact_lock(16320261010);
 select *into b from public.export_boxes where id=p_box_id for update;
 select *into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if b.id is null or b.box_status<>'open' or w.state is distinct from 'draft' or w.saved_at is not null then raise exception 'This box is already saved or unavailable. Reload the box.'using errcode='22023';end if;
 if w.revision is distinct from p_revision then raise exception 'This box changed. Refresh the box before pasting again.'using errcode='40001';end if;
 if b.id is distinct from(select id from public.export_boxes where box_status='open'order by opened_at,created_at limit 1)then raise exception 'A different box is open for scanning. Refresh the box.'using errcode='40001';end if;
 foreach v in array p_imeis loop
  begin
   if v is null or v!~'^[0-9]{15}$'then raise exception 'Use a valid 15-digit IMEI.'using errcode='22023';end if;
   if v=any(seen)then raise exception 'Duplicate IMEI in pasted list.'using errcode='22023';end if;
   seen:=array_append(seen,v);
   select *into r from public.scan_imei_to_export_box(v);
   if r.box_id is distinct from b.id then raise exception 'Box changed during paste. Reload before retrying.'using errcode='40001';end if;
   n:=n+1;results:=results||jsonb_build_array(jsonb_build_object('imei',v,'ok',true,'serial_no',r.serial_no));
  exception when sqlstate '22023' or sqlstate '23505' or sqlstate '55000' or sqlstate 'P0001'then
   results:=results||jsonb_build_array(jsonb_build_object('imei',v,'ok',false,'message',sqlerrm));
  end;
 end loop;
 snapshot:=public.get_box_workflow_v1(b.id);
 return snapshot||jsonb_build_object('loaded',n,'results',results);
end;$$;
revoke all on function greenloop_private.bb_scan(uuid,integer,text[])from public,anon,authenticated;
create or replace function public.scan_imeis_to_export_box_v1(p_box_id uuid,p_revision integer,p_imeis text[])returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.bb_scan(p_box_id,p_revision,p_imeis);end;$$;
revoke all on function public.scan_imeis_to_export_box_v1(uuid,integer,text[])from public,anon,authenticated;
grant execute on function public.scan_imeis_to_export_box_v1(uuid,integer,text[])to authenticated;
insert into greenloop_private.office_routines values('public.scan_imeis_to_export_box_v1(uuid,integer,text[])','greenloop_private.bb_scan(uuid,integer,text[])',md5(pg_get_functiondef('greenloop_private.bb_scan(uuid,integer,text[])'::regprocedure)),md5(pg_get_functiondef('public.scan_imeis_to_export_box_v1(uuid,integer,text[])'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
insert into greenloop_private.capability_rpc_rules values('scan_imeis_to_export_box_v1','{"page":"export_boxes","capability":"scan"}')on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.box_bulk_installation(identity text primary key,hash text not null);
alter table greenloop_private.box_bulk_installation enable row level security;
revoke all on greenloop_private.box_bulk_installation from public,anon,authenticated;
create or replace function public.get_box_bulk_entry_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when(select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.box_bulk_installation)
 and has_function_privilege('authenticated','public.scan_imeis_to_export_box_v1(uuid,integer,text[])','EXECUTE')and not has_function_privilege('anon','public.scan_imeis_to_export_box_v1(uuid,integer,text[])','EXECUTE')
 and not has_function_privilege('authenticated','greenloop_private.bb_scan(uuid,integer,text[])','EXECUTE')and not has_function_privilege('anon','greenloop_private.bb_scan(uuid,integer,text[])','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.box_bulk_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.box_bulk_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_class where oid='greenloop_private.box_bulk_installation'::regclass and relrowsecurity)
 and exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name='scan_imeis_to_export_box_v1'and rule='{"page":"export_boxes","capability":"scan"}'::jsonb)
 then '20261109-box-bulk-portrait-1'end;
$$;
revoke all on function public.get_box_bulk_entry_version()from public;grant execute on function public.get_box_bulk_entry_version()to anon,authenticated;
insert into greenloop_private.box_bulk_installation select s,md5(pg_get_functiondef(s::regprocedure))from unnest(array['greenloop_private.bb_scan(uuid,integer,text[])','public.scan_imeis_to_export_box_v1(uuid,integer,text[])','public.get_box_bulk_entry_version()'])s on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_box_bulk_entry_version()is distinct from '20261109-box-bulk-portrait-1'or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'or public.get_office_access_version()is distinct from '20261024-office-access-1'then raise exception 'Box Bulk installation failed verification. No changes installed.';end if;
end;$$;
notify pgrst,'reload schema';commit;
select public.get_box_bulk_entry_version()as installed_box_bulk_entry_version;
