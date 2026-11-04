# Accounts IMEI DATA

Version: 20261104-accounts-imei-data-1

Accounts has four cards: Verify Box, Supplier Stock, Customer Stock and IMEI DATA.

IMEI DATA provides Supplier, Stock/Batch and Invoice selectors, live search, optional model/GB/color/final grade/stage/received-date filters, heading sorting and 50-record screen pages. It shows one physical phone per receipt even when multiple jobs exist. Initial and Final BH are separate. Supplier codes include original receipt quantity; supplier names require existing confidential-name permission. IMEI2 and serial number remain backend-only.

Completed supplier returns stay attached to their original receipt and appear in red, with available return number/date/reason/reference. Pending returns remain separate. A returned unentered unit with no recorded IMEI is explicitly marked; no IMEI is invented. Deleted operational records remain excluded.

PDF View, Download PDF and Download Excel include every matching record across all table pages. Portrait A4 PDF repeats headers and has no fixed page cap. Excel uses real .xlsx files and text IMEI cells. A changed report snapshot blocks stale exports until Refresh.

User Access > Accounts has separate View IMEI DATA and IMEI DATA: PDF View / Download and Excel ticks. Search/date filters and heading sorting use existing Accounts search/sort permissions. Existing grants are preserved; protected Owner/Super Admin accounts with Accounts view receive the new read permissions. Other users must be granted these ticks. Office Only restrictions apply on every API.

Installation: run the prepared Publish-GreenLoop-Accounts-IMEI-Data.ps1. Its existing prerequisite checks run first, then it copies only this new SQL when the new marker is missing. Paste the clipboard into a NEW Supabase SQL query and run it. Required result: installed_accounts_imei_data_version = 20261104-accounts-imei-data-1. Return to PowerShell and press Enter. No new Edge deployment, JWT or secret change is required. HTTP errors or an altered version stop installation; they never trigger speculative repair.

This package is prepared locally. The user runs PowerShell to install/publish. Existing workflow, stock and history records are not modified by the new report.
