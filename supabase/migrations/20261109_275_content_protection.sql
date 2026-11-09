-- Bounded, self-attributed browser-attempt telemetry. Never receives selected text or images.
-- Browser signals do not prove that an OS-level screenshot was taken or prevented.
do $cp_install$begin
do $$begin
 if public.get_lab_sunday_counts_version()is distinct from '20261109-lab-sunday-counts-1'
 or public.get_suspicious_activity_version()is distinct from '20261017-suspicious-activity-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Suspicious Activity, page and office installations are required.';end if;
 if to_regprocedure('public.get_content_protection_version()')is not null then
  if public.get_content_protection_version()is distinct from '20261109-content-protection-1'then raise exception 'Existing content-protection integrity differs.';end if;
 end if;
end;$$;
-- Keep ordinary alert tables at 50 rows per page; downloads retain their separate limit.
do $cp_reader$declare impl regprocedure;ddl text;h text;begin
 select to_regprocedure(implementation)into strict impl from greenloop_private.office_routines where to_regprocedure(identity)='public.get_suspicious_alerts_v1(jsonb,text,integer,boolean)'::regprocedure;
 select replace(pg_get_functiondef(oid),chr(13),''),md5(replace(prosrc,chr(13),''))into ddl,h from pg_proc where oid=impl;
 if position('greenloop-content-alert-pages-275'in ddl)=0 then
  if h is distinct from '635d07fa13aad2bfcad874aa5c90926e' or position('case when p_download then 5000 else 25 end'in ddl)=0 then raise exception 'Reviewed Suspicious Activity page reader differs.';end if;
  ddl:=replace(ddl,'case when p_download then 5000 else 25 end','case when p_download then 5000 else 50 end');
  execute replace(ddl,'declare ',E'-- greenloop-content-alert-pages-275\ndeclare ');
 end if;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(implementation)=impl;
end;$cp_reader$;
insert into greenloop_private.suspicious_rules(key,label,enabled,settings)values('content_protection','Protected text / screen-capture attempts',true,'{}')on conflict(key)do nothing;
create table if not exists greenloop_private.content_attempt_limits(
 actor_id uuid primary key,window_start timestamptz not null,attempts integer not null check(attempts between 0 and 30));
alter table greenloop_private.content_attempt_limits enable row level security;revoke all on greenloop_private.content_attempt_limits from public,anon,authenticated;
create or replace function greenloop_private.cp_log(p_action text,p_page text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid();stamp timestamptz:=clock_timestamp();lim greenloop_private.content_attempt_limits%rowtype;existing record;event_ref text;page_name text;username text;title text;why text;capture boolean;alert uuid;
begin
 perform greenloop_private.require_office_network();
 if actor is null or not coalesce(public.is_active_staff(),false)then raise exception 'An active signed-in account is required.'using errcode='42501';end if;
 if p_page is null or length(p_page)>64 or not exists(select 1 from greenloop_private.page_capability_catalog where page_key=p_page)
 or not coalesce(public.has_page_capability_v1(p_page,'view'),false)
 or(greenloop_private.damage_tv_only(actor)and p_page<>'damage_report')then raise exception 'Page access is required to report this browser event.'using errcode='42501';end if;
 if p_request_id is null or p_action is null or p_action not in('select_all','text_drag','text_select','copy','cut','print_screen','alt_print_screen','windows_snip','edge_capture','mac_capture')then raise exception 'Choose a supported browser event.'using errcode='22023';end if;
 event_ref:='content:'||actor::text||':'||p_request_id::text;
 insert into greenloop_private.content_attempt_limits values(actor,stamp,0)on conflict(actor_id)do nothing;
 select *into lim from greenloop_private.content_attempt_limits where actor_id=actor for update;
 select id,evidence into existing from greenloop_private.suspicious_alerts where event_key=event_ref;
 if found then
  if existing.evidence->>'Action code'is distinct from p_action or existing.evidence->>'Page key'is distinct from p_page then raise exception 'This event reference belongs to another attempt.'using errcode='22023';end if;
  return jsonb_build_object('accepted',true,'alert_id',existing.id,'duplicate',true);
 end if;
 if not exists(select 1 from greenloop_private.suspicious_rules where key='content_protection'and enabled)then return jsonb_build_object('accepted',false,'reason','rule_disabled');end if;
 if stamp>=lim.window_start+interval '1 minute'then lim.window_start:=stamp;lim.attempts:=0;end if;
 if lim.attempts>=30 then return jsonb_build_object('accepted',false,'reason','rate_limited');end if;
 update greenloop_private.content_attempt_limits set window_start=lim.window_start,attempts=lim.attempts+1 where actor_id=actor;
 select login_username into username from public.user_profiles where id=actor;
 page_name:=case p_page when 'overview'then 'Dashboard'when 'lab_glass'then 'Lab & Glass'when 'qc_issuance'then 'Lab & Glass Issuance'when 'frame_department'then 'B-DEPT'when 'export_boxes'then 'Box Entry'when 'daily_production'then 'Available Stock'else initcap(replace(p_page,'_',' '))end;
 capture:=p_action in('print_screen','alt_print_screen','windows_snip','edge_capture','mac_capture');
 title:=case when capture then 'Screen-capture shortcut observed'when p_action in('copy','cut')then 'Protected page copy attempted'else 'Protected text selection attempted'end;
 why:=case when capture then 'A screen-capture shortcut was reported on a protected software page. The page attempted to cancel the shortcut and temporarily cover its content. Whether a screenshot was taken or prevented is not confirmed.'else 'A text-selection or copy gesture was reported on protected page content. The page blocks ordinary selection and copy outside editable entry fields. Review the browser-reported attempt; it does not prove data was copied.'end;
 perform greenloop_private.suspicious_emit(event_ref,'content_protection','high',title,why,actor,page_name,'Data Protection',stamp,
  jsonb_build_object('Username',username,'Page',page_name,'Page key',p_page,'Action code',p_action,
   'Event source','Client-reported browser interaction','Recorded time',stamp,
   'Capture result',case when capture then 'Unknown: no screenshot completion signal is available to this website.'else 'Not a screenshot event'end,
   'Context','This is a review signal, not proof of misconduct. No selected text, clipboard contents, screenshot, password or token was collected. OS tools and other capture methods that do not notify the browser are not observable.'));
 select id into alert from greenloop_private.suspicious_alerts where event_key=event_ref;
 return jsonb_build_object('accepted',alert is not null,'alert_id',alert,'duplicate',false);
end;$$;
create or replace function public.log_content_protection_attempt_v1(p_action text,p_page text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin
 -- greenloop-office-wrapper-196
 perform greenloop_private.require_office_network();return greenloop_private.cp_log(p_action,p_page,p_request_id);end;$$;
revoke all on function greenloop_private.cp_log(text,text,uuid)from public,anon,authenticated;
revoke all on function public.log_content_protection_attempt_v1(text,text,uuid)from public,anon,authenticated;grant execute on function public.log_content_protection_attempt_v1(text,text,uuid)to authenticated;
insert into greenloop_private.office_routines values('public.log_content_protection_attempt_v1(text,text,uuid)','greenloop_private.cp_log(text,text,uuid)',md5(pg_get_functiondef('greenloop_private.cp_log(text,text,uuid)'::regprocedure)),md5(pg_get_functiondef('public.log_content_protection_attempt_v1(text,text,uuid)'::regprocedure)))on conflict(identity)do update set implementation=excluded.implementation,original_hash=excluded.original_hash,wrapped_hash=excluded.wrapped_hash;
-- View-only accounts may append only their own bounded security telemetry, never business edits.
insert into greenloop_private.capability_rpc_rules select 'log_content_protection_attempt_v1',jsonb_object_agg(page_key,jsonb_build_object('page',page_key,'capability','view'))||'{"dynamic":"filter_source","parameter":"p_page","read":true}'::jsonb from greenloop_private.page_capability_catalog on conflict(rpc_name)do update set rule=excluded.rule;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(r)order by rpc_name)::text)from greenloop_private.capability_rpc_rules r)where identity='rules';
create table if not exists greenloop_private.content_protection_installation(identity text primary key,hash text not null);
alter table greenloop_private.content_protection_installation enable row level security;revoke all on greenloop_private.content_protection_installation from public,anon,authenticated;
create or replace function public.get_content_protection_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=3 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.content_protection_installation)
 and not has_table_privilege('authenticated','greenloop_private.content_attempt_limits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.content_attempt_limits','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('authenticated','greenloop_private.cp_log(text,text,uuid)','EXECUTE')and not has_function_privilege('anon','public.log_content_protection_attempt_v1(text,text,uuid)','EXECUTE')
 and has_function_privilege('authenticated','public.log_content_protection_attempt_v1(text,text,uuid)','EXECUTE')
 and exists(select 1 from greenloop_private.suspicious_rules where key='content_protection')
 and exists(select 1 from pg_class where oid='greenloop_private.content_attempt_limits'::regclass and relrowsecurity)
 then '20261109-content-protection-1'end;$$;
revoke all on function public.get_content_protection_version()from public;grant execute on function public.get_content_protection_version()to anon,authenticated;
insert into greenloop_private.content_protection_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('greenloop_private.cp_log(text,text,uuid)'::regprocedure,'public.log_content_protection_attempt_v1(text,text,uuid)'::regprocedure,'public.get_content_protection_version()'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_content_protection_version()is distinct from '20261109-content-protection-1'
 or public.get_suspicious_activity_version()is distinct from '20261017-suspicious-activity-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Content protection verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$cp_install$;
select public.get_content_protection_version()as installed_content_protection_version;
