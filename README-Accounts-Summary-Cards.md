# Accounts summary-first cards

12 November 2026. Based on 1813e34; retains centered/date-only reports and prior reader/return fixes.

All four Accounts sections start without a detailed table. Verify Box shows a clickable box count. Supplier/Customer Stock and IMEI Data show their filters, summary cards and receipt quantities. Selecting a card or applying filters reveals matching records; Clear filters and switching sections restore the summary view. Refresh keeps the current detail visibility. Selected cards are highlighted and the table states its scope.

The four receipt balance cards open original receipt rows with received, returned, replacement and balance quantities. Operational cards filter stock groups or IMEI rows by their actual category. Screen pages remain capped at 50 records. PDF/Excel use the selected card and filters, include all matches, and reject changed snapshots. Summary-only responses contain no detailed rows.

Required SQL: supabase/migrations/20261112_292_accounts_summary_cards.sql. Adds one read-only RPC and private helper using existing authoritative report/receipt routines; retains the stock/IMEI/download/office permission checks. Existing routines, device IDs, timestamps and business records are unchanged. The migration verifies its own routine hashes, ACLs and registration, and preserves the existing office-version result (the isolated legacy fixture already has an unrelated null office marker after migration 291).

Verified with isolated PGlite: summary responses, all card types, exact receipt quantities, 51-return pagination/full download, 2 replacements, empty selection, stale snapshot rejection, invalid input, denied access, private ACL and repeat installation. Isolated Chrome: four sections, ten IMEI summary cards, every stock card, hidden initial/refresh tables, clear/reset/filter behavior, 50-row paging and complete selected export; no page errors. Screenshots reviewed. No live SQL or publishing performed by Codex.
