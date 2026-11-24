-- Install through the publisher, which substitutes an offline-generated bcrypt hash.
begin;
set local lock_timeout = '5s';
create extension if not exists pgcrypto with schema extensions;

create table if not exists greenloop_private.deletion_credential (
  singleton boolean primary key default true check (singleton),
  password_hash text not null check (password_hash ~ '^\$2a\$12\$[./A-Za-z0-9]{53}$')
);
alter table greenloop_private.deletion_credential enable row level security;
revoke all on greenloop_private.deletion_credential from public, anon, authenticated;

insert into greenloop_private.deletion_credential (singleton, password_hash)
values (true, '__DELETION_PASSWORD_BCRYPT__')
on conflict (singleton) do update set password_hash = excluded.password_hash;

do $verifier$
declare
  crypto_schema name;
begin
  select n.nspname into strict crypto_schema
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  execute format($definition$
    create or replace function greenloop_private.valid_deletion_code(p_code text)
    returns boolean language sql stable security definer set search_path = pg_catalog as $body$
      select case when length(btrim(p_code)) between 6 and 32 and btrim(p_code) ~ '^[0-9]+$'
        then coalesce((select %I.crypt(btrim(p_code), password_hash) = password_hash
                       from greenloop_private.deletion_credential where singleton), false)
        else false end;
    $body$;
  $definition$, crypto_schema);
end;
$verifier$;
revoke all on function greenloop_private.valid_deletion_code(text) from public, anon, authenticated;

-- The Initial QC requirement is still a local draft at this point.
create or replace function public.get_initial_qc_deletion_code_valid_v1(p_code text)
returns boolean language plpgsql stable security definer set search_path = pg_catalog as $body$
begin
  perform greenloop_private.require_office_network();
  perform greenloop_private.pf_cap('initial_qc', 'entry');
  return greenloop_private.valid_deletion_code(p_code);
end;
$body$;
revoke all on function public.get_initial_qc_deletion_code_valid_v1(text) from public, anon, authenticated;
grant execute on function public.get_initial_qc_deletion_code_valid_v1(text) to authenticated;

create table if not exists greenloop_private.deletion_code_installation (
  identity text primary key,
  hash text not null
);
alter table greenloop_private.deletion_code_installation enable row level security;
revoke all on greenloop_private.deletion_code_installation from public, anon, authenticated;

do $patch$
declare
  target record;
  receipt record;
  columns record;
  signature regprocedure;
  before_ddl text;
  after_ddl text;
  before_hash text;
  after_hash text;
  pattern text;
  replacement text;
begin
  for target in
    select * from (values
      ('delete_greenloop_test_data_selectively(text,text,text,date,date,text[])', 'p_deletion_code'),
      ('remove_lab_technician(uuid,text)', 'p_deletion_code'),
      ('remove_supplier_from_receipts(uuid,text)', 'p_deletion_code'),
      ('delete_unused_supplier_company(uuid,text)', 'p_deletion_code'),
      ('delete_entry_option(uuid,text)', 'p_deletion_code'),
      ('execute_greenloop_deletion(text,text,text,text,text,text)', 'p_deletion_code'),
      ('delete_export_box_with_restore(uuid,text)', 'p_delete_code'),
      ('delete_export_box_by_number_with_restore(text,text)', 'p_delete_code'),
      ('delete_all_test_operational_data(text,text,date,date)', 'p_deletion_code'),
      ('delete_stock_channel(uuid,text)', 'p_deletion_code'),
      ('archive_supplier_company(uuid,text)', 'p_deletion_code'),
      ('reset_greenloop_to_zero(text,text)', 'p_deletion_code'),
      ('delete_technician_roster(uuid,text)', 'p_deletion_code'),
      ('public.archive_final_qc_failure_reason_v1(uuid,text)', 'p_deletion_code'),
      ('greenloop_private.rds_execute(text,jsonb,text,text,text,text)', 'p_deletion_code'),
      ('greenloop_private.wfs_action(uuid,text,text,text,text,text,text,uuid)', 'p_code')
    ) as items(api, parameter)
  loop
    if target.api like 'greenloop_private.%' then
      signature := to_regprocedure(target.api);
    else
      select to_regprocedure(coalesce(
        (select implementation from greenloop_private.capability_routines
         where to_regprocedure(identity) = to_regprocedure(target.api)),
        (select implementation from greenloop_private.office_routines
         where to_regprocedure(identity) = to_regprocedure(target.api))
      )) into signature;
    end if;
    before_ddl := pg_get_functiondef(signature);
    before_hash := md5(before_ddl);
    if before_ddl is null then
      raise exception 'Delete code routine is missing for %.', target.api;
    end if;

    if position('greenloop_private.valid_deletion_code(' in before_ddl) = 0 then
      if target.parameter = 'p_code' then
        -- A move-back operation retains its separate correction-code workflow.
        pattern := $rx$p_code\s+is\s+distinct\s+from\s+('[0-9]{4}')$rx$;
        replacement := $new$(case when p_action='delete' then not greenloop_private.valid_deletion_code(p_code) else p_code is distinct from \1 end)$new$;
      else
        pattern := format($rx$(?:coalesce\(\s*btrim\(\s*%1$s\s*\)\s*,\s*''\s*\)|coalesce\(\s*%1$s\s*,\s*''\s*\)|%1$s)\s*(?:<>|is\s+distinct\s+from)\s*'[0-9]{4}'$rx$, target.parameter);
        replacement := format('not greenloop_private.valid_deletion_code(%s)', target.parameter);
      end if;
      if (select count(*) from regexp_matches(before_ddl, pattern, 'g')) <> 1 then
        raise exception 'Could not verify the delete-code check in %.', target.api;
      end if;

      after_ddl := regexp_replace(before_ddl, pattern, replacement);
      execute after_ddl;
      after_hash := md5(pg_get_functiondef(signature));

      -- Reseal only receipts that identify this exact previously installed function.
      for columns in select * from (values
        ('identity','hash'), ('identity','before_hash'), ('identity','definition_hash'),
        ('object_identity','definition_hash'), ('function_identity','definition_hash')
      ) as names(id_column, hash_column)
      loop
        for receipt in
          select c.oid::regclass as relation
          from pg_class c
          where c.relnamespace = 'greenloop_private'::regnamespace and c.relkind = 'r'
            and c.relname like '%_installation' and c.relname <> 'deletion_code_installation'
            and exists (select 1 from pg_attribute where attrelid = c.oid and attname = columns.id_column and atttypid = 'text'::regtype)
            and exists (select 1 from pg_attribute where attrelid = c.oid and attname = columns.hash_column and atttypid = 'text'::regtype)
        loop
          execute format('update %s set %I=$1 where %I=$2 and to_regprocedure(%I)=$3',
            receipt.relation, columns.hash_column, columns.hash_column, columns.id_column)
            using after_hash, before_hash, signature;
        end loop;
      end loop;
      update greenloop_private.office_routines set original_hash = after_hash
        where original_hash = before_hash and to_regprocedure(implementation) = signature;
      update greenloop_private.capability_routines set original_hash = after_hash
        where original_hash = before_hash and to_regprocedure(implementation) = signature;
    end if;

    insert into greenloop_private.deletion_code_installation values (signature::text, md5(pg_get_functiondef(signature)))
    on conflict (identity) do update set hash = excluded.hash;
  end loop;

  insert into greenloop_private.deletion_code_installation
  select signature_text, md5(pg_get_functiondef(signature_text::regprocedure))
  from unnest(array[
    'greenloop_private.valid_deletion_code(text)',
    'public.get_initial_qc_deletion_code_valid_v1(text)'
  ]) as names(signature_text)
  on conflict (identity) do update set hash = excluded.hash;
end;
$patch$;

create or replace function public.get_deletion_code_version()
returns text language sql stable security definer set search_path = pg_catalog as $body$
  select case when
    (select count(*) = 18 and bool_and(coalesce(hash = md5(pg_get_functiondef(to_regprocedure(identity))), false))
     from greenloop_private.deletion_code_installation)
    and exists (select 1 from greenloop_private.deletion_credential where singleton)
    and not has_table_privilege('authenticated', 'greenloop_private.deletion_credential', 'SELECT')
    and not has_table_privilege('anon', 'greenloop_private.deletion_credential', 'SELECT')
    and not has_function_privilege('authenticated', 'greenloop_private.valid_deletion_code(text)', 'EXECUTE')
    and not has_function_privilege('anon', 'greenloop_private.valid_deletion_code(text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.get_initial_qc_deletion_code_valid_v1(text)', 'EXECUTE')
  then '20261124-delete-code-1' end;
$body$;
revoke all on function public.get_deletion_code_version() from public, anon, authenticated;
grant execute on function public.get_deletion_code_version() to anon, authenticated;

do $verify$
begin
  if public.get_deletion_code_version() is distinct from '20261124-delete-code-1' then
    raise exception 'Deletion code rotation could not be verified.';
  end if;
end;
$verify$;
notify pgrst, 'reload schema';
commit;
select public.get_deletion_code_version() as installed_deletion_code_version;
