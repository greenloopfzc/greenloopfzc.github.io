# Restore report pagination

Report/table readers return only the requested server page; the automatic
follow-up-page collector is removed. Previous/Next and original range labels
are visible again. Shared remote report tables request 50 records and do not
collect all following pages, including for pasted report-search lists.
Accounts IMEI DATA, Ready Stock IMEI details, B-DEPT performance, Lab overdue,
Parts queues, stock history, box status and other native pagers resume their
original paging. Dashboard work queue renders 50 lines with Previous/Next.

Entry trays are separate: bulk IMEI paste and continuous scanning, Issuance
sidebar/count, B-DEPT scan tray, existing manual Save actions and uncapped Parts
bulk-issue selection remain. Complete PDF/Excel/CSV export APIs are unchanged.
S.No, Invoice, returned/replacement colors, stock balances, supplier labels and
permissions remain. No new SQL, Edge, JWT, secret or permission tick.
