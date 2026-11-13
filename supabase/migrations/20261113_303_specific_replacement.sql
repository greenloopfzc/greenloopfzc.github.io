-- Explicit returned-phone selection and reviewed different-GB replacements; no stored data changes.
DO $specific_replacement_install$ BEGIN EXECUTE $ddl$
do $$begin if public.get_return_details_sync_version()is distinct from '20261113-return-details-sync-1'or public.get_direct_replacement_intake_version()is distinct from '20261112-direct-replacement-intake-1'then raise exception 'Install the verified current Return/Replacement updates first.';end if;end;$$;
do $patch$declare sig text;old text;updated text;before_hash text;c record;t record;begin
 foreach sig in array array['greenloop_private.srma_plan(uuid,uuid,jsonb)','greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)']loop
  old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);updated:=old;
  if sig='greenloop_private.srma_plan(uuid,uuid,jsonb)'then
   execute $new_plan$create or replace function greenloop_private.srma_plan(p_supplier uuid,p_batch uuid,p_phones jsonb)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;v jsonb;c jsonb;choices jsonb;rows jsonb:='[]';used uuid[]:='{}';imeis text[]:='{}';imei text;m text;col text;gb integer;why text;n integer:=0;ok boolean:=true;mode text;target_imei text;requested uuid;reserved uuid[]:='{}';hits integer;gb_changed boolean;
begin
 perform greenloop_private.srp_access('replacement_entry');
 if jsonb_typeof(p_phones)is distinct from 'array'or jsonb_array_length(p_phones)not between 1 and 1000 then raise exception 'Add 1 to 1000 replacement phones.'using errcode='22023';end if;
 select *into b from public.receiving_batches where id=p_batch and supplier_id=p_supplier;
 if b.id is null or b.planned_quantity is null or not exists(select 1 from public.suppliers where id=p_supplier and deleted_at is null and is_active)then raise exception 'Select a supplier and its original stock.'using errcode='22023';end if;
 select coalesce(jsonb_agg(x),'[]')into choices from greenloop_private.srma_candidates(b.id)x;
 -- Reserve every explicit target before auto matching, irrespective of row order.
 for v in select value from jsonb_array_elements(p_phones)loop
  if coalesce(btrim(v->>'return_id'),'')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then reserved:=array_append(reserved,(btrim(v->>'return_id'))::uuid);
  elsif nullif(btrim(v->>'returned_imei'),'')is not null then
   select count(*)into hits from jsonb_array_elements(choices)x where x->>'old_imei'=btrim(v->>'returned_imei');
   if hits=1 then select(x->>'return_id')::uuid into requested from jsonb_array_elements(choices)x where x->>'old_imei'=btrim(v->>'returned_imei');reserved:=array_append(reserved,requested);end if;
  end if;
 end loop;
 for v in select value from jsonb_array_elements(p_phones)loop
  n:=n+1;c:=null;why:=null;imei:=btrim(v->>'imei');m:=btrim(v->>'model');col:=coalesce(btrim(v->>'color'),'');gb:=null;requested:=null;mode:=coalesce(nullif(btrim(v->>'match_mode'),''),'auto');target_imei:=nullif(btrim(v->>'returned_imei'),'');gb_changed:=false;
  if jsonb_typeof(v)is distinct from 'object'or exists(select 1 from jsonb_object_keys(v)k where k<>all(array['imei','model','storage_gb','color','imei_2','serial_number','specification_region','battery_health','brand','platform','return_id','returned_imei','match_mode','gb_change_approved']))then raise exception 'Use supported replacement fields.'using errcode='22023';end if;
  if mode not in('specific','auto')then why:='Choose Specific IMEI or Auto Match.';
  elsif nullif(btrim(v->>'return_id'),'')is not null and btrim(v->>'return_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then why:='Choose a valid returned phone.';
  elsif target_imei is not null and target_imei!~'^[0-9]{15}$'then why:='Enter a complete 15-digit returned IMEI.';
  elsif v?'gb_change_approved'and jsonb_typeof(v->'gb_change_approved')not in('boolean','null')then why:='GB change approval must be explicit.';
  elsif imei is null or imei!~'^[0-9]{15}$'then why:='Enter a complete 15-digit new IMEI.';
  elsif imei=any(imeis)then why:='Duplicate new IMEI in this list.';
  elsif exists(select 1 from public.devices where imei_1=imei or imei_2=imei)or exists(select 1 from public.supplier_returns where imei_1=imei and archived_at is null and status in('requested','approved','returned'))then why:='This IMEI already belongs to a saved or returned phone.';
  elsif exists(select 1 from greenloop_private.gl4_return_phone_details c where imei in(c.capture->>'imei',c.capture->>'imei_2')or nullif(v->>'imei_2','')in(c.capture->>'imei',c.capture->>'imei_2')or upper(nullif(v->>'serial_number',''))=upper(nullif(c.capture->>'serial_number','')))then why:='This identity belongs to a returned phone.';
  elsif exists(select 1 from greenloop_private.srma_pairs where new_imei=imei)then why:='This IMEI is already reserved for a replacement receipt.';
  elsif nullif(v->>'imei_2','') is not null and ((v->>'imei_2')!~'^[0-9]{15}$' or v->>'imei_2'=imei or v->>'imei_2'=any(imeis)) then why:='Invalid or duplicate secondary identity.';
  elsif exists(select 1 from public.devices where imei_1=nullif(v->>'imei_2','') or imei_2=nullif(v->>'imei_2','') or upper(serial_number)=upper(nullif(btrim(v->>'serial_number'),''))) then why:='Secondary IMEI or Serial Number already belongs to a phone.';
  elsif length(coalesce(v->>'serial_number',''))>128 or length(coalesce(v->>'specification_region',''))>128 then why:='Identity details are too long.';
  elsif nullif(v->>'battery_health','') is not null and (coalesce(v->>'battery_health','')!~'^[0-9]{1,3}$' or (v->>'battery_health')::integer>100) then why:='Battery health must be between 0 and 100.';
  elsif nullif(m,'')is null or length(m)>120 or length(col)>120 or coalesce(v->>'storage_gb','')!~'^[0-9]{1,5}$'then why:='Enter Model and GB to match a returned phone. Color is optional.';
  else
   gb:=(v->>'storage_gb')::integer;
   if gb not between 1 and 16384 then why:='Choose valid storage.';
   else
    if nullif(btrim(v->>'return_id'),'')is not null then requested:=(btrim(v->>'return_id'))::uuid;end if;
    if requested is not null or target_imei is not null then mode:='specific';end if;
    if mode='specific'then
     if requested is not null then select x into c from jsonb_array_elements(choices)x where x->>'return_id'=requested::text;
     elsif target_imei is not null then
      select count(*)into hits from jsonb_array_elements(choices)x where x->>'old_imei'=target_imei;
      if hits=1 then select x into c from jsonb_array_elements(choices)x where x->>'old_imei'=target_imei;
      elsif hits>1 then why:='More than one pending return has this IMEI. Choose its exact return reference.';end if;
     else why:='Select or scan the returned IMEI for this replacement.';end if;
     if why is null then
      if c is null then why:='Selected return is not pending in this supplier/batch, or its replacement is already received.';
      elsif (c->>'return_id')::uuid=any(used)then why:='This returned phone is already selected in another line.';
      elsif target_imei is not null and target_imei is distinct from c->>'old_imei'then why:='Returned IMEI changed. Select that returned phone again.';
      elsif nullif(btrim(c->>'model'),'')is null or greenloop_private.srma_model(c->>'model')<>greenloop_private.srma_model(m)then why:='Replacement Model must match the selected returned phone. Correct missing return Model first.';
      else gb_changed:=nullif(c->>'storage_gb','')::integer is distinct from gb;end if;
     end if;
    else
     select x into c from jsonb_array_elements(choices)x where not((x->>'return_id')::uuid=any(used))and not((x->>'return_id')::uuid=any(reserved))and greenloop_private.srma_model(x->>'model')=greenloop_private.srma_model(m)and(x->>'storage_gb')::integer=gb order by(x->>'returned_at')::timestamptz,(x->>'return_id')::uuid limit 1;
     if c is null then why:='Auto Match needs the same Model and GB. Choose Specific IMEI for a different GB replacement.';end if;
    end if;
   end if;
  end if;
  if imei is not null then imeis:=array_append(imeis,imei);if nullif(v->>'imei_2','') is not null then imeis:=array_append(imeis,v->>'imei_2');end if;end if;
  if why is null then used:=array_append(used,(c->>'return_id')::uuid);else ok:=false;end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('line',n,'imei',imei,'model',m,'storage_gb',gb,'color',col,'matched',why is null,'reason',coalesce(why,case when gb_changed then 'GB change: returned '||coalesce(c->>'storage_gb','Not recorded')||' -> replacement '||gb::text||' GB. Approval required.'when mode='specific'then 'Specific returned IMEI matched.'else 'Matched oldest pending return with same Model and GB.'end),
   'return_id',c->'return_id','group_id',c->'group_id','old_imei',c->'old_imei','old_model',c->'model','old_storage_gb',c->'storage_gb','old_color',c->'color','gb_changed',gb_changed,'match_mode',mode,'return_reference',c->'return_reference','batch_number',b.batch_number,'received_quantity',b.planned_quantity));
 end loop;
 return jsonb_build_object('matching_version','20261113-specific-replacement-1','rows',rows,'all_matched',ok,'snapshot',md5(jsonb_build_object('supplier',p_supplier,'batch',p_batch,'rows',rows,'phones',(select coalesce(jsonb_agg(x.value-'gb_change_approved'order by x.n),'[]')from jsonb_array_elements(p_phones)with ordinality x(value,n)))::text));
end;$$;
$new_plan$;
  elsif position('GB change approval required'in old)=0 then
   if position('Nothing was saved.''using errcode=''40001'';end if;'in old)=0 then raise exception 'Replacement save boundary changed. Review before installing.';end if;
   updated:=replace(updated,'Nothing was saved.''using errcode=''40001'';end if;',$approval$Nothing was saved.'using errcode='40001';end if;
   if exists(select 1 from jsonb_array_elements(plan->'rows')as reviewed(line) join jsonb_array_elements(p_phones)as incoming(payload) on incoming.payload->>'imei'=reviewed.line->>'imei'where(reviewed.line->>'gb_changed')::boolean and incoming.payload->'gb_change_approved'is distinct from 'true'::jsonb)then raise exception 'GB change approval required. Review the returned and replacement GB, then Approve.'using errcode='42501';end if;$approval$);
   execute updated;
  end if;
  for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
   for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
    execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
   end loop;
  end loop;
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 end loop;
end;$patch$;
create or replace function greenloop_private.srmx_pending(supplier uuid,batch uuid,query text,start_row integer)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare b public.receiving_batches%rowtype;rows jsonb;begin
 perform greenloop_private.srp_access('replacement_entry');
 if start_row is null or start_row<0 or start_row%50<>0 or length(coalesce(query,''))>160 then raise exception 'Choose a valid pending-return page or search.'using errcode='22023';end if;
 select *into b from public.receiving_batches where id=batch and supplier_id=supplier and exists(select 1 from public.suppliers where id=supplier and is_active and deleted_at is null);
 if b.id is null then raise exception 'Choose the supplier and its original stock.'using errcode='22023';end if;
 select coalesce(jsonb_agg(x order by(x->>'returned_at')::timestamptz,x->>'return_id'),'[]')into rows from greenloop_private.srma_candidates(batch)x where nullif(btrim(query),'')is null or strpos(lower(x::text),lower(btrim(query)))>0;
 return jsonb_build_object('supplier_id',supplier,'batch_id',batch,'batch_number',b.batch_number,'receipt_quantity',b.planned_quantity,'offset',start_row,'total',jsonb_array_length(rows),'rows',coalesce((select jsonb_agg(value order by n)from jsonb_array_elements(rows)with ordinality a(value,n)where n>start_row and n<=start_row+50),'[]'));
end;$$;
create or replace function public.get_pending_replacement_returns_v1(p_supplier uuid,p_batch uuid,p_query text default '',p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set lock_timeout='5s' set statement_timeout='120s' as $$begin perform greenloop_private.require_office_network();return greenloop_private.srmx_pending(p_supplier,p_batch,p_query,p_offset);end;$$;
revoke all on function greenloop_private.srmx_pending(uuid,uuid,text,integer)from public,anon,authenticated;
revoke all on function public.get_pending_replacement_returns_v1(uuid,uuid,text,integer)from public,anon;grant execute on function public.get_pending_replacement_returns_v1(uuid,uuid,text,integer)to authenticated;
create table if not exists greenloop_private.specific_replacement_installation(identity text primary key,hash text not null);alter table greenloop_private.specific_replacement_installation enable row level security;revoke all on greenloop_private.specific_replacement_installation from public,anon,authenticated;
create or replace function public.get_specific_replacement_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_return_details_sync_version()='20261113-return-details-sync-1'and public.get_direct_replacement_intake_version()='20261112-direct-replacement-intake-1'
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.specific_replacement_installation)
 and not has_function_privilege('authenticated','greenloop_private.srmx_pending(uuid,uuid,text,integer)','EXECUTE')and not has_function_privilege('anon','public.get_pending_replacement_returns_v1(uuid,uuid,text,integer)','EXECUTE')
 and not has_table_privilege('authenticated','greenloop_private.specific_replacement_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')then '20261113-specific-replacement-1'end;$$;
revoke all on function public.get_specific_replacement_version()from public;grant execute on function public.get_specific_replacement_version()to anon,authenticated;
insert into greenloop_private.specific_replacement_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.srma_plan(uuid,uuid,jsonb)','greenloop_private.srma_save(uuid,uuid,jsonb,text,uuid,text)','greenloop_private.srmx_pending(uuid,uuid,text,integer)','public.get_pending_replacement_returns_v1(uuid,uuid,text,integer)','public.get_specific_replacement_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_specific_replacement_version()is distinct from '20261113-specific-replacement-1'then raise exception 'Specific replacement verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$specific_replacement_install$;
select public.get_specific_replacement_version()as installed_specific_replacement_version;
