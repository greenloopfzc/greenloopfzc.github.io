-- Lab requests the physical return. Only Parts classifies its reason.
begin;
do $$begin if public.get_parts_services_version()is distinct from '20261026-parts-services-separate-1'then raise exception 'Verified independent Parts / Lab Services support is required.';end if;if to_regprocedure('public.get_parts_return_review_version()')is not null then if public.get_parts_return_review_version()is distinct from '20261026-parts-return-review-1'then raise exception 'Existing Parts Return Review needs review.';end if;end if;end;$$;
alter table greenloop_private.parts_flow_returns drop constraint if exists parts_flow_returns_classification_check;
alter table greenloop_private.parts_flow_returns add constraint parts_flow_returns_classification_check check(classification in ('not_needed','damaged','faulty','other'));
alter table public.lab_part_return_requests drop constraint if exists lab_part_return_requests_return_reason_check;
alter table public.lab_part_return_requests add constraint lab_part_return_requests_return_reason_check check(return_reason in ('not_needed','damaged','faulty','other'));
alter table public.part_return_audit drop constraint if exists part_return_audit_return_condition_check;
alter table public.part_return_audit add constraint part_return_audit_return_condition_check check(return_condition in ('restocked','damaged','faulty','other'));
do $patch$declare n text;impl text;ddl text;needle text;replacement text;begin
 foreach n in array array['request_parts_flow_return_v1','review_parts_flow_return_v1']loop
 select implementation into impl from greenloop_private.office_routines r join pg_proc p on p.oid=to_regprocedure(r.identity)where p.pronamespace='public'::regnamespace and p.proname=n;
 if impl is null then raise exception 'Reviewed return implementation is missing: %',n;end if;ddl:=pg_get_functiondef(to_regprocedure(impl));
 if position('greenloop-parts-return-review-201'in ddl)=0 then
 if n='request_parts_flow_return_v1'then
 needle:='if p_quantity is null or p_quantity not between 1 and 10000';replacement:=E'-- greenloop-parts-return-review-201\n p_notes:=coalesce(nullif(btrim(p_notes),''''),''Awaiting Parts review.'');\n if p_quantity is null or p_quantity not between 1 and 10000';
 else
 needle:='if p_approve and(p_classification is null or p_classification not in (''not_needed'',''damaged'',''faulty'')';replacement:=E'-- greenloop-parts-return-review-201\n if p_approve and p_classification=''other'' and length(btrim(coalesce(p_notes,'''')))<2 then raise exception ''Parts must enter the other return reason.'' using errcode=''22023'';end if;\n if p_approve and(p_classification is null or p_classification not in (''not_needed'',''damaged'',''faulty'',''other'')';
 end if;
 if position(needle in ddl)=0 then raise exception 'Return source differs from the reviewed version: %',n;end if;ddl:=replace(ddl,needle,replacement);execute ddl;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(impl)))where implementation=impl;
 end if;
 end loop;
end;$patch$;
create table if not exists greenloop_private.parts_return_review_installation(kind text not null,identity text primary key,hash text not null);
alter table greenloop_private.parts_return_review_installation enable row level security;
revoke all on greenloop_private.parts_return_review_installation from public,anon,authenticated;
insert into greenloop_private.parts_return_review_installation select 'function',implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines r join pg_proc p on p.oid=to_regprocedure(r.identity)where p.pronamespace='public'::regnamespace and p.proname in ('request_parts_flow_return_v1','review_parts_flow_return_v1')on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.parts_return_review_installation select 'constraint',c.conrelid::regclass::text||'.'||c.conname,md5(pg_get_constraintdef(c.oid))from pg_constraint c where(c.conrelid='greenloop_private.parts_flow_returns'::regclass and c.conname='parts_flow_returns_classification_check')or(c.conrelid='public.lab_part_return_requests'::regclass and c.conname='lab_part_return_requests_return_reason_check')or(c.conrelid='public.part_return_audit'::regclass and c.conname='part_return_audit_return_condition_check')on conflict(identity)do update set hash=excluded.hash;
create or replace function public.get_parts_return_review_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_parts_services_version()='20261026-parts-services-separate-1'
 and(select count(*)=5 and bool_and(hash=case kind when 'function'then md5(pg_get_functiondef(to_regprocedure(identity)))else(select md5(pg_get_constraintdef(c.oid))from pg_constraint c where c.conrelid::regclass::text||'.'||c.conname=identity)end)from greenloop_private.parts_return_review_installation)
 and not has_table_privilege('authenticated','greenloop_private.parts_return_review_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('anon','greenloop_private.parts_return_review_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not exists(select 1 from greenloop_private.parts_return_review_installation where kind='function'and(has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')or has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')))
 then '20261026-parts-return-review-1'end;$$;
revoke all on function public.get_parts_return_review_version()from public;grant execute on function public.get_parts_return_review_version()to anon,authenticated;
do $$begin if public.get_parts_return_review_version()is distinct from '20261026-parts-return-review-1'then raise exception 'Parts Return Review verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_parts_return_review_version()as installed_parts_return_review_version;
