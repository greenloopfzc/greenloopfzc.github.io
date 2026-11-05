# Reports > Bulk IMEI Correction

An editable report table for one IMEI, an explicitly pasted IMEI list or a saved
Stock/Batch. The report button appears beside IMEI Data Correction.

User Access > Reports > IMEI Data Correction: enable Full IMEI Workflow Correction
and the separate Bulk IMEI Correction action. The report view tick is also needed.
Existing Owner/Super Admin workflow editors receive the new action. Other users
must be granted it explicitly. No operational page gains an editor.

Columns: S.No, IMEI/Stock, Model, GB, Color, Initial BH, Final BH, Supplier/Stock,
Supplier Grade, GL Grade, Parts Needed, Service Needed. Model/Color have saved
suggestions; GB and grades use dropdowns. Parts/services use inline selection,
plus and remove controls. New parts have one unit per IMEI; existing quantities
remain unchanged. Initial and Final BH edit distinct records.

Changed cells turn orange. Review / Save All Changes shows the exact old and new
values for each IMEI. Enter a reason and the existing correction code, then confirm.
The entire submitted set saves in one database transaction: an invalid, stale or
blocked row rolls back all changes. Failed requests keep edits. Identical request
retries replay once; changed payloads cannot reuse a request key.

Batch screens fetch 50 rows at a time with Previous/Next and ranges. Drafts stay
while moving between pages and Save All includes changed rows from those pages.
Explicit pasted lists load all matching IMEIs into the editing tray in 50-row read
requests, deduplicating the same phone's primary/secondary IMEI. Unmatched numbers
are reported. Existing rows are never saved just by loading, typing or paging.

Supplier references always use the actual receipt original quantity. Names still
require the existing confidential-name permission. Received, Returned, Replaced
and Balance appear independently. Supplier changes use a real Stock/Batch picker,
not editable code text. Downstream receipt changes require Full Workflow Correction.

Parts/services can change for saved inspections before transfer and active Lab
lines. Pending Lab parts may be cancelled or additional saved parts ordered.
Issued parts cannot be removed or relabelled; use Return/replacement order first.
Ready Stock or completed work needs normal Rework before new work is requested.
Phones held/returned to a supplier or recorded in a box remain protected. Final BH
requires an actual Final QC or Direct Initial QC Ready Stock result; no result is
invented. Editing a row never transfers the phone or rewrites receipt quantities.

Permanent private audit contains actor, time, reason and each phone's before/after
values. Full IMEI Workflow Correction > Correction History also shows these bulk
changes. Server checks Office access, report permissions, correction code, field
allowlist, exact device/job ownership, current revisions and physical dependencies.

Install additive migration 256 after verified 255. No business entries are changed
during installation. No Edge deployment, JWT, secret or password change is needed.
Run Publish-GreenLoop-Bulk-IMEI-Correction.ps1. Paste its clipboard SQL directly into
a NEW Supabase SQL query, RUN the complete SQL and check:
installed_bulk_imei_correction_version = 20261106-bulk-imei-correction-1.
Then Enter in PowerShell and wait for GREENLOOP BULK IMEI CORRECTION LIVE - VERIFIED.
Press Ctrl+F5 > Reports > Bulk IMEI Correction.
