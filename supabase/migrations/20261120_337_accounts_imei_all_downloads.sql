-- Annotate complete Accounts exports without repeatedly copying their row arrays.
do $install$
declare
  mapper regprocedure := 'greenloop_private.chaman_accounts(jsonb,uuid[])'::regprocedure;
  before_hash text;
  after_hash text;
begin
  if to_regprocedure('public.get_accounts_imei_all_downloads_version()') is not null then
    if public.get_accounts_imei_all_downloads_version() is distinct from '20261120-accounts-imei-all-downloads-1' then
      raise exception 'Accounts IMEI export verification differs. Nothing installed.';
    end if;
    return;
  end if;

  select md5(pg_get_functiondef(oid)) into strict before_hash from pg_proc
  where oid=mapper and md5(replace(prosrc,chr(13),''))='e67d454c6ab1fe714ee7b235ae99ec3e';
  if not exists (
    select 1 from greenloop_private.chaman_flow_installation
    where to_regprocedure(identity)=mapper and hash=before_hash
  ) then
    raise exception 'The reviewed Chaman display routine does not match its installation record.';
  end if;

  execute $ddl$
  create or replace function greenloop_private.chaman_accounts(p_data jsonb,p_ids uuid[])
  returns jsonb language sql stable security definer set search_path=pg_catalog,public as $format$
    with active_custody as (
      select distinct on (l.job_id) l.job_id::text job_key,l.phase
      from greenloop_private.chaman_lines l
      where l.phase<>'company' and l.voided_at is null
      order by l.job_id,l.custody_order desc,l.id
    ), formatted as (
      select coalesce(jsonb_agg(
        case when c.phase is null then x.record
          else x.record||jsonb_build_object('stage',case c.phase
            when 'out_pending' then 'Chaman — Pending receipt'
            when 'shop' then 'Chaman — Received'
            else 'Chaman return — Pending Greenloop receipt' end)
        end order by x.position),'[]'::jsonb) rows
      from jsonb_array_elements(p_data->'rows') with ordinality x(record,position)
      left join active_custody c on c.job_key=x.record->>'job_id'
    )
    select jsonb_set(p_data,'{rows}',formatted.rows)
      ||jsonb_build_object('chaman_summary',greenloop_private.chaman_counts(p_ids))
    from formatted;
  $format$;
  revoke all on function greenloop_private.chaman_accounts(jsonb,uuid[]) from public,anon,authenticated;

  create table if not exists greenloop_private.accounts_imei_download_installation(
    identity text primary key,hash text not null
  );
  alter table greenloop_private.accounts_imei_download_installation enable row level security;
  revoke all on greenloop_private.accounts_imei_download_installation from public,anon,authenticated;

  create or replace function public.get_accounts_imei_all_downloads_version() returns text
  language sql stable security definer set search_path=pg_catalog,public as $version$
    select case when (
      select count(*)=2 and bool_and(coalesce(hash=md5(pg_get_functiondef(to_regprocedure(identity))),false))
      from greenloop_private.accounts_imei_download_installation
    ) and exists (
      select 1 from greenloop_private.chaman_flow_installation
      where to_regprocedure(identity)='greenloop_private.chaman_accounts(jsonb,uuid[])'::regprocedure
        and hash=md5(pg_get_functiondef(to_regprocedure(identity)))
    )
    and not has_function_privilege('anon','greenloop_private.chaman_accounts(jsonb,uuid[])','EXECUTE')
    and not has_function_privilege('authenticated','greenloop_private.chaman_accounts(jsonb,uuid[])','EXECUTE')
    and public.get_accounts_imei_speed_version()='20261113-accounts-imei-speed-1'
    then '20261120-accounts-imei-all-downloads-1' end;
  $version$;
  revoke all on function public.get_accounts_imei_all_downloads_version() from public;
  grant execute on function public.get_accounts_imei_all_downloads_version() to anon,authenticated;
  $ddl$;

  after_hash:=md5(pg_get_functiondef(mapper));
  update greenloop_private.chaman_flow_installation set hash=after_hash
  where to_regprocedure(identity)=mapper and hash=before_hash;
  insert into greenloop_private.accounts_imei_download_installation(identity,hash) values
    (mapper::text,after_hash),
    ('public.get_accounts_imei_all_downloads_version()',md5(pg_get_functiondef('public.get_accounts_imei_all_downloads_version()'::regprocedure)));
  if public.get_accounts_imei_all_downloads_version() is distinct from '20261120-accounts-imei-all-downloads-1' then
    raise exception 'Accounts IMEI export verification failed. Nothing installed.';
  end if;
  notify pgrst,'reload schema';
end
$install$;
select public.get_accounts_imei_all_downloads_version() as installed_accounts_imei_all_downloads_version;
