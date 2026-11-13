# Greenloop project policy

## Supplier code and receipt quantity

Persistent user requirement recorded on 5 November 2026 (Asia/Dubai):

- Wherever the software displays a supplier reference, display the supplier
  code together with that stock/receipt's original quantity in brackets, for
  example `SUP-06-(342)`. Apply this consistently to operational pages, tables,
  reports, detail views, PDF/print output and spreadsheet exports.
- Codes and bracketed quantities are visible to everyone who can view the
  relevant page. Supplier/customer names still require the existing authorized
  name-view permission. An authorized label may read `SUP-06-(342) J&K`.
- Resolve the quantity against the actual receipt/stock/batch. Do not use a
  model subgroup quantity or combine a supplier's separate deliveries.
- Show returned quantities, received replacements and remaining balances
  separately; do not silently change the original receipt quantity in the code.
- Use canonical stock data. Do not invent a quantity when it is unavailable.

These are business display requirements, not permission to disclose protected
names or to delete, reset, or otherwise change business records.

- Supplier/company identity selectors (especially Create stock entry) show only the base supplier code and permitted company name. Quantity brackets are added only when a specific receipt or newly entered receipt quantity is known; never combine separate receipts in a company label.

## Batch number and original receipt quantity

- Every displayed batch number also shows that exact receipt's original quantity, for example `BATCH-2026-0001-(100)`, on pages, filters/selectors, details, print/PDF and spreadsheet exports.
- Batch quantity is visible to every allowed viewer; supplier/customer names retain their existing permissions.
- This is a display label. Keep canonical batch numbers, IDs, option values, search/filter arguments and saved records unchanged.
- Use the original receipt quantity; show returned, replacement and balance quantities separately. Never use a model subgroup count, combine deliveries or invent an unavailable quantity.

## Report pagination

- Keep regular report/data tables paginated at 50 records per page, with Previous/Next and visible ranges. Do not automatically fetch or render all matching pages.
- Keep complete PDF/Excel/CSV downloads independent from on-screen pagination.
- Explicit bulk entry/paste/scanner trays retain their full pasted/selected lines and existing manual Save/Transfer behavior; do not reintroduce Parts issue-selection caps.

## Issuance inline editing

- Lab & Glass Issuance edits stay in the same IMEI row, in Parts Needed and Service Needed, with Initial QC style dropdowns and plus/minus controls. Do not open a separate editor panel.
- Do not show a quantity input. Each newly selected part has one unit for that IMEI. A layout update must not reset existing saved quantities or business records.
- Save / Cancel stay on the same row. Saving changes and transferring the phone remain separate actions.

## Copying and screenshot choices

- User Access provides independent Allow Copying and Allow Screenshots choices beside the Supplier & Customer Names options. These are virtual preferences and grant no page visibility, entry, download or other business action.
- Owner and Super Admin accounts default to both allowed until explicitly configured; other accounts remain restricted until granted. Preserve choices in atomic user creation, access saves and TV-only settings.
- Every allowed viewer can select/copy visible IMEI and batch-number values, including the batch receipt quantity label, without a content-protection alert. This exception must not include the surrounding row, supplier/customer names or other protected text.
- Allowed copy/capture actions do not create Suspicious Activity alerts. Browser-observed restricted attempts retain the existing bounded, self-attributed alert behavior. Screenshot completion/prevention by operating-system tools is not observable or guaranteed by a website.
- Saved or disabled identifier fields stay locked. Expose their value for selection/copy without enabling an entry control or changing its value.

## Compact work trays and serial numbers

- Initial QC, Lab & Glass Issuance, Final QC and B-DEPT use compact desktop rows with small controls and content-aware column widths. Generic report layout changes must not expand these work trays into desktop cards. Retain the raised design, same-row editing and all workflow behavior.
- S.No is always the leftmost column in tables, PDF/print and spreadsheet exports. Keep the matching values, widths, totals and formulas aligned; never add a duplicate serial column.
- Stock Journey is removed from sidebar navigation. IMEI Search history and existing stock records remain available.

## Glass part naming in grading reports

- User requirement (12 November 2026): `Glass`, `Glass (Glass Damage)` and `Glass (Damaged Glass)` mean the same required part. Include both under Glass in Stock Grade & Work Analysis counts, percentages and PDF output. Count each phone once even if both aliases occur. Preserve unrelated parts such as Back Glass and preserve stored historical part names.

## Chaman Shop transfers

- Chaman Shop has no sales/customer-account process. Every allowed non-shop login uses Greenloop Section: Transfer Stock Entry / Returned Stock Entry / Reports. The explicit Chaman Shop login uses Chaman Shop Section: Received Stock Entry / Returned Stock Entry / Reports. Reports opens three nested cards: Greenloop = Transferred Stock Data / Received Stock Data / Stock Balance Data; Chaman = Received Stock Data / Returned Stock Data / Stock Balance Data. Owner / Super Admin may switch sections; each shows only its three main cards. Other users gain no automatic page access. User Access has one special flag, This is the Chaman Shop login; other allowed IDs use Greenloop by default. Server enforces each side's writes.
- Entry pages use compact phone rows with scan-to-next-line and unrestricted explicit bulk paste. IMEI loads model/GB/color/grade, original supplier/batch quantity and stage at dispatch. Scanning/preview never changes stock: only Save / Confirm does. Receiving may contain IMEIs from multiple deliveries; match each exact pending document atomically. Returned phones restore their original saved workflow stage. Reports use whole red rows for pending and whole green rows for receiving confirmed, with date-wise documents, partial receipt counts and complete PDF/Excel independent of 50-row UI pages.
- Original received stock never disappears or shrinks when Chaman is dispatched. Example: received500, sent100, Greenloop return received50 => original received500, company450, Chaman50 (when no other movements). Supplier Stock, IMEI DATA and Supplier Progress show Chaman sent/returned/pending/physical quantities separately. IMEI Search keeps an append-only dispatch/receipt/return/correction journal and current custody; keep earlier trips after subsequent work or corrections. No sales process or device-number columns.
- Reports has an Admin-only Chaman Transfer Correction card for date/notes, receiving undo, selected phone removal and transfer deletion. Require a reason, reviewed snapshot and idempotent request. Keep before/after audit and deleted IMEI/model/batch details. Reversals must adjust custody/stock atomically, preserve original receipt quantities, and reject dependent/later trips or changed workflows. No hard deletion of phone/jobs or transfer audit.
- Confirmed dispatch immediately removes the reviewed phones from Greenloop available stock. Chaman receipt is separately confirmed by IMEI. Chaman return dispatch never adds to Greenloop stock; only Greenloop confirmed receiving adds the scanned units back. Partial receiving and separate pending-transit counts are required. Chaman Balance is physically received stock minus return dispatches.
- Preserve original phone/job, supplier, receipt quantity and batch. Each delivery/return has its own date/reference/IMEI history. Never count the same phone in both company and shop availability.
