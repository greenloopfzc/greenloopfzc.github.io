-- Continue the active Lab clock from this job's first recorded Lab/Glass entry.
-- Existing completed stay timestamps and all movement records remain unchanged.
begin;
do $$begin
 if public.get_qc_auto_rules_version()is distinct from '20261031-qc-auto-rules-1'then raise exception 'Install the verified QC automatic rules first.';end if;
 if to_regprocedure('public.get_lab_return_clock_version()')is not null then if public.get_lab_return_clock_version()is distinct from '20261031-lab-return-clock-1'then raise exception 'Existing Lab return clock needs review.';end if;end if;
end;$$;
do $patch$declare f regprocedure:='greenloop_private.lab_stays_v1(uuid)'::regprocedure;ddl text;needle text;t record;begin
 ddl:=replace(pg_get_functiondef(f),chr(13)||chr(10),chr(10));
 if strpos(ddl,'greenloop-lab-return-clock-230')=0 then
  needle:='), stays as(select e.device_id,e.job_id,min(e.moved_at) arrived,e.ended from entries e group by e.device_id,e.job_id,e.ended)';
  if strpos(ddl,needle)=0 then raise exception 'Reviewed Lab stay grouping differs. Nothing was installed.';end if;
  ddl:=replace(ddl,needle,needle||E',\n -- greenloop-lab-return-clock-230\n first_entries as(select device_id,job_id,min(moved_at)arrived from entries group by device_id,job_id),\n clock_stays as(select s.*,case when s.ended is null then f.arrived else s.arrived end clock_arrived from stays s join first_entries f using(device_id,job_id))');
  needle:='select s.device_id,s.job_id,s.arrived,s.ended,extract(epoch from coalesce(s.ended,now())-s.arrived),s.ended is null';
  if strpos(ddl,needle)=0 then raise exception 'Reviewed Lab stay clock differs.';end if;
  ddl:=replace(ddl,needle,'select s.device_id,s.job_id,s.clock_arrived,s.ended,extract(epoch from coalesce(s.ended,now())-s.clock_arrived),s.ended is null');
  needle:='from stays s join public.jobs j';if strpos(ddl,needle)=0 then raise exception 'Reviewed Lab stay access boundary differs.';end if;
  execute replace(ddl,needle,'from clock_stays s join public.jobs j');
 end if;
 -- Re-seal only the reviewed read-only function; retain every existing access guard.
 for t in select c.table_name from information_schema.columns c join information_schema.columns h on h.table_schema=c.table_schema and h.table_name=c.table_name and h.column_name='hash'where c.table_schema='greenloop_private'and c.column_name='identity'and c.table_name like '%\_installation'escape '\'loop
  execute format('update greenloop_private.%I set hash=md5(pg_get_functiondef($1))where to_regprocedure(identity)=$1',t.table_name)using f;
 end loop;
end;$patch$;
create table if not exists greenloop_private.lab_return_clock_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_return_clock_installation enable row level security;
revoke all on greenloop_private.lab_return_clock_installation from public,anon,authenticated;
create or replace function public.get_lab_return_clock_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_qc_auto_rules_version()='20261031-qc-auto-rules-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_return_clock_installation)
 and exists(select 1 from pg_class where oid='greenloop_private.lab_return_clock_installation'::regclass and relrowsecurity)
 and not has_table_privilege('anon','greenloop_private.lab_return_clock_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')and not has_table_privilege('authenticated','greenloop_private.lab_return_clock_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_function_privilege('anon','greenloop_private.lab_stays_v1(uuid)','EXECUTE')and not has_function_privilege('authenticated','greenloop_private.lab_stays_v1(uuid)','EXECUTE')
 then '20261031-lab-return-clock-1'end;
$$;
revoke all on function public.get_lab_return_clock_version()from public;grant execute on function public.get_lab_return_clock_version()to anon,authenticated;
insert into greenloop_private.lab_return_clock_installation select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))from pg_proc p where p.oid in('public.get_lab_return_clock_version()'::regprocedure,'greenloop_private.lab_stays_v1(uuid)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_lab_return_clock_version()is distinct from '20261031-lab-return-clock-1'then raise exception 'Lab return clock verification failed. Nothing was installed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_lab_return_clock_version()as installed_lab_return_clock_version;
