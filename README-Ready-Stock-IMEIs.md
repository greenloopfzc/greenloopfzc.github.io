# Ready Stock clickable quantities

Version: 20261028-ready-stock-imeis-1

Positive grade quantities, each model row total, the grade totals and grand totals open a read-only IMEI dialog. The list shows IMEI 1, model, storage, color, final grade, supplier code, stock/batch number and Final QC pass time. Zero quantities remain plain text. The existing raised style is retained, with responsive scrolling inside the dialog.

Each click captures the exact visible model/grade groups and the applied Final QC date range. Row/grade/grand totals therefore include the same local model, grade and text filtering as the summary. Dates entered but not applied do not alter the clicked scope. The server uses the existing native Ready Stock eligibility and pass-date selection; phones moved from Ready Stock are excluded on the next read. If current totals differ from the opened summary, the dialog states that stock changed and offers Refresh list. Lists use 50-row pagination and have no four-page-style display cutoff.

Ready Stock View permission permits opening records and pagination, including View Only users. Applying date scopes also requires Search permission. Phone-history links appear only with IMEI Search View and Search access; the list itself does not require access to another page. Office Only, TV, staff/role checks and revocation remain enforced server-side. Supplier/customer names, IMEI 2 and private costs are absent from this endpoint. There are no stock mutations, quantity edits or operational actions in the dialog.

The additive SQL adds a read API and a Final QC pass lookup index. Existing stock records, statuses, counts, date behavior, rework and permissions are preserved. Validation compares native summary and detail totals across model/GB/grade/RMA, UAE midnight boundaries, repeated groups, pagination, state changes, replay, role/capability/Office/TV boundaries and previous version receipts. Browser checks cover filtered and dated scopes, all quantity types, paging, View Only, stale requests, errors, stock changes, mobile/dark, Office lock and rework navigation.

Run outputs/Publish-GreenLoop-Ready-Stock-IMEIs.ps1. Install the copied SQL in a new Supabase query and require installed_ready_stock_imeis_version = 20261028-ready-stock-imeis-1 before pressing Enter. The script verifies the database before publishing pinned code and checking live assets. No Edge Function or JWT change is needed.
