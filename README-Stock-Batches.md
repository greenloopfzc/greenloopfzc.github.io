# Receiving batch identity across stock reports

Version: 20261027-stock-batches-1

Stock Received already creates a unique BATCH-year-sequence reference and an invoice for every receipt. The existing batch IDs, displayed numbers, IMEI links and stock quantities are preserved. There is no new manual batch field and no renumbering of historical records.

Stock Received now explains automatic generation and shows the saved Batch No. IMEI Entry shows Batch No and invoice in receipt choices and receipt details, so two equal-quantity receipts from the same supplier can be selected reliably. Native intake continues linking each phone to the selected receiving_batch_id.

Parts Ordered and every Parts Returned category show Supplier Code and Stock/Batch No on the phone line. Parts detail includes batch, invoice and stock-received time. New read endpoints support batch search, filters and sorting before pagination; legacy returns use their original job link.

IMEI Search shows batch, invoice and receiving date in phone details. Recorded receipt milestones show Batch No in the compact Stock Journey. The Stock Journey table and Accounts Supplier/Customer Stock tables have a separate batch column and batch filters/sorting. The original supplier/customer name permissions remain in force. Missing legacy batch links show no invented batch.

Validation: disposable PostgreSQL baseline and additive migrations through 206, native repeated 100-unit receipts for one supplier, unique existing batch/invoice sequences, native IMEI intake links, report totals, batch search/filter/sort, legacy/new returns, missing batch, old privacy/capability/TV/Office guards, replay and earlier version receipts. Browser checks cover receipt save, IMEI receipt selection, IMEI history, Stock Journey, Accounts stock reports and Parts issue/return paths.

Run outputs/Publish-GreenLoop-Stock-Batches.ps1 from the chat workspace. The publisher selects the required SQL, verifies the installed version, safely publishes the pinned source and compares published files. Required final SQL result: installed_stock_batch_links_version = 20261027-stock-batches-1. No Edge Function or JWT setting change is needed.
