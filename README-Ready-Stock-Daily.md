# Ready Stock daily activity and appearance

Prepared 11 November 2026. This package requires an additive, read-only
database installation. No live records are changed during preparation.

Ready Stock has two raised, clickable cards: **Daily Ready Stock** and
**Daily Export**. Both use the selected UAE calendar date, from **10:00 AM
through exactly 9:00 PM**. The default date comes from the server. Nothing
after 9:00 PM or before 10:00 AM contributes to that date's activity cards.

Daily Ready Stock counts distinct phones recorded entering the actual Ready
Stock location. Initial QC direct releases, Final QC and B-DEPT arrivals use
their recorded location movements. A Final QC Pass routed into B-DEPT is not
a Ready Stock arrival. An IMEI counts once per day even if it returns after
rework. Exporting it later does not subtract its earlier daily arrival.

Daily Export counts distinct phones in Accounts-verified exported boxes, at
their verification time, plus completed recorded stock dispatches. Scanning a
draft box or submitting it to Accounts does not count as export. Original
historical movements and confirmations are used; no missing time is invented.

Each card opens a read-only phone list with S.No, IMEI, Model, GB, Grade,
Color, supplier code with original receipt quantity, batch with original
receipt quantity, and the recorded UAE time. Export details include the box.
The list fetches only 50 phones per page with Previous/Next and a visible range.
Historical date selection uses the existing Ready Stock Search & Date Filters
permission. View-only accounts can open today's cards without entry access.
Supplier names retain the existing name-view permission. No customer names or
additional business actions are exposed by these lists.

The current physical-stock table and six grade cards remain independent from
daily activity. Raised panels, centered card values, compact controls, subtle
green/blue accents and theme-aware surfaces refresh the Ready Stock design.
Mobile detail records wrap inside the dialog. Date controls stay behind a
button. Existing rework, stock quantity drill-down, printing and QC work-tray
layouts retain their existing behavior.

## Install

Run `outputs/Publish-GreenLoop-Ready-Stock-Daily.ps1`. Earlier updates,
including QC Fast Work Trays, are checked first. If SQL is missing, paste the
clipboard directly into a **new Supabase SQL Editor query** and Run it.
Require this final result before pressing Enter in PowerShell:

`installed_ready_stock_daily_activity_version = 20261111-ready-stock-daily-1`

The publisher verifies the installation, uploads without a force push and
compares the published files. After **LIVE - VERIFIED**, press Ctrl+F5 and
open Ready Stock. No Edge deployment, JWT setting, encryption secret, new
permission tick or Cable Reader restart is needed.

## Isolated verification

`work/test-ready-daily-db.cjs`: original business rows/routines/access preserved
on LF/CRLF install and reinstall; UAE boundaries; repeated arrivals; draft and
pending-box exclusions; verified export times; arrivals retained after export;
Final QC-to-B-DEPT exclusion; exact receipt data and grades; 50-row pagination;
date/name permissions; Office Only/private/anonymous boundaries and tamper check.

`work/check-ready-daily-browser.cjs`: real Chromium and actual page runtimes,
using local fixtures. Light/dark/Ruby/mobile visuals, card drill-down, original
quantity labels, leftmost serials, paging, view-only access, hidden names,
read-error recovery, malformed responses, changing dates during a read and
Office lock are checked. Screenshots are fixture previews, not live stock data.
