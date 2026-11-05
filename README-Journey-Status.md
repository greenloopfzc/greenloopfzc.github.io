# Ready Stock and box journey status

The legacy journey readers marked every box scan as shipped and used the scan
time as an export date. A phone could consequently show a Ready Stock badge,
Production as its location and Export in its recorded journey simultaneously.

This release renames the human-readable PRODUCTION location to Ready Stock in
the database, retaining its location ID and all references. Shared display labels
also map the equivalent Production / pending / completed labels to Ready Stock.
Technical enum values, compatibility codes and the independent Available Stock
production-day reports retain their existing meaning and records.

IMEI Search and Stock Journey now distinguish Box Entry, Accounts Pending,
Box Re-check and verified export. A box scan never establishes export. Older
scan-only entries remain visible as Box Scan History (not exported), preserving
their original date, box and operator. Accounts verification and actual stock
dispatch are separate dated evidence. If a phone is currently Ready Stock, a
genuine earlier verification remains explicitly historical, rather than its
current stage. A legacy shipped value without verification is labeled as an
unverified box entry; it is not silently rewritten in business records.

The source readers apply these rules before filter facets, sorting and paging.
Current phone details prefer the latest non-deleted job, independently from older
history. IMEI Search always shows the Current location, even without a region.
Supplier receipt quantities and protected names retain their existing handling.
The release does not transfer, delete or reset phones, boxes or business history.

Run the supplied Publish-GreenLoop-Journey-Status-Fix.ps1 from the outputs folder.
The publisher verifies prior installations, supplies the missing reviewed SQL,
checks installed_journey_status_version = 20261105-journey-status-1, and then
publishes the pinned source using ordinary Git ancestry. No force push, Edge
deployment, JWT change, secret or additional permission checkbox is required.
Wait for GREENLOOP JOURNEY STATUS LIVE - VERIFIED and press Ctrl+F5.

Regular tables remain paginated at 50 records. Complete exports and explicit
bulk/scanner trays are unchanged. The previous inline Issuance editor is included.
