# Accounts IMEI DATA: simplified stock report

Accounts > IMEI DATA now uses six columns, in the same order on screen, PDF and Excel:

IMEI | Model | GB | Color | Supplier | Date Received

Grades, battery health, current stage and technician columns are removed from this report. Received dates use the UAE calendar date. Supplier code and receipt quantity remain visible; supplier names still require the existing confidential-name permission. Completed supplier returns retain their original stock and red row marking, with pending returns separately marked. No stock, receiving, QC, technician or history records are changed.

The existing supplier, stock/batch and invoice selectors, optional filters, heading sorting, pagination and all-record exports are preserved. No new SQL, Edge deployment, secret, JWT change or permission tick is required. The publisher verifies existing installations and preserves newer remote changes.

Validation: 17 real-browser scenarios, three generated PDF files, three generated Excel files, 120-record export completeness, portrait PDF render inspection, text IMEI cells, supplier-name masking, return colors, view/download permissions, Office Only clearing and unchanged source mirrors.
