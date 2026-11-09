# Ready Stock and box packing grades

Ready Stock shows separate, centered A, B, D, BA, BB and RMA counts, including zero counts. Model, grade, search and date filters update these counts using the same stock rows as the table. A nonzero count opens its canonical grade's read-only IMEI list using the existing 50-record paging. Other saved grades remain available in the stock table.

Box Entry PDF, vector preview and printed packing sheets display BA as A and BB as B. A, B, D and RMA retain their labels. This mapping does not alter stored grades, the Box Entry screen, Ready Stock records, stock quantities, pricing or workflow actions.

No new SQL, Edge deployment, JWT setting, secret or permission tick is needed for this change. The publisher retains earlier installation checks and stops safely if newer GitHub changes need combining. After LIVE - VERIFIED, refresh with Ctrl+F5.

Validation: native Chrome Ready Stock with six grade counts, custom grade preservation, model/date filters, canonical BA drilldown, mobile/dark appearance and rework navigation; PDF grade mapping with immutable input, matching preview, printable red issues and 50 valid phones on one A4 portrait page. Print branding, Quality Control Team footer and earlier IMEI Entry 50-line update remain preserved.
