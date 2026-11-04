# Initial QC inspection and issuance

Initial QC now saves the inspection before handover. Supplier Grade, GL Grade,
parts and services are saved immediately. No technician or destination is chosen
in this tray. Stock Grade & Work Analysis and Parts Required can include saved
inspection data while the phone remains physically at Initial QC.

The Lab & Glass Issuance card appears before Manage Dropdowns. It opens
`qc-issuance.html` in a separate browser tab/window, preserving the inspection
tray. The page is part of the existing Initial QC page permission. View allows
reading the queue; Entry allows scanning, pasting, assignment and transfer.
There is no additional permission tick or sidebar page.

Scan an IMEI, paste an Excel IMEI column, or load all awaiting inspections.
Each line shows the canonical saved phone details, supplier code with receipt
quantity, stock/batch and invoice, grades, parts and services. Confidential
supplier names still require the existing partner-name permission. Apply one
technician/destination to loaded phones or choose per line. Saved inspection
fields are read-only here; use Reports for audited corrections, then Reload
details. Stale inspections cannot be transferred without reloading.

Lab transfer reuses the same inspection, assigns the technician, creates its
work order, publishes identified parts to Parts Ordered and seeds saved Lab
services. The Lab arrival and technician clock start at transfer. B-DEPT keeps
the existing direct-route restrictions: no parts or services, a non-D GL grade,
and no Lab technician. It uses the existing B-DEPT routing implementation.

The portrait Technician Handover Sheet (Print / PDF View / Download PDF) is on
Issuance and includes successful Lab transfers during that page session. Its
existing English mixed-technician warning and PDF layout are preserved.
Issuance itself is a full page, not a modal. PDF previews remain dialogs.

Both save and transfer accept stable request IDs. Transaction locks, revisions,
Office Only, active-account and Initial QC capability checks are enforced on
the server. Failed operations roll back their changes. Replays do not duplicate
inspections, work orders, parts or timers. Bulk transfer runs per phone, retains
failed lines and reports the successful/failed counts.

The private receipt ledger has no new foreign key into the reviewed operational
deletion graph. Active readers require live jobs, devices and inspections, so
deleted phones cannot appear as awaiting. Ledger receipts remain private and
preserve idempotency/audit context. Installation changes no existing business
records; previously routed phones continue through their existing workflow.

Counts and stage lookups use indexed receipt/phone identifiers without building
every saved inspection. Detailed queue rows are paginated before enrichment.
Parts Required shows pre-issuance rows as Identified. After transfer, those rows
are replaced by normal Parts requests, keeping each requirement counted once.

Migration: `20261104_245_qc_inspection_issuance.sql`.
Required prior: `get_report_section_access_version()` returns
`20261104-report-permissions-1`.
Final marker: `get_qc_issuance_version()` returns
`20261104-qc-inspection-issuance-1`.

No new Edge Function deployment, JWT change, secret or account permission
change is needed. Use the pinned PowerShell publisher for installation and
publication. Local test results do not mean the website is published.
