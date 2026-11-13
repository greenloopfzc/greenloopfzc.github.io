# Accounts timeout and responsive section cards

The previous Accounts card reader collected all matching supplier/customer rows by repeatedly calling the complete aggregate for each50-row slice. With many batches and SKU rows this recalculated the same inventory repeatedly and could exceed the database statement limit, leaving summary cards unavailable. The Supplier/Customer reader also used the global Box action lock, temporarily disabling all four section cards while a read was pending.

Migration307 collects filtered stock once through a private complete reader, while public page sizes remain50. Supplier aggregation materializes canonical phone rows once, selects current/original unit representatives without building unused per-phone history arrays, and reuses that source for historical returns. Scoped name-visibility decisions are evaluated once per statement. Filters, facets, ordering, totals, exact unit/replacement links, historical receiving, authorization and snapshot/export semantics remain unchanged. No business data, saved access or server timeout setting is changed.

Accounts section navigation remains available during report reads. Superseded Supplier/Customer and IMEI requests forward AbortSignal through the actual shared capability/office-aware client; late results/errors cannot overwrite the new section. Timeout failures release controls and provide a Refresh recovery message. Writes and exports retain their action locks.

Local regression workload:2500 added phones across10 batches,602 stock SKU rows including the existing fixture stock. Previous summary17.7s vs optimized0.98s on a measured run; live timing depends on server/data. Totals, facets, total rows and snapshots were identical before/after. UI remains50 rows; complete export retains all matching rows. Prior342/41/7/308, missing-IMEI, repeated exchange, pending replacement and Chaman regressions passed.

Install supabase/migrations/20261113_307_accounts_read_speed.sql after Stock Units306. Expected marker:20261113-accounts-read-speed-1. The publisher supplies the SQL and verifies its installation before publishing.
