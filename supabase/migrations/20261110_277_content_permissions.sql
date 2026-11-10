-- Independent copying / browser-capture choices; no business data or existing alerts are changed.
do $cpa_install$begin
do $$begin
 if public.get_dashboard_ready_counts_version()is distinct from '20261110-dashboard-ready-counts-1'
 or public.get_content_protection_version()is distinct from '20261109-content-protection-1'
 or public.get_settings_appearance_version()is distinct from '20261017-settings-appearance-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Workspace / Ready Counts, Content Protection and Appearance installations are required.';end if;
 if to_regprocedure('public.get_content_permissions_version()')is not null then
  if public.get_content_permissions_version()is distinct from '20261110-content-permissions-1'then raise exception 'Existing Copy / Screenshot permission integrity differs.';end if;
 elsif exists(select 1 from greenloop_private.page_capability_catalog where page_key='content_access')then raise exception 'Existing content permission catalog requires review.';
 end if;
end;$$;
-- Resolve private implementations from the installation registry, never database-specific OIDs.
create or replace function pg_temp.cpa_function(sig text)returns regprocedure language sql as $$
 select coalesce((select to_regprocedure(implementation)from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure(sig)),to_regprocedure(sig));
$$;
do $review$declare r record;begin
 if to_regprocedure('public.get_content_permissions_version()')is not null then
  if public.get_content_permissions_version()='20261110-content-permissions-1'then return;end if;
 end if;
 for r in select *from(values
 ('greenloop_private.user_capabilities(uuid)','4c6ac84029af72b0c9fe1da168c28f3a'),
 ('greenloop_private.normalize_capabilities(jsonb)','b02df0eff0f0fcb2dd76f7a9900bcb79'),
 ('public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)','8e26340f493c497642c3e53ef5663ce9'),
 ('greenloop_private.cp_log(text,text,uuid)','4b04ef6992b2daff0f3a57821a250adb'))v(identity,hash)loop
 if(select md5(replace(prosrc,chr(13),''))from pg_proc where oid=pg_temp.cpa_function(r.identity))is distinct from r.hash
 then raise exception 'Reviewed Copy / Screenshot permission function differs: %',r.identity;end if;
 end loop;
end;$review$;
insert into greenloop_private.page_capability_catalog values('content_access','[{"key":"view","label":"Content choices","write":false},{"key":"copy","label":"Allow Copying","write":false},{"key":"screenshots","label":"Allow Screenshots","write":false}]'::jsonb)on conflict(page_key)do update set capabilities=excluded.capabilities;
do $patch0$declare body text;needle text:=$needle$  -- Appearance is a preference permission, never a routed page or entry grant.$needle$;replacement text:=$replacement$  -- Content permissions are independent of page/write access. Admin defaults apply only until explicitly configured.
  if p.page_key='content_access' then
   result:=result||jsonb_build_object('content_access',coalesce(configured->'content_access',case when is_owner then '["view","copy","screenshots"]'::jsonb else '[]'::jsonb end));
   continue;
  end if;
  -- Appearance is a preference permission, never a routed page or entry grant.$replacement$;begin
 select replace(pg_get_functiondef(to_regprocedure('greenloop_private.user_capabilities(uuid)')),chr(13),'')into body;
 if position(replacement in body)=0 then
  if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Reviewed permission clause missing or ambiguous: 0';end if;
  body:=replace(body,needle,replacement);
  if position('greenloop-content-permissions-277'in body)=0 then body:=replace(body,'begin',E'-- greenloop-content-permissions-277\nbegin');end if;execute body;
 end if;
end;$patch0$;
do $patch1$declare body text;needle text:=$needle$  if p.page_key='appearance' then$needle$;replacement text:=$replacement$  if p.page_key='content_access' then
   if selected?'copy' or selected?'screenshots' then
    select jsonb_agg(v order by v)into selected from(select distinct value v from jsonb_array_elements_text(selected||'["view"]'::jsonb))d;
   else selected:='[]'::jsonb;end if;
   normalized:=normalized||jsonb_build_object(p.page_key,selected);continue;
  end if;
  if p.page_key='appearance' then$replacement$;begin
 select replace(pg_get_functiondef(to_regprocedure('greenloop_private.normalize_capabilities(jsonb)')),chr(13),'')into body;
 if position(replacement in body)=0 then
  if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Reviewed permission clause missing or ambiguous: 1';end if;
  body:=replace(body,needle,replacement);
  if position('greenloop-content-permissions-277'in body)=0 then body:=replace(body,'begin',E'-- greenloop-content-permissions-277\nbegin');end if;execute body;
 end if;
end;$patch1$;
do $patch2$declare body text;needle text:=$needle$ caps:=p_capabilities;$needle$;replacement text:=$replacement$ caps:=p_capabilities||jsonb_build_object('content_access',coalesce(p_capabilities->'content_access',greenloop_private.user_capabilities(p_user_id)->'content_access','[]'::jsonb));$replacement$;begin
 select replace(pg_get_functiondef(pg_temp.cpa_function('public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)')),chr(13),'')into body;
 if position(replacement in body)=0 then
  if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Reviewed permission clause missing or ambiguous: 2';end if;
  body:=replace(body,needle,replacement);
  if position('greenloop-content-permissions-277'in body)=0 then body:=replace(body,'begin',E'-- greenloop-content-permissions-277\nbegin');end if;execute body;
 end if;
end;$patch2$;
do $patch3$declare body text;needle text:=$needle$'appearance',coalesce(p_capabilities->'appearance','[]'::jsonb));$needle$;replacement text:=$replacement$'appearance',coalesce(p_capabilities->'appearance','[]'::jsonb),'content_access',caps->'content_access');$replacement$;begin
 select replace(pg_get_functiondef(pg_temp.cpa_function('public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)')),chr(13),'')into body;
 if position(replacement in body)=0 then
  if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Reviewed permission clause missing or ambiguous: 3';end if;
  body:=replace(body,needle,replacement);
  if position('greenloop-content-permissions-277'in body)=0 then body:=replace(body,'begin',E'-- greenloop-content-permissions-277\nbegin');end if;execute body;
 end if;
end;$patch3$;
do $patch4$declare body text;needle text:=$needle$ event_ref:='content:'||actor::text||':'||p_request_id::text;$needle$;replacement text:=$replacement$ if coalesce((greenloop_private.user_capabilities(actor)->'content_access')?case when p_action in('print_screen','alt_print_screen','windows_snip','edge_capture','mac_capture')then 'screenshots'else 'copy'end,false)then
  return jsonb_build_object('accepted',false,'reason','action_allowed');
 end if;
 event_ref:='content:'||actor::text||':'||p_request_id::text;$replacement$;begin
 select replace(pg_get_functiondef(to_regprocedure('greenloop_private.cp_log(text,text,uuid)')),chr(13),'')into body;
 if position(replacement in body)=0 then
  if (length(body)-length(replace(body,needle,'')))/length(needle)<>1 then raise exception 'Reviewed permission clause missing or ambiguous: 4';end if;
  body:=replace(body,needle,replacement);
  if position('greenloop-content-permissions-277'in body)=0 then body:=replace(body,'begin',E'-- greenloop-content-permissions-277\nbegin');end if;execute body;
 end if;
end;$patch4$;
-- Reseal only the four reviewed permission functions in existing receipts.
do $seal$declare t record;ids regprocedure[]:=array['greenloop_private.user_capabilities(uuid)'::regprocedure,'greenloop_private.normalize_capabilities(jsonb)'::regprocedure,pg_temp.cpa_function('public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)'),'greenloop_private.cp_log(text,text,uuid)'::regprocedure];begin
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(implementation))),wrapped_hash=md5(pg_get_functiondef(to_regprocedure(identity)))where to_regprocedure(identity)=any(ids)or to_regprocedure(implementation)=any(ids);
 for t in select c.table_name,c.column_name hash_col,i.column_name id_col from information_schema.columns c join information_schema.columns i on i.table_schema=c.table_schema and i.table_name=c.table_name where c.table_schema='greenloop_private'and c.table_name like '%installation'and c.column_name in('hash','definition_hash')and i.column_name in('identity','object_identity','function_identity')loop
 execute format('update greenloop_private.%I set %I=md5(pg_get_functiondef(to_regprocedure(%I)))where case when %I like ''%%(%%''then to_regprocedure(%I)else null end=any($1)',t.table_name,t.hash_col,t.id_col,t.id_col,t.id_col)using ids;end loop;
end;$seal$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c)order by page_key)::text)from greenloop_private.page_capability_catalog c)where identity='catalog';
create table if not exists greenloop_private.content_permissions_installation(identity text primary key,hash text not null);
alter table greenloop_private.content_permissions_installation enable row level security;
revoke all on greenloop_private.content_permissions_installation from public,anon,authenticated;
create or replace function public.get_content_permissions_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 exists(select 1 from pg_class where oid='greenloop_private.content_permissions_installation'::regclass and relrowsecurity)
 and(select count(*)=5 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.content_permissions_installation where identity<>'catalog')
 and exists(select 1 from greenloop_private.content_permissions_installation where identity='catalog'and hash=(select md5(capabilities::text)from greenloop_private.page_capability_catalog where page_key='content_access'))
 and not has_table_privilege('authenticated','greenloop_private.content_permissions_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.content_permissions_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261110-content-permissions-1'end;$$;
revoke all on function public.get_content_permissions_version()from public;grant execute on function public.get_content_permissions_version()to anon,authenticated;
insert into greenloop_private.content_permissions_installation select f::text,md5(pg_get_functiondef(f))from unnest(array['greenloop_private.user_capabilities(uuid)'::regprocedure,'greenloop_private.normalize_capabilities(jsonb)'::regprocedure,pg_temp.cpa_function('public.save_user_access_capabilities_v1(uuid,text,text,boolean,jsonb,text,boolean,boolean,boolean,boolean,text,jsonb)'),'greenloop_private.cp_log(text,text,uuid)'::regprocedure]||array['public.get_content_permissions_version()'::regprocedure])f on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.content_permissions_installation values('catalog',(select md5(capabilities::text)from greenloop_private.page_capability_catalog where page_key='content_access'))on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_content_permissions_version()is distinct from '20261110-content-permissions-1'
 or public.get_dashboard_ready_counts_version()is distinct from '20261110-dashboard-ready-counts-1'
 or public.get_content_protection_version()is distinct from '20261109-content-protection-1'
 or public.get_settings_appearance_version()is distinct from '20261017-settings-appearance-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Copy / Screenshot permission verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$cpa_install$;
select public.get_content_permissions_version()as installed_content_permissions_version;
