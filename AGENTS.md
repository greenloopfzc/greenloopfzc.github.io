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

## Report pagination

- Keep regular report/data tables paginated at 50 records per page, with Previous/Next and visible ranges. Do not automatically fetch or render all matching pages.
- Keep complete PDF/Excel/CSV downloads independent from on-screen pagination.
- Explicit bulk entry/paste/scanner trays retain their full pasted/selected lines and existing manual Save/Transfer behavior; do not reintroduce Parts issue-selection caps.

## Issuance inline editing

- Lab & Glass Issuance edits stay in the same IMEI row, in Parts Needed and Service Needed, with Initial QC style dropdowns and plus/minus controls. Do not open a separate editor panel.
- Do not show a quantity input. Each newly selected part has one unit for that IMEI. A layout update must not reset existing saved quantities or business records.
- Save / Cancel stay on the same row. Saving changes and transferring the phone remain separate actions.
