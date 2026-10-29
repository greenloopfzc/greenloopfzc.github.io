# Technician Parts Report dropdown filters

Parts > Technician Parts Report has six dropdowns: Technician, Model, Color, Part, Pending Qty and Phones. Each has an All option; Clear filters resets the entire selection. Pending Qty and Phones match the displayed grouped row counts exactly, and their options sort numerically. The other dropdowns show required part units, including zero for every technician. Options reflect the other selected filters and keep a currently selected value visible after a refresh, even if it no longer matches any pending row.

Filtering and sorting run locally on one read-only snapshot. Individual phone IDs are used internally to count a phone once across several parts; hidden secondary IMEIs, serial numbers, prices and supplier/customer names are not in that snapshot. Exact IMEI details still use the existing secured line-detail report.

PDF View, PDF download and Excel download fetch a fresh secured snapshot and apply all six dropdown choices and the current sort. Export captions list the active selection. Existing download permission remains required. Bulk Issue selects only visible report lines and retains the existing review, confirmation, permission and transaction checks.

The new SQL adds two read-only report RPCs and a verification marker. Existing business records and permission grants are preserved. Report viewing uses Parts > View page + Technician Parts Report; exporting additionally requires Technician report downloads. Issue permission is separate. Office Only, TV-only, inactive-account and authentication checks continue to apply.

Run outputs/Publish-GreenLoop-Parts-Report-Filters.ps1. The publisher verifies and installs earlier required updates if needed, then copies the report filter SQL. Paste the clipboard directly into a NEW Supabase SQL Editor query and RUN the entire query. The final result must be:

installed_parts_report_filters_version = 20261029-parts-report-filters-1

Then press Enter in PowerShell and allow GitHub upload and published-file verification to finish. Refresh with Ctrl+F5. No Edge Function or JWT setting changes are needed. Live installation/publication remain pending until the publisher succeeds.

Validation: disposable PostgreSQL, browser fixtures with real PDF/XLSX downloads, combined filters, exact unique phone totals, selected-line details/issuing, access denial, refresh selection retention, mobile dark layout and installer rehearsals. No live business data is modified by tests.
