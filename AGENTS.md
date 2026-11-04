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
