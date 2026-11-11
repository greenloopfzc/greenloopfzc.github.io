# Ready Stock card summaries and exact-group IMEI lists

Prepared 11 November 2026. Every Ready Stock card first opens a summary:
S.No, Model, GB, Color, Grade, Stock / Batch, Supplier, Qty. The total footer
covers the complete selected stock, not just the current 50-group page.
Select a Model to view only that exact Model/GB/Color/Grade/receipt/supplier
combination. Back to summary restores the previous group page. Both summary
and phone lists request at most 50 records; no hidden all-page loading.

Total / grade cards use current physical Ready Stock and the existing active
model/grade/date selection. Daily Ready / Export use the selected UAE day and
existing 10 AM-9 PM real arrivals / confirmed export rules. All grade and daily
averages, including Sunday exclusion, are preserved. Existing table quantity
links keep their direct IMEI behavior. Names on all cards are larger and bold.

Batch and supplier codes show the original receipt quantity. Separate batches
never merge. Supplier names require existing name-view permission; every allowed
viewer retains receipt code/quantity visibility. No customer names are exposed.
Read-only additive SQL; private helpers/Office/role/TV/view/search guards remain.
No new permission tick, Edge deployment, JWT, secret or reader restart.

Run outputs/Publish-GreenLoop-Ready-Stock-Groups.ps1. Paste requested SQL into a
NEW Supabase query and RUN. Required final result:
installed_ready_stock_groups_version = 20261111-ready-stock-groups-1
Then Enter in PowerShell. After LIVE - VERIFIED: Ctrl+F5 > Ready Stock.
