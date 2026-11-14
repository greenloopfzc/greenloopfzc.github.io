IMEI Search QC details, Reports corrections and shared Transfer Desk

IMEI Search shows Initial BH, Final BH, Supplier Grade, GL Grade and Final Grade as separate saved values. Missing final data is Not recorded; an explicit battery-unavailable choice is Not available. Final QC/B-DEPT or a real recorded Direct Ready release supplies final values for the current job. Initial values never silently fill missing final ones. Stock received dates are date only.

SQL310 extends the existing protected IMEI activity reader. Reports audit records supply exact old/new changes with date, actor and reason in light-red correction rows. Full-workflow audit and its general wrapper are shown once, not duplicated. Pages are bounded at50 with a snapshot guard. Immutable business/audit records are not changed. Supplier/customer names and price fields retain independent visibility; correction history is read through IMEI Search view, not a Reports write grant. Audit events in Full activity also receive the red treatment.

Both Chaman home workspaces now show the same directional six-counter matrix used in Accounts: Greenloop to Chaman (transferred, received, pending), then Chaman to Greenloop (returned, GL received, pending). The centered mint title is Greenloop & Chaman Transfer Desk everywhere. Pending quantities still open their exact server-filtered report; recent five documents and the role-specific entry/receiving cards remain.

Run the supplied PowerShell publisher. If it copies Install-IMEI-QC-Corrections.sql, run the entire SQL in Supabase SQL Editor and wait for20261114-imei-qc-corrections-1, then press Enter in PowerShell. The publisher verifies prerequisites/source/package and live assets. No live SQL or publish has been performed by Codex. Ctrl+F5 after publishing.
