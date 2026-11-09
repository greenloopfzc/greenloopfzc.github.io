# Stock Receipt Correction — Reports only

Open Reports > Stock Receipt Correction. Select Supplier, then Stock / Batch / Invoice. Search also accepts a batch or invoice number. The receipt picker and permanent correction history use 50-record Previous / Next pages.

The receipt shows received quantity, entered IMEIs, completed returns, received replacements, stock balance and unentered balance. Enter the correct total received quantity and a reason; choose Save quantity correction. This corrects an intake typing/recount error. It does not record a supplier return.

For example, a quantity-only receipt entered as 1500 with 1200 linked IMEIs can be corrected to 1200. Its unentered balance becomes zero. Canonical supplier and batch quantity labels read (1200); the old 1500 value, new value, reason, account and UAE timestamp remain in permanent correction history. Phones and their jobs, grades, parts, services, returns, replacements and box records are not modified.

Server checks lock the receipt, reject stale snapshots and prevent reducing quantity below linked active phone jobs, reserved returns or saved model plans. Existing replacement receipts retain their recorded replacement quantity. A retry with the same save reference confirms the same correction instead of creating another audit entry. Existing Supplier Return protections remain active; a narrow same-transaction audit authorizes only this receipt quantity change.

User Access > Reports has separate Stock Receipt Correction View and Correct received stock quantity ticks. Save requires Reports Edit and the explicit correction tick. Ordinary users receive no new report access automatically. Existing full correction owners retain access. Supplier names still require their existing permission; receipt codes and exact quantity labels remain visible to permitted report viewers.

The publisher copies additive SQL for Supabase SQL Editor. Run the entire query in a NEW query and check:

`installed_stock_receipt_correction_version = 20261109-stock-receipt-correction-1`

No Edge Function deployment, JWT setting or encryption secret change is required. After LIVE - VERIFIED, press Ctrl+F5 and open the new report. Installation does not automatically change any receipt quantity.

Verified in an isolated database and native Chrome: 1500 -> 1200 with 1200 linked phones; unchanged workflow rows; entered/pending balance and intake selector; return/replacement preservation; model plan and reserved return floors; stale and invalid input; idempotent retry; immutable history; office, anonymous, report-specific and view-only permissions; protected names; 50-row paging; rollback/reinstallation; previous installation markers; responsive report and matching supplier/batch labels. Live business data was not changed during preparation.
