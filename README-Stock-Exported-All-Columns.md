# Stock Exported full-column PDF / print

Stock Exported > open a box > Print Box shows a professional branded source-detail report, with every screenshot column:

S.No, IMEI, Device, Model, GB, Grade, Color, Supplier, Supplier Code, Stock received (UAE), Invoice, Stock/Batch No.

The report uses one A4 Portrait page for a standard full box of 50 phones. Measured widths, row heights, font fitting and 22-point margins keep complete cells inside the page. There is no screen table clipping, hidden column, ellipsis or omitted phone. The preview, downloaded PDF and isolated browser print use the same drawing operations. Very long custom data which cannot fit one readable page produces an error instead of silently clipping or omitting details.

The report preserves the actual on-screen grade values, including BA and BB. Box Entry remains its separate A4 Portrait packing sheet, with its earlier BA -> A and BB -> B print labels. Supplier/customer names remain subject to the existing names permission. Supplier and batch codes keep their exact original receipt quantity labels; canonical receipt metadata supplies these labels without changing records.

Existing Stock Exported View and Print ticks authorize preview, download and printing, including permitted view-only accounts. Every print reloads the complete selected box, independent of on-screen filters. Permission loss, office lock, sign-out and Close remove its preview. This read-only frontend change adds no SQL, Edge Function, JWT setting, secret or permission tick. Earlier required installation checks remain in the publisher.

Validation: 46/50 phones with all twelve fields on one A4 Portrait page; every PDF text/cell checked against margins; independent text extraction including invoice, supplier/batch labels and the last IMEI; protected names; native Chrome PDF download and isolated browser print; permission denial/revocation; mobile and Close. Box Entry's portrait preview/print/grade labels and Accounts' printing acknowledgement remain unchanged. No live stock or deployment was changed during preparation.
