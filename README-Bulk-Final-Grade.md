# Bulk IMEI Correction: Final Grade / Ready Stock

Prepared 10 November 2026.

Reports > IMEI Data Correction > Bulk IMEI Correction now separates GL Grade
(the Initial QC inspection grade) from Final Grade / Ready Stock. Changing the
latter updates the canonical latest passed Final QC or Direct Ready Stock
outcome. Ready Stock grade summaries and drill-downs read that same outcome.
Total stock, Initial GL Grade, original receipt quantities, parts, prices,
status/location and older QC attempts remain unchanged unless explicitly edited
in their own existing correction cells.

Final Grade is editable only for an unboxed, non-returned phone currently in
Ready Stock with one unambiguous latest passed outcome. Earlier process stages
show a disabled field. Choose an active Final QC grade from the saved grade
catalog; no new grade is invented. Existing box and supplier-return locks stay.
Changes require Review, reason and the existing correction code. A stale phone
or invalid later row rolls back the entire selected save. Existing immutable
bulk correction history records before/after Final Grade and request identity;
retrying the same request replays its original result. No automatic Save.

Installation is additive and changes no phone data. Existing GL Grade changes
are not automatically copied to Final Grade: reopen the intended 18 IMEIs,
choose B in Final Grade / Ready Stock and confirm the reviewed corrections.
Then refresh Ready Stock. Existing Bulk IMEI Correction / Full Workflow
Correction permissions are reused. No new tick, Edge, JWT or secret is needed.

Run Publish-GreenLoop-Bulk-Final-Grade.ps1. It checks existing installations,
copies the new SQL to the clipboard if needed, asks you to run it in a NEW
Supabase SQL Editor query and verifies installed_bulk_final_grade_version =
20261110-bulk-final-grade-1. It performs a normal non-force GitHub push and
verifies published files. Missing earlier approved installations keep their
existing prompts. No local Cable Reader process is changed by this publisher.
After LIVE - VERIFIED use Ctrl+F5 and the new column.

Validation: isolated PostgreSQL install / repeat / CRLF / late rollback,
18-phone A-to-B Ready Stock counts, direct and Final QC outcomes, original
GL and older attempts, atomic failure, retry, stale data, box/return locks,
existing parts/services/batch correction regressions, permissions, office,
private and anonymous boundaries, integrity tamper refusal. UI checks cover
18 reviewed final-only patches, disabled rows, no automatic save, 60-line
pastes, 50-row batch pages, retry and office lock. Chromium desktop and mobile
review / layout inspected. No live stock records changed during preparation.
