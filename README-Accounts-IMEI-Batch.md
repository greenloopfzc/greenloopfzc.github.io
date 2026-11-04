# Accounts IMEI DATA: Stock / Batch No.

The Accounts > IMEI DATA table, portrait PDF and Excel exports now include Stock / Batch No. between Supplier and Date Received. All seven columns match: IMEI, Model, GB, Color, Supplier, Stock / Batch No., Date Received. Each row uses the phone's original stock/batch; returned phones retain the same original stock association and return coloring. Batch heading sorting uses the existing authorized server API.

Existing supplier-name permissions, source quantities, selectors, optional filters, text IMEIs and complete matching-record exports are retained. No records, database functions or permission ticks are changed. No new SQL or Edge deployment is required.
