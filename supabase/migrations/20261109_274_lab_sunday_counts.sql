-- Align Dashboard overdue cards, detail rows and recorded delay history with Lab & Glass.
-- Sunday (Asia/Dubai) contributes zero time. No arrivals, assignments or business rows change.
do $lsc_install$begin
do $$begin
 if public.get_lab_technician_visibility_version()is distinct from '20261109-lab-technician-visibility-1'
 or public.get_lab_overdue_card_version()is distinct from '20261105-lab-overdue-card-1'
 or public.get_tv_month_sunday_version()is distinct from '20261102-tv-month-sunday-1'
 or public.get_lab_return_clock_version()is distinct from '20261031-lab-return-clock-1'
 or public.get_stock_bulk_search_version()is distinct from '20261105-stock-bulk-search-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Verified Lab, original-arrival clock and office installations are required.';end if;
 if to_regprocedure('public.get_lab_sunday_counts_version()')is not null then
  if public.get_lab_sunday_counts_version()is distinct from '20261109-lab-sunday-counts-1'then raise exception 'Existing Sunday-free Lab counts integrity differs.';end if;
 end if;
end;$$;
do $patch$declare f record;impl regprocedure;ddl text;body_hash text;needle text;begin
 for f in select *from(values
 ('public.get_lab_overdue_v1(jsonb,integer,integer,text,text)','93e2a01c613a81ec389863fd7444974e'),
 ('public.get_lab_delay_history_v1(text,text)','0381eef49d1240263b8dafe504dc59d3'))x(sig,expected_hash)loop
  select to_regprocedure(implementation)into strict impl from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure(f.sig);
  select replace(pg_get_functiondef(oid),chr(13),''),md5(replace(prosrc,chr(13),''))into ddl,body_hash from pg_proc where oid=impl;
  if position('greenloop-sunday-free-lab-274'in ddl)=0 then
   if body_hash is distinct from f.expected_hash then raise exception 'Reviewed Lab overdue reader differs: %. Nothing was installed.',f.sig;end if;
   if f.sig like '%get_lab_overdue_v1%'then
    needle:='st.entered_at,st.elapsed_seconds,j.job_number,sp.supplier_code';
    if position(needle in ddl)=0 then raise exception 'Reviewed Dashboard waiting-time clause is missing.';end if;
    ddl:=replace(ddl,needle,'st.entered_at,greenloop_private.tv_work_seconds(st.entered_at,now())elapsed_seconds,j.job_number,coalesce(receipt.supplier_code,sp.supplier_code)||case when receipt.received_quantity is not null then ''-(''||receipt.received_quantity::text||'')''else ''''end supplier_code');
    needle:='left join public.suppliers sp on sp.id=j.supplier_id';
    if position(needle in ddl)=0 then raise exception 'Reviewed Dashboard receipt join is missing.';end if;
    ddl:=replace(ddl,needle,needle||' left join greenloop_private.sc_receipts()receipt on receipt.batch_id=j.receiving_batch_id');
    needle:='where st.ongoing and st.elapsed_seconds>=172800';
    if position(needle in ddl)=0 then raise exception 'Reviewed Dashboard overdue threshold is missing.';end if;
    ddl:=replace(ddl,needle,'where st.ongoing and greenloop_private.tv_work_seconds(st.entered_at,now())>172800');
   else
    needle:='s.elapsed_seconds>=172800';
    if position(needle in ddl)=0 then raise exception 'Reviewed history overdue threshold is missing.';end if;
    ddl:=replace(ddl,needle,'greenloop_private.tv_work_seconds(s.entered_at,coalesce(s.exited_at,now()))>172800');
    ddl:=replace(ddl,'s.elapsed_seconds','greenloop_private.tv_work_seconds(s.entered_at,coalesce(s.exited_at,now()))');
   end if;
   needle:='''threshold_hours'',48';
   if position(needle in ddl)=0 then raise exception 'Reviewed Lab threshold metadata is missing.';end if;
   ddl:=replace(ddl,needle,needle||',''sunday_excluded'',true');
   execute replace(ddl,'declare ',E'-- greenloop-sunday-free-lab-274\ndeclare ');
  end if;
  -- Re-seal only the two reviewed private readers; the public office wrappers stay intact.
  update greenloop_private.office_routines set original_hash=md5(pg_get_functiondef(impl))where to_regprocedure(identity)=to_regprocedure(f.sig)and to_regprocedure(implementation)=impl;
  if f.sig like '%get_lab_overdue_v1%'then
   update greenloop_private.stock_bulk_search_installation set hash=md5(pg_get_functiondef(impl))where to_regprocedure(identity)=impl;
   if not found then raise exception 'Dashboard bulk-search verification row is missing.';end if;
  end if;
 end loop;
end;$patch$;
create table if not exists greenloop_private.lab_sunday_counts_installation(identity text primary key,hash text not null);
alter table greenloop_private.lab_sunday_counts_installation enable row level security;revoke all on greenloop_private.lab_sunday_counts_installation from public,anon,authenticated;
create or replace function public.get_lab_sunday_counts_version()returns text language sql stable security definer set search_path=pg_catalog,public as $$select case when
 (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))from greenloop_private.lab_sunday_counts_installation)
 and (select count(*)=2 and bool_and(position('greenloop-sunday-free-lab-274'in p.prosrc)>0 and not has_function_privilege('authenticated',p.oid,'EXECUTE')and not has_function_privilege('anon',p.oid,'EXECUTE'))from greenloop_private.office_routines o join pg_proc p on p.oid=to_regprocedure(o.implementation)where to_regprocedure(o.identity)in('public.get_lab_overdue_v1(jsonb,integer,integer,text,text)'::regprocedure,'public.get_lab_delay_history_v1(text,text)'::regprocedure))
 and not has_table_privilege('authenticated','greenloop_private.lab_sunday_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.lab_sunday_counts_installation','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 then '20261109-lab-sunday-counts-1'end;$$;
revoke all on function public.get_lab_sunday_counts_version()from public;grant execute on function public.get_lab_sunday_counts_version()to anon,authenticated;
insert into greenloop_private.lab_sunday_counts_installation select implementation,md5(pg_get_functiondef(to_regprocedure(implementation)))from greenloop_private.office_routines where to_regprocedure(identity)in('public.get_lab_overdue_v1(jsonb,integer,integer,text,text)'::regprocedure,'public.get_lab_delay_history_v1(text,text)'::regprocedure)on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.lab_sunday_counts_installation values('greenloop_private.tv_work_seconds(timestamp with time zone,timestamp with time zone)',md5(pg_get_functiondef('greenloop_private.tv_work_seconds(timestamptz,timestamptz)'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
insert into greenloop_private.lab_sunday_counts_installation values('public.get_lab_sunday_counts_version()',md5(pg_get_functiondef('public.get_lab_sunday_counts_version()'::regprocedure)))on conflict(identity)do update set hash=excluded.hash;
do $$begin
 if public.get_lab_sunday_counts_version()is distinct from '20261109-lab-sunday-counts-1'
 or public.get_lab_delay_version()is distinct from '20261024-lab-delay-1'
 or public.get_lab_overdue_card_version()is distinct from '20261105-lab-overdue-card-1'
 or public.get_stock_bulk_search_version()is distinct from '20261105-stock-bulk-search-1'
 or public.get_page_capabilities_version()is distinct from '20261016-page-capabilities-1'
 or public.get_office_access_version()is distinct from '20261024-office-access-1'
 then raise exception 'Sunday-free Lab count verification failed. Installation rolled back.';end if;
end;$$;
notify pgrst,'reload schema';
end;$lsc_install$;
select public.get_lab_sunday_counts_version()as installed_lab_sunday_counts_version;
