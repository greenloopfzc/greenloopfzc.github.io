-- Read-only home overview and exact pending-receiving report scope. No stock changes.
DO $transfer_summary_install$ BEGIN EXECUTE $ddl$
do $patch$declare sig text:='greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)';old text;updated text;t record;c record;before_hash text;begin
 if public.get_chaman_report_cards_version()is distinct from '20261113-chaman-report-cards-1'then raise exception 'Install the verified Chaman report-cards update first.';end if;
 old:=pg_get_functiondef(sig::regprocedure);before_hash:=md5(old);updated:=old;
 if position('p_view in(''history'',''home'')'in old)=0 then
  if position('if p_view=''home''then rows:=''[]'';'in old)=0 or position('where(p_view not in(''balance'',''detail'')'in old)=0 then raise exception 'Chaman overview read boundary changed. Review before installing.';end if;
  updated:=replace(updated,'if p_view=''home''then rows:=''[]'';'||chr(10)||' elsif p_view in(''balance'',''detail'')then','if p_view in(''balance'',''detail'')then');
  updated:=replace(updated,'p_view=''history''or d.direction=p_view','p_view in(''history'',''home'')or d.direction=p_view');
  updated:=replace(updated,'where(p_view not in(''balance'',''detail'')',$scope$where(p_action is distinct from 'pending' or p_view in('out','return')and(r->>'pending')::bigint>0 or p_view='detail'and r->>'receipt_status'='Pending')and(p_view not in('balance','detail')$scope$);
  updated:=replace(updated,'''rows'',case when p_download then chosen',$home$'overview_version','20261113-chaman-overview-1','rows',case when p_view='home'then coalesce((select jsonb_agg(r order by n)from jsonb_array_elements(chosen)with ordinality a(r,n)where n<=5),'[]')when p_download then chosen$home$);
  if updated=old or position('if p_view=''home''then rows:=''[]'';'in updated)>0 then raise exception 'Chaman overview could not be applied.';end if;
  execute updated;
 end if;
 -- Preserve the reviewed routine's existing integrity receipts, including the complete-flow marker.
 for c in select *from(values('identity','hash'),('identity','before_hash'),('identity','definition_hash'),('object_identity','definition_hash'),('function_identity','definition_hash'))x(idcol,hashcol)loop
  for t in select cls.oid::regclass::text name from pg_class cls where cls.relnamespace='greenloop_private'::regnamespace and cls.relkind='r'and cls.relname like '%_installation'and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.idcol and atttypid='text'::regtype)and exists(select 1 from pg_attribute where attrelid=cls.oid and attname=c.hashcol and atttypid='text'::regtype)loop
   execute format('update %s set %I=md5(pg_get_functiondef(to_regprocedure($1)))where replace(%I,'' '','''')=replace($1,'' '','''')and %I=$2',t.name,c.hashcol,c.idcol,c.hashcol)using sig,before_hash;
  end loop;
 end loop;
 update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
 update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(sig::regprocedure))where to_regprocedure(implementation)=sig::regprocedure and original_hash=before_hash;
end;$patch$;
create table if not exists greenloop_private.chaman_overview_installation(identity text primary key,hash text not null);alter table greenloop_private.chaman_overview_installation enable row level security;revoke all on greenloop_private.chaman_overview_installation from public,anon,authenticated;
create or replace function public.get_chaman_overview_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when public.get_chaman_report_cards_version()='20261113-chaman-report-cards-1'
 and(select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.chaman_overview_installation)
 and not has_table_privilege('authenticated','greenloop_private.chaman_overview_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261113-chaman-overview-1'end;$$;
revoke all on function public.get_chaman_overview_version()from public;grant execute on function public.get_chaman_overview_version()to anon,authenticated;
insert into greenloop_private.chaman_overview_installation select sig,md5(pg_get_functiondef(sig::regprocedure))from unnest(array['greenloop_private.chaman_read_v2(text,uuid,text,date,date,integer,boolean,text,text,jsonb)','public.get_chaman_overview_version()'])sig on conflict(identity)do update set hash=excluded.hash;
do $$begin if public.get_chaman_overview_version()is distinct from '20261113-chaman-overview-1'then raise exception 'Chaman overview verification failed. Nothing installed.';end if;end;$$;
notify pgrst,'reload schema';
$ddl$;END;$transfer_summary_install$;
select public.get_chaman_overview_version()as installed_chaman_overview_version;
