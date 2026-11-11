# Initial QC / Final QC fast work trays

Prepared 11 November 2026. Install with the supplied PowerShell publisher;
this source package has not itself been applied to the production database.

- A completed 15-digit scan starts immediately. One combined response contains
  the confirmed phone, exact original receipt quantity, platform and QC data.
- Final QC receives the phone through the existing guarded receive action and
  returns fresh Battery Health defaults and Fail return-technician context.
  Diagnostic Battery uses Final BH 100; Initial BH remains historical.
- Explicit Excel paste and Auto Pick prepare up to 100 phones per request,
  preserving every tray line. Regular report tables remain 50 per page.
- Manual bulk Save uses at most three concurrent normal save requests. Each
  phone retains its individual result, validation, routing and error. No
  automatic Pass/Fail or automatic retry of failed writes is introduced.
- Initial QC confirms a successful Save before its debounced pending-count
  refresh. Saved rows leave the local pending count immediately. Final QC does
  not preload every phone's battery/context just to show the pending summary.
- Compact rows, S.No, grades, first-row carry, individual Fail, Direct Ready
  Stock, inspection/issuance separation, supplier-name access and Office Only
  remain in place. Previous Box Fast Scan and replacement fixes are included.

## Installation

Run `outputs/Publish-GreenLoop-QC-Fast-Work-Trays.ps1` in PowerShell. It checks
the pinned source, required previous database installations and current GitHub
history. If the additive QC Fast SQL is missing, it copies the complete query.
Paste directly into a **new Supabase SQL Editor query**, Run, and require:

`installed_qc_fast_work_trays_version = 20261111-qc-fast-work-trays-1`

Return to PowerShell and press Enter only after that result. The script checks
the installed functions and publishes without force pushing, then compares the
live website files. No new Edge deployment, JWT setting, secret, reader restart
or permission tick is required. After LIVE - VERIFIED use Ctrl+F5 on both QC
pages. Network and database response time still affect actual speed.

## Isolated validation

`work/test-qc-fast-db.cjs` checks PostgreSQL installation/reinstallation, old
routine/business-record preservation, primary/secondary identities, wrong-stage
and mixed lists, receipt labels/privacy, Diagnostic100 versus Initial78,
Android unavailable BH, actual Pass/Fail, Office Only and private/anonymous ACLs.

`work/check-qc-fast-browser.cjs` runs actual Chromium with local fixtures and
real page/permission/scanner/paste scripts. It checks one request per scan,
105 phones in two requests, Auto Pick, compact rows, leftmost S.No, stale and
malformed replies, duplicate/secondary errors and three bounded manual saves.
These are controlled tests, not a production latency guarantee.
