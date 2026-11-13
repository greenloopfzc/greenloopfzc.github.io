# Mint headers, model summaries and Accounts loading

CHAMAN SHOP summary headers in Accounts/IMEI DATA and both Chaman workspace homes use #C1E2D2 sampled from the supplied Accounts navigation reference. Dark text remains readable. The eight company stock cards have a separate Greenloop Stock Data heading beneath the Chaman matrix. Stock values, movement formulas, receiving and access stay unchanged.

Ready Stock: open any card, then choose Model Summary beside Show Color. Each model has one total across its GB, grade, color and batch variants. Select a model for its GB x Grade matrix; select a nonzero quantity for exact IMEI rows,50 per page. Detailed View restores the existing color preference. Model totals and cell totals cover the complete originating card/date scope, with a shared snapshot to reject changed stock. Supplier names remain protected. Dates have no time; no device-number column.

SQL308 adds private scoped model readers and a bounded public read API. SQL309 keeps a private lean inventory source for Accounts aggregation, retaining complete exchange-chain histories and restoring full metadata only for returned pages or explicit downloads. Original general readers remain available. Privacy checks and parent joins are calculated once. The report and supplier/batch choices begin independently on first IMEI open, with existing stale-response/office/access protections.

Measured local PGlite workload:2500 phones,2501 scoped units with fixture stock. Summary4768ms ->2069ms; first detail page5234ms ->1818ms. Full counts, facets and visible business rows match. Actual live latency depends on server/data. No database timeout or role setting increased.

Run the supplied PowerShell publisher. It checks prerequisite versions and copies any required installer for you to run in Supabase SQL Editor. Run the complete SQL, wait for its version result and return to PowerShell. Codex has not run live SQL or published. Ctrl+F5 after publishing.
