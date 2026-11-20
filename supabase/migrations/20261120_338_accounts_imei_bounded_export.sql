-- Bounded, snapshot-checked IMEI export pages through the existing report permission.
do $install$
declare
  reader regprocedure := 'greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)'::regprocedure;
  source text;
  revised text;
  before_hash text;
  after_hash text;
  reviewed_change record;
  seal record;
begin
  if to_regprocedure('public.get_accounts_imei_bounded_export_version()') is not null then
    if public.get_accounts_imei_bounded_export_version() is distinct from '20261120-accounts-imei-bounded-export-1' then
      raise exception 'The existing IMEI export page installation did not verify.';
    end if;
    return;
  end if;

  if public.get_accounts_imei_all_downloads_version() is distinct from '20261120-accounts-imei-all-downloads-1' then
    raise exception 'Verify the Accounts IMEI All Downloads update first.';
  end if;
  select replace(pg_get_functiondef(oid),chr(13),''),md5(pg_get_functiondef(oid))
    into strict source,before_hash from pg_proc
    where oid=reader and md5(replace(prosrc,chr(13),''))='be820ddbcecee179de9e597cc007990b';
  if not exists (
    select 1 from greenloop_private.accounts_imei_speed_installation
    where to_regprocedure(identity)=reader and hash=before_hash
  ) then
    raise exception 'The current IMEI card reader did not match its verified definition.';
  end if;

  revised:=source;
  for reviewed_change in select replace(v.before_text,chr(13),'') before_text,
    replace(v.after_text,chr(13),'') after_text from (values
    ('metric_key text;result jsonb;', $new$metric_key text;result jsonb;
 export_page boolean:=p_kind='imei' and p_download and p_limit>50;$new$),
    ('p_limit not between 1 and 50', $new$p_limit not between 1 and (case when export_page then 500 else 50 end)$new$),
    ($old$ if p_kind='imei' then
  perform greenloop_private.aid_access$old$, $new$ if export_page and (p_summary_only or p_expected_snapshot is null or p_expected_snapshot !~ '^[a-f0-9]{32}$') then
  raise exception 'Refresh the IMEI DATA selection before downloading.' using errcode='22023';
 end if;
 if p_kind='imei' then
  perform greenloop_private.aid_access$new$),
    ($old$when p_download then selected else coalesce($old$, $new$when p_download and not export_page then selected else coalesce($new$),
    ($old$token:=md5(jsonb_build_array(p_kind,p_filters,p_metric,selected,base->'stock_summary',greenloop_private.chaman_counts(ids))::text);$old$,
     $new$token:=md5(jsonb_build_array(p_kind,p_filters,p_metric,selected,base->'stock_summary',greenloop_private.chaman_counts(ids),
  case when p_kind='imei' and not receipt_mode then (
    select jsonb_agg(jsonb_build_array(l.job_id,l.phase) order by l.job_id,l.custody_order,l.id)
    from greenloop_private.chaman_lines l
    where l.phase<>'company' and l.voided_at is null and l.job_id::text in (
      select r->>'job_id' from jsonb_array_elements(selected) r
    )
  ) end)::text);$new$),
    ($old$n<=p_offset+p_limit$old$, $new$n<=p_offset::bigint+p_limit$new$),
    ($old$when p_download then selected else result->'rows'end$old$, $new$when p_download and not export_page then selected else result->'rows'end$new$),
    ($old$if p_kind='imei'then result:=jsonb_set(result,'{rows}',greenloop_private.isu_hydrate(result->'rows'));end if;$old$,
     $new$if export_page then
  -- File generators use the ordered report rows and exchange pairs. Avoid sending
  -- the duplicated histories used by the on-screen record details.
  result:=jsonb_set(result,'{rows}',coalesce((
    select jsonb_agg(r-array['unit_original','unit_history'] order by n)
    from jsonb_array_elements(result->'rows') with ordinality x(r,n)
  ),'[]'::jsonb))||jsonb_build_object('download_offset',p_offset,'download_limit',p_limit);
 elsif p_kind='imei' then
  result:=jsonb_set(result,'{rows}',greenloop_private.isu_hydrate(result->'rows'));
 end if;$new$)
  ) as v(before_text,after_text) loop
    if length(revised)-length(replace(revised,reviewed_change.before_text,''))<>length(reviewed_change.before_text) then
      raise exception 'The reviewed IMEI export boundary changed. Nothing installed.';
    end if;
    revised:=replace(revised,reviewed_change.before_text,reviewed_change.after_text);
  end loop;
  execute revised;
  after_hash:=md5(pg_get_functiondef(reader));

  -- Update only seals for this routine that matched the reviewed old definition.
  for seal in
    select c.oid::regclass table_name, h.attname hash_col, i.attname id_col
    from pg_class c
    join pg_attribute h on h.attrelid=c.oid and h.attname in ('hash','definition_hash','before_hash') and h.atttypid='text'::regtype
    join pg_attribute i on i.attrelid=c.oid and i.attname in ('identity','object_identity','function_identity') and i.atttypid='text'::regtype
    where c.relnamespace='greenloop_private'::regnamespace and c.relkind='r' and c.relname like '%_installation'
  loop
    execute format('update %s set %I=$1 where to_regprocedure(%I)=$2 and %I=$3',seal.table_name,seal.hash_col,seal.id_col,seal.hash_col)
      using after_hash,reader,before_hash;
  end loop;
  update greenloop_private.office_routines set original_hash=after_hash
    where to_regprocedure(implementation)=reader and original_hash=before_hash;
  update greenloop_private.capability_routines set original_hash=after_hash
    where to_regprocedure(implementation)=reader and original_hash=before_hash;

  execute $ddl$
  create table greenloop_private.accounts_imei_bounded_export_installation(
    identity text primary key,hash text not null
  );
  alter table greenloop_private.accounts_imei_bounded_export_installation enable row level security;
  revoke all on greenloop_private.accounts_imei_bounded_export_installation from public,anon,authenticated;
  create or replace function public.get_accounts_imei_bounded_export_version() returns text
  language sql stable security definer set search_path=pg_catalog,public as $version$
    select case when (
      select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.accounts_imei_bounded_export_installation
    )
    and not has_function_privilege('anon','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','EXECUTE')
    and not has_function_privilege('authenticated','greenloop_private.acard_report(text,jsonb,text,integer,integer,text,text,boolean,boolean,text)','EXECUTE')
    and public.get_accounts_imei_all_downloads_version()='20261120-accounts-imei-all-downloads-1'
    then '20261120-accounts-imei-bounded-export-1' end;
  $version$;
  revoke all on function public.get_accounts_imei_bounded_export_version() from public;
  grant execute on function public.get_accounts_imei_bounded_export_version() to anon,authenticated;
  $ddl$;

  insert into greenloop_private.accounts_imei_bounded_export_installation values
    (reader::text,after_hash),
    ('public.get_accounts_imei_bounded_export_version()',md5(pg_get_functiondef('public.get_accounts_imei_bounded_export_version()'::regprocedure)));
  if public.get_accounts_imei_bounded_export_version() is distinct from '20261120-accounts-imei-bounded-export-1' then
    raise exception 'IMEI export page verification failed. Nothing installed.';
  end if;
  notify pgrst,'reload schema';
end
$install$;
select public.get_accounts_imei_bounded_export_version() as installed_accounts_imei_bounded_export_version;
