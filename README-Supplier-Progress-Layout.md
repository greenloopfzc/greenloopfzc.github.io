# Supplier Progress: visible stock selection and optional dates

Reports > Supplier Progress now opens with a visible, aligned Supplier / Stock-Batch / Invoice selector row. Supplier selection limits both receipt selectors. Choosing a batch selects its invoice and choosing an invoice selects its matching batch. Invoice labels include the batch number to distinguish repeated invoice numbers. Receipts without an invoice remain selectable by batch. Supplier names still follow the existing confidential-name permission.

The first load covers all receipt history through the existing get_supplier_progress_v2 RPC. Its required date parameters use explicit wide calendar bounds instead of the shared monthly report range; no migration is needed. Selecting stock resets date/model/search refinements so the full selected stock is shown. Model search, column sorting, returned-phone detail and filtered totals retain their existing behavior.

Date Range appears below the stock totals as an optional disclosure. Its From/To fields filter by stock received date in UAE time, matching the existing RPC's meaning. Apply changes the rows, totals and returned details together. All dates restores full selected stock from the all-history read. An empty range result does not reset the chosen supplier, batch or invoice. Failed reads show Unavailable, rather than zero counts; All dates remains available after a range failure. Request revisions discard superseded date responses.

Supplier Progress uses its own date state and read lifecycle. Other Reports tabs retain their existing date controls and queries. The shared clean-layout script no longer adopts these selectors because the shared report-date form is hidden for Supplier Progress. The selection row has responsive light/dark styling and retains the raised design.

Search/date controls require Reports Search permission. View-only accounts may still read their report, open returned-phone details and refresh it. No workflow, supplier, stock, IMEI, return, price or permission data is written by this change.

Run outputs/Publish-GreenLoop-Supplier-Progress-Layout.ps1 to publish the cumulative update. No new SQL, Edge Function, JWT, secret or permission tick is required. Existing prerequisite installers/checkers remain unchanged. After LIVE - VERIFIED, press Ctrl+F5 on Reports.

Local browser fixtures verify default visible selectors, historical receipts, linked selectors, optional dates/totals, zero results, stale reads, failed-range recovery, other report dates, permissions/privacy, returned details and mobile light/dark layouts. Package TEST-SUMMARY lists the final checks. Local verification does not claim a live publication or change business records.
