# Accounts Supplier / Customer Stock filters and totals

Customer Stock now reads the canonical receipt/batch for each exported box line. Distinct receipts remain distinct even when supplier, invoice, model, GB and colour match. Supplier Stock keeps its existing stock calculations and uses canonical batch identity and original receipt quantity.

Both views have Supplier Name (authorised accounts), Supplier Code, Stock/Batch No, Invoice, Model, GB and Color filters. Customer Stock also has Customer Name (authorised accounts), Customer Code and Grade. Names are filtered/sorted only with existing partner-name permission. Code/quantity and batch/quantity labels remain visible to allowed viewers. Option values and saved identifiers stay canonical.

Both tables have a green Total footer covering all matching records, independent of the current fifty-row page. Customer totals show exported phone quantity; supplier totals show Received, In company, Ready, In process, Exported and Returned. The receipt/returned/replacement/balance summary is calculated server-side for the complete matched receipt scope. S.No appears once, on the left. Previous/Next pagination remains fifty records.

The additive read-only get_accounts_stock_report_v2 reader enforces Office Only, Accounts View, Supplier/Customer section access, Search and Sort. Anonymous and direct private access are denied. New data is not fetched/rendered after a grant is revoked, and stale table/name filters are cleared. No stock, IMEIs, export boxes, customer/supplier records or user grants are changed by report reads or installation.

The PowerShell publisher checks prior required installations, copies the Accounts Stock Filters SQL only when its marker is missing and verifies it before publishing. No Edge Function, JWT, secret or new permission tick is required. Final SQL result: installed_accounts_stock_filters_version = 20261109-accounts-stock-filters-1.

Checks: first CRLF/repeat LF installation; unchanged prior routines/business rows/access; real exported workflow fixtures spanning 57 grouped rows and 63 phones; same supplier/invoice with separate 342/100-unit receipts; selected/whole totals on both fifty-row pages; dependent facets; sorting; zero-match and permission boundaries; name redaction; Office Only; anonymous/private denial; actual page dropdowns/footer/pagination/read failure/revocation; native Chrome appearance. No live SQL, deployment or real business data mutation was performed during development.
