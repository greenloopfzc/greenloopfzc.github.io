# Supplier codes on Parts phone reports

Version: 20261027-parts-supplier-codes-1

Parts Ordered and all Parts Returned sections show Supplier Code next to each IMEI: Awaiting Review, Damaged, Faulty, Not Needed and Other. The single-phone order detail also identifies its supplier code. Legacy returns resolve the code from their original job. Missing suppliers display an em dash; supplier names are never substituted for codes.

Parts users with View permission can see codes without partner-name permission. These Parts endpoints select codes only and do not return supplier/customer name fields; existing name visibility permissions elsewhere are unchanged. Search/filter and sorting still require their existing Parts capabilities. Supplier Code is available in the Filters drawer, live search and column sorting. Filtering is applied before pagination. Pending badges remain global unique IMEI counts.

The issue, return, review and private price workflow remains unchanged. Search highlighting on Parts uses a single table-body observer so matched code text does not cause repeated highlighting.

Install using outputs/Publish-GreenLoop-Parts-Supplier-Codes.ps1 in the chat workspace. The publisher selects the required SQL based on installed versions, verifies the final receipt, safely uploads the pinned source and checks published files. Required final SQL result: installed_parts_supplier_codes_version = 20261027-parts-supplier-codes-1. No Edge Function or JWT setting change is needed.

Validation: disposable PostgreSQL baseline plus Employees and supplier-code migrations, all prior version receipts, replay, ordered/detail/new and legacy returns, five return categories, missing supplier, search/filter/sort/pagination, name flags, View Only/search/sort/issue/Office/TV/private/anonymous guards. Browser checks cover all categories, detail, legacy returns, filter, live search, missing codes, View Only, issue, review and mobile dark mode.
