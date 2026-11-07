# Stock Parts Cost phone count

Recorded net parts cost now states how many distinct phones have priced net parts in that amount. This appears in the summary, each stock/phone cost cell and the filtered footer. Counts follow the current stock/supplier/invoice/date/search scope and stay separate per currency.

Multiple parts on one IMEI count once. A recorded zero price counts as priced. Fully restocked parts and phones with only pending prices do not contribute to the count. Partially priced phones count once, with the existing incomplete-price warning retained. Entered phones remain separate.

Run outputs/Publish-GreenLoop-Stock-Cost-Phone-Count.ps1. When SQL is copied, paste it directly into a NEW Supabase query and RUN all SQL. Required result: installed_stock_cost_phone_count_version = 20261107-stock-cost-phone-count-1. Then press Enter in PowerShell and wait for LIVE - VERIFIED. No Edge Function, JWT, secret or new permission tick is needed.

The SQL changes one reviewed read-only totals helper and its exact installation hash. It does not change stock, issued quantities, prices, returns, assignments, permissions or cost formulas. Existing permission, office and stock integrity checks must still pass.
