# Approved EHTASHAM / Ehtesham employee merge

Release 20261031-employee-merge-1. Canonical employee: EHTESHAM.

This migration implements the specifically approved identity merge. It does not infer that other similar names are the same person.

The existing Ehtesham identity is retained when available; otherwise the existing EHTASHAM identity is retained and renamed. Original alias master IDs are archived, not deleted. The private permanent merge audit captures the old master records, assignments, timers, Parts labels, TV selections and affected damage report IDs.

Existing work-step and timer rows are relinked to the canonical roster ID without copying/deleting rows or changing recorded timer durations. Parts request employee labels are updated without changing parts, quantities, issues, returns or prices. User accounts, logins, roles and page permissions are not merged or changed.

Phones held for Supplier Return or already returned are included in this identity merge. A private transaction context allows only verified alias-to-canonical employee metadata changes on their work steps, timers and Parts labels. Their return records, status, approvals, handover slips and operational edit protections stay intact. Failed installation attempts roll back completely; run this revised installer in a new SQL query.

Raw damage reports and their original spelling snapshots remain untouched. A one-to-one read projection maps their existing report IDs to the canonical employee, including legacy name-only records. Corrections/deletions retain their existing effective state. Cards, employee history, TV views, Original/Copy totals and PDF exports use that same projection. TV allowlists map either approved identity to one canonical key.

Existing monthly payable rules run once for the merged person. The merged payable is recalculated from preserved incidents, not obtained by adding two separately calculated employee payables. Existing missing-price/department-conflict rules remain in force.

Adding either approved spelling through Initial QC, Lab & Glass or Damage choices reuses EHTESHAM; archived duplicate identities cannot be reactivated. New managed employee entries are normalized to capitals. This is not a fuzzy auto-merge for other employees.

The transaction stops and rolls back if the approved names or their catalog links cannot be verified. Before/after checks preserve raw damage records, report count, distinct IDs, quantities and Original/Copy amounts. Re-running the installer never repeats the merge or duplicates entries.

Run outputs/Publish-GreenLoop-Employee-Merge.ps1. It checks preceding versions first and copies the SQL for Supabase SQL Editor. Required result: installed_employee_merge_version = 20261031-employee-merge-1. The same result row includes merged_employee_summary with relinked record counts. Refresh Greenloop with Ctrl+F5 afterward.

Local tests use disposable data. The real business database is merged only when the SQL is run successfully. No Edge Function, JWT setting or secret change is required by this release.
