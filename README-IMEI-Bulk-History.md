# IMEI bulk current stages and history popup

The previous pasted-IMEI list expected current_status, but the legacy suggestion payload supplied status. The new read-only list endpoint returns an explicit current_stage from the same canonical journey-stage helper as single-phone history. It uses the latest live job, distinguishes saved Initial QC awaiting Issuance, respects supplier return status, and does not call a box scan a verified export.

Bulk list requests fetch at most fifty selected rows per page with Previous/Next and visible ranges. They preserve paste order, mark unknown IMEIs and identify IMEI2 aliases without replacing the current-stage text. Supplier codes keep the exact original receipt quantity; protected names remain permission-controlled.

Open history opens a native modal dialog with the full existing history, all audit records and expandable automatic routing details. The underlying pasted list and query remain in place. Close or Escape restores focus/list; closing during a pending read cannot reopen stale history. Loading and read failures stay inside the dialog. Single-phone and receipt searches remain available.

The migration only adds a read-only endpoint, office registration and its explicit Search action rule. It does not change operational records, historical timestamps, existing routine definitions or user permission selections. No new permission tick, Edge deployment, JWT or secret is required.

Validation: first CRLF/repeat LF install and unchanged prior routines/business/access snapshots; eleven stages matching single-phone history; latest live job; IMEI2/not found; fifty-row pages; confidential-name, Search, anonymous/private and office access; actual-page popup/loading/error/close tests; desktop light/dark and mobile native Chrome; earlier single history, rework, export proof and pagination regressions. Publisher rehearsals perform no real deployment.

Version: 20261109-imei-bulk-history-1.
