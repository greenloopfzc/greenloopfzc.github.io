# Supplier Stock Progress

Release: 20261030-supplier-progress-1

Reports > Supplier Progress has linked Supplier and Stock / Batch selectors in Filters. A batch option also shows its invoice. Search, model filters, sortable headings and filtered totals remain. Supplier/customer names use the existing confidential-name permission; supplier codes remain visible. Reports View permits reading the report/returned details; Search permission controls both selectors and other filters.

The report counts physical phones once per receipt and separates models AND storage sizes. A quantity-only receipt is not added as a second model plan. A full 100-phone receipt with 59 + 41 entered phones therefore shows 100 stock quantity, 100 entered, 2 returned, 98 active workflow and zero entry pending. The Returned phones card opens IMEI, model, storage, color, original batch/invoice, return time/reference and reason. Requested/approved returns are Return pending, never completed returns or ordinary department work.

Only a genuine unentered receipt balance produces an Unentered stock row. For example, 3 entered out of 10 produces 3 model units plus 7 unentered units, totaling 10. Returns before IMEI Entry remain receipt-level units; optional scanned IMEIs do not imply entered phones. Receipt returns and reserved requests reduce that entry balance. They are not invented as model allocations. If stored records exceed their original receipt quantity, the report shows a review notice instead of hiding the discrepancy.

The date range selects original receipt dates using UAE boundaries. Returned details include completed returns against those receipts even if the return happened later. Current return membership excludes archived/deleted entries. Existing legacy returned status remains visible with an explicit missing-metadata note when no return record exists. Rework jobs cannot count one physical phone twice in a receipt.

Migration 224 adds a read-only authenticated Reports RPC, its protected office wrapper and an integrity version marker. It does not alter receipts, jobs, phones, return records, permissions or existing workflow functions. Earlier integrity markers remain valid. No Edge Function or JWT changes are needed.

Run Publish-GreenLoop-Supplier-Progress.ps1. The cumulative publisher checks previous installations and requests this SQL only when its marker is missing. Run the entire clipboard SQL in a NEW query, and confirm installed_supplier_progress_version = 20261030-supplier-progress-1. Database failures or changed definitions stop publishing. Final success requires all published assets to match the tested source.

Validation uses a disposable PostgreSQL database and browser fixtures; no live business records were changed by these tests.
