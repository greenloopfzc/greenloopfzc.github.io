-- The empty grade-analysis filter is the all-stock selection.
begin;
set local lock_timeout='5s';

create table if not exists greenloop_private.stock_grade_all_scope_installation (
  identity text primary key,
  hash text not null
);
alter table greenloop_private.stock_grade_all_scope_installation enable row level security;
revoke all on greenloop_private.stock_grade_all_scope_installation from public,anon,authenticated;

do $install$
declare
  edit record;
  fragment record;
  routine regprocedure;
  ddl text;
  prior_hash text;
  new_hash text;
  body_hash text;
  has_receipt boolean;
  receipt record;
begin
  if to_regprocedure('public.get_stock_grade_analysis_all_version_v2()') is not null then
    if public.get_stock_grade_analysis_all_version_v2() is distinct from '20261123-stock-grade-analysis-all-2' then
      raise exception 'Existing All Stock Grade Analysis could not be verified.';
    end if;
    return;
  end if;

  -- Prove the four routines used by this read-only feature. The old report
  -- marker also checks an Initial QC write routine outside this release.
  for edit in select * from (values
    ('greenloop_private.sga_access(jsonb,boolean)','5c2643e8fab8236ad89f5adad7fd68d9','579f5cd8218c1f27f8b4ee8661f84ac4',jsonb_build_array(
      jsonb_build_array(
        $old$if download and not exists(select 1 from jsonb_each_text(f)e where nullif(e.value,'')is not null)then raise exception 'Select stock before creating its PDF.'using errcode='22023';end if;$old$,'')
    )),
    ('greenloop_private.sga_report(jsonb,boolean,text)','b8bb6727bd8447fb0e426e3edd95db73','16e46e74b8dcd2ee10140628b795a6cc',jsonb_build_array(
      jsonb_build_array('selected boolean;', 'has_filter boolean;'),
      jsonb_build_array('selected:=exists','has_filter:=exists'),
      jsonb_build_array('b where selected and(', 'b where ('),
      jsonb_build_array('if selected and jsonb_array_length(stocks)=0', 'if has_filter and jsonb_array_length(stocks)=0'),
      jsonb_build_array('if selected then',''),
      jsonb_build_array(
        $old$else rows:='[]';totals:='{"qty":0,"a":0,"b":0,"d":0,"other":0,"pending":0,"qc_waiting":0,"grade_missing":0,"qc_record_missing":0,"saved_grade_used":0,"returned_ungraded":0,"glass":0,"polish":0,"returned":0}';other:='[]';phone_snapshot:=md5('[]');end if;$old$,''),
      jsonb_build_array($old$'selected',selected,$old$,$new$'selected',true,$new$)
    )),
    ('greenloop_private.sgc_rows(jsonb)','d956f5df0e4b7e902e9dc8bd0d7a27ea','29a807aa693a58c27920357b726fcb18',jsonb_build_array(
      jsonb_build_array('/* su-original-grade-units */ and(',
        $new$/* su-original-grade-units */
   and not exists (select 1 from greenloop_private.srp_receipts r where r.replacement_batch_id=b.id)
   and($new$)
    )),
    ('greenloop_private.sga_phone_details(jsonb,text,integer,text,text)','d5bd94874066a80d278c2e58afe84e42','5473638e226379841000320d6a40cfe3',jsonb_build_array(
      jsonb_build_array(
        $old$if not(summary->>'selected')::boolean then raise exception 'Select supplier, stock / batch or invoice first.'using errcode='22023';end if;$old$,
        $new$perform greenloop_private.rp_require('stock_grade_analysis','search');$new$),
      jsonb_build_array('),details as(',
        $new$),stocks as materialized (
  select (s->>'batch_id')::uuid batch_id,s from jsonb_array_elements(summary->'stocks') s
 ),details as($new$),
      jsonb_build_array(
        $old$join lateral(select value from jsonb_array_elements(summary->'stocks')where value->>'batch_id'=p.batch_id::text limit 1)stock(s)on true$old$,
        'join stocks stock on stock.batch_id=p.batch_id')
    ))
  ) as changes(signature,expected_base,expected_all,fragments) loop
    routine:=to_regprocedure(edit.signature);
    if routine is null or not exists (
      select 1 from pg_proc p where p.oid=routine and p.prosecdef and p.provolatile='s'
        and p.proconfig=array['search_path=pg_catalog, public']
    ) or has_function_privilege('anon',routine,'EXECUTE')
      or has_function_privilege('authenticated',routine,'EXECUTE') then
      raise exception 'Stock Grade routine is missing or its access differs: %',edit.signature;
    end if;
    ddl:=pg_get_functiondef(routine);
    prior_hash:=md5(ddl);
    select md5(replace(p.prosrc,chr(13),'')) into body_hash from pg_proc p where p.oid=routine;

    if body_hash=edit.expected_all then
      insert into greenloop_private.stock_grade_all_scope_installation values(edit.signature,prior_hash);
      continue;
    end if;
    if body_hash is distinct from edit.expected_base then
      has_receipt:=false;
      if to_regclass('greenloop_private.returned_grade_report_installation') is not null then
        select exists (
          select 1 from greenloop_private.returned_grade_report_installation
          where identity=edit.signature and hash=prior_hash
        ) into has_receipt;
      end if;
      if not has_receipt or edit.signature='greenloop_private.sgc_rows(jsonb)'
          and strpos(ddl,'not p.was_returned')=0 then
        raise exception 'Existing Stock Grade report definition differs: %',edit.signature;
      end if;
    end if;

    ddl:=replace(ddl,chr(13),'');
    for fragment in
      select replace(value->>0,chr(13),'') as before_text,replace(value->>1,chr(13),'') as after_text
      from jsonb_array_elements(edit.fragments)
    loop
      if cardinality(string_to_array(ddl,fragment.before_text)) is distinct from 2 then
        raise exception 'Stock grade code block differs in %: %',edit.signature,left(fragment.before_text,60);
      end if;
      ddl:=replace(ddl,fragment.before_text,fragment.after_text);
    end loop;
    execute ddl;
    new_hash:=md5(pg_get_functiondef(routine));
    insert into greenloop_private.stock_grade_all_scope_installation values(edit.signature,new_hash);

    for receipt in
      select c.oid::regclass as table_name
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='greenloop_private' and c.relkind='r' and c.relname like '%\_installation'
        and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='identity' and a.atttypid='text'::regtype)
        and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='hash' and a.atttypid='text'::regtype)
    loop
      execute format('update %s set hash=$1 where identity=$2 and hash=$3',receipt.table_name)
      using new_hash,edit.signature,prior_hash;
    end loop;
  end loop;
end;
$install$;

create or replace function public.get_stock_grade_analysis_all_version_v2()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case
    when (select count(*)=4 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false)
           and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')
           and not has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE'))
          from greenloop_private.stock_grade_all_scope_installation)
     and strpos(pg_get_functiondef('greenloop_private.sga_report(jsonb,boolean,text)'::regprocedure),'''selected'',true')>0
     and strpos(pg_get_functiondef('greenloop_private.sga_phone_details(jsonb,text,integer,text,text)'::regprocedure),'join stocks stock')>0
     and strpos(pg_get_functiondef('greenloop_private.sga_access(jsonb,boolean)'::regprocedure),'Select stock before creating its PDF.')=0
     and not exists (
       select 1 from unnest(array[
         'public.get_stock_grade_analysis_v1(jsonb)',
         'public.export_stock_grade_analysis_v1(jsonb,text)',
         'public.get_stock_grade_phone_details_v1(jsonb,text,integer,text,text)'
       ]) f
       where to_regprocedure(f) is null or has_function_privilege('anon',f,'EXECUTE')
          or not has_function_privilege('authenticated',f,'EXECUTE')
     )
    then '20261123-stock-grade-analysis-all-2'
  end;
$version$;
revoke all on function public.get_stock_grade_analysis_all_version_v2() from public;
grant execute on function public.get_stock_grade_analysis_all_version_v2() to anon,authenticated;

do $verify$
begin
  if public.get_stock_grade_analysis_all_version_v2() is distinct from '20261123-stock-grade-analysis-all-2' then
    raise exception 'Stock Grade Analysis All could not be verified.';
  end if;
end;
$verify$;
notify pgrst,'reload schema';
commit;
select public.get_stock_grade_analysis_all_version_v2() as installed_stock_grade_analysis_all_version;
