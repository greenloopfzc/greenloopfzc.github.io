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
