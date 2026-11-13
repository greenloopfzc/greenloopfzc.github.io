-- Read current per-phone return reasons/notes; never rewrite immutable return-group history.
DO $return_details_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_direct_replacement_intake_version()is distinct from '20261112-direct-replacement-intake-1'or public.get_replacement_original_stock_version()is distinct from '20261111-replacement-original-stock-1'then raise exception 'Install the verified direct replacement / original stock updates first.';end if;end;$$;
create or replace function greenloop_private.srr_display_reason(reason text,notes text)returns text language sql immutable set search_path=pg_catalog as $$
 select case when reason='other'then coalesce(nullif(btrim(notes),''),'Other')else concat_ws(' - ',case reason when 'dead'then 'Dead phone'when 'icloud_locked'then 'iCloud locked'else coalesce(nullif(replace(reason,'_',' '),''),'Not specified')end,nullif(btrim(notes),''))end;
$$;
create or replace function greenloop_private.srr_current_return_details(g jsonb)returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('return_details',coalesce(jsonb_agg(jsonb_build_object('return_id',r.id,'imei',r.imei_1,'return_reason',r.reason,'return_notes',r.notes)order by r.id),'[]'))from jsonb_array_elements_text(g->'return_ids')i join public.supplier_returns r on r.id=i.value::uuid where r.archived_at is null and r.status='returned';
$$;
revoke all on function greenloop_private.srr_display_reason(text,text),greenloop_private.srr_current_return_details(jsonb)from public,anon,authenticated;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;begin
 foreach sig in array array['greenloop_private.srp_rows()','greenloop_private.gl4_history(jsonb,boolean,text,integer)','public.get_stock_return_phone_history_v1(text,integer)']loop
  old:=pg_get_functiondef(sig::regprocedure);updated:=old;before_hash:=md5(old);
  if sig='greenloop_private.srp_rows()'then
   if position('greenloop_private.srr_current_return_details(g)'in old)=0 then
    if position('select g||jsonb_build_object('in old)=0 then raise exception 'Replacement group reader changed. Review before installing.';end if;
    updated:=replace(updated,'select g||jsonb_build_object(','select g||greenloop_private.srr_current_return_details(g)||jsonb_build_object(');
   end if;
  elsif position('greenloop_private.srr_display_reason('in old)=0 then
   if sig='greenloop_private.gl4_history(jsonb,boolean,text,integer)'then
    if position('v:=g-''receipts''-''return_ids''-''imeis'';'in old)=0 or position('''reason'',g->>''reason'''in old)=0 then raise exception 'Replacement phone reader changed. Review before installing.';end if;
    updated:=replace(updated,'v:=g-''receipts''-''return_ids''-''imeis'';',$phone$v:=(g-'receipts'-'return_ids'-'imeis'-'return_details')||jsonb_build_object('return_id',r.id,'return_reason',r.reason::text,'return_notes',r.notes,'notes',r.notes);$phone$);
    updated:=replace(updated,'''reason'',g->>''reason''',$reason$'reason',greenloop_private.srr_display_reason(r.reason::text,r.notes)$reason$);
   else
    if position('''return_id'',r.id)'in old)=0 then raise exception 'Stock Return phone reader changed. Review before installing.';end if;
    updated:=replace(updated,'''return_id'',r.id)',$reason$'return_id',r.id,'return_reason',r.reason::text,'return_notes',r.notes,'reason',greenloop_private.srr_display_reason(r.reason::text,r.notes),'notes',r.notes)$reason$);
   end if;
  end if;
  if updated<>old then execute updated;end if;
  -- Reseal only exact before-definition matches; preserve every other routine receipt.
  for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
   for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
    execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
   end loop;
  end loop;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;
end;$patch$;
create table if not exists greenloop_private.return_details_sync_installation(identity text primary key,hash text not null);
alter table greenloop_private.return_details_sync_installation enable row level security;revoke all on greenloop_private.return_details_sync_installation from public,anon,authenticated;
create or replace function public.get_return_details_sync_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_direct_replacement_intake_version()='20261112-direct-replacement-intake-1'and public.get_replacement_original_stock_version()='20261111-replacement-original-stock-1'
 and(select count(*)=6 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.return_details_sync_installation)
 and not has_function_privilege('authenticated','greenloop_private.srr_display_reason(text,text)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.srr_current_return_details(jsonb)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.return_details_sync_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261113-return-details-sync-1'end;
$$;
revoke all on function public.get_return_details_sync_version()from public;grant execute on function public.get_return_details_sync_version()to anon,authenticated;
insert into greenloop_private.return_details_sync_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.srr_display_reason(text,text)','greenloop_private.srr_current_return_details(jsonb)','greenloop_private.srp_rows()','greenloop_private.gl4_history(jsonb,boolean,text,integer)','public.get_stock_return_phone_history_v1(text,integer)','public.get_return_details_sync_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_return_details_sync_version()is distinct from '20261113-return-details-sync-1'then raise exception 'Return details verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$return_details_install$;
select public.get_return_details_sync_version()as installed_return_details_sync_version;
