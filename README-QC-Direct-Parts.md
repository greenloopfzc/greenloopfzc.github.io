# Initial QC direct Parts workflow

Saving Initial QC with required physical parts now creates the normal Parts order in the same database transaction that sends the phone to Lab. The existing Initial QC API, entry permission, role validation, Office Only check and routing remain in use. A failed parts publication rolls the QC save back. Services remain exclusively in Lab; service-only QC does not create an empty Parts order. Phones without a selected technician remain unassigned and visible in Lab and Parts reports.

The Lab line shows the already submitted required parts and Order Additional Parts. New different parts may be ordered before or after the first issue. An already pending part cannot be ordered again. An issued part needs an unused return quantity before a replacement can be ordered; each return quantity can authorize a replacement only once. Parts still decides the return classification and must approve the return before issuing its replacement. Rejected returns cancel their unissued replacements. Unissued requests may be removed; issued requests must be returned. Old full-list submission APIs cannot overwrite a submitted order.

The source order, original requests, issue prices, returns and service history are preserved. Installation also queues safe pending first-cycle QC lists that have no existing orders, requests or manual installations. It never rebuilds an existing issued/order history or merges unrelated unlinked requests. Pending badges continue to count distinct IMEIs. Technician Parts Report dropdowns, filtered bottom totals, flat table controls and exports remain included.

Three existing Initial QC completion actions are explicitly mapped to their existing entry permission in the browser action map. No account receives an additional permission. New private helpers and tracking tables are inaccessible to normal accounts. The installer checks the previous verified release, updates only four reviewed private implementation bodies and their matching receipts, and validates every previous verification component before committing. Replay is safe and refuses a changed existing direct-QC installation.

Run outputs/Publish-GreenLoop-QC-Direct-Parts.ps1. After prior required updates are verified, it copies Install-QC-Direct-Parts.sql. In a NEW Supabase SQL Editor query paste the clipboard directly and run the complete SQL. Required final result:

installed_qc_direct_parts_version = 20261029-qc-direct-parts-1

Then press Enter in PowerShell, allow upload / published-file verification to finish, and refresh with Ctrl+F5. No Edge Function or JWT change is needed. No new permission tick is required: Initial QC uses Entry, Lab uses Entry, and Parts uses its existing Issue / Return permissions. Live installation and publication remain pending until that publisher succeeds.

Validation uses disposable PostgreSQL and mocked-browser fixtures: atomic publication, safe owner-run backfill, duplicate rejection, unassigned phones, services separation, additional orders before first issue, stale/old-list denial, returns and partial replacement limits, preserved prices, return rejection, account permissions, replay, all 75 earlier verification components, and actual QC/Lab controls in light and mobile dark modes. No live stock is issued by tests.
