-- Run AFTER all updated website files have been verified live by the publisher.
-- Atomic final privacy restriction; no business records are modified.
begin;
do $ready$
begin
  if public.get_greenloop_audit_version() not in ('20260918-audit-2-prepared','20260918-audit-2') then
    raise exception 'Install the audit preparation update first.';
  end if;
end;
$ready$;
revoke select on public.suppliers, public.customers from public, anon, authenticated;

-- Table-level REVOKE does not revoke any pre-existing per-column SELECT grants.
do $revoke_partner_column_select$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['suppliers','customers'] loop
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_columns
      from pg_attribute as a where a.attrelid = to_regclass('public.' || v_table)
        and a.attnum > 0 and not a.attisdropped;
    execute format('revoke select (%s) on table public.%I from public, anon, authenticated', v_columns, v_table);
    if has_any_column_privilege('authenticated', 'public.' || v_table, 'SELECT')
       or has_any_column_privilege('anon', 'public.' || v_table, 'SELECT') then
      raise exception 'An inherited role still grants raw partner reads on %. No changes applied.', v_table;
    end if;
  end loop;
end;
$revoke_partner_column_select$;


create or replace function public.get_greenloop_audit_version()
returns text language sql immutable set search_path=public as $version$ select '20260918-audit-2'::text; $version$;
notify pgrst, 'reload schema';
commit;
select public.get_greenloop_audit_version() as installed_audit_version;
