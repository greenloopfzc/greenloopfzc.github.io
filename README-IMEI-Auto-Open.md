# IMEI Search: direct full-IMEI report

On IMEI Search, a complete 15-digit IMEI entered by scanner, paste or typing
opens the saved device report automatically. It bypasses the autocomplete
250ms debounce, search-record lookup and result selection. IMEI2 is resolved
by the existing authoritative journey reader, retaining canonical phone identity.

Partial IMEIs and model/serial/invoice searches retain suggestions. Other
record-search inputs do not opt into automatic full-IMEI opening. Bulk phone
lists retain their existing handling. Composition waits until committed.

Only a running exact report read is shared with trailing scanner Enter or
simultaneous form submission. Completed reports are not cached; a new edit or
an explicit later search reads again. Changed queries, late Office/access
changes, errors and not-found results retain the page's existing stale-response
and permission handling. Receipt enrichment, full history, all grades and BH,
correction history, original supplier/batch quantities and privacy stay intact.

No new SQL, polling, workflow write, business-data correction or automatic
transfer. Actual database/network time still applies to the report read.

Validation: real Chromium at desktop/mobile widths using actual record-search,
IMEI page and history/correction modules with disposable local API fixtures.
Exact auto-open, running-read coalescing, repeated input, fresh retry, IMEI2,
partial search, composition, other-widget isolation, errors/not found and stale
Office replies. Existing timeline/date/user/rework/51-row correction paging
regressions pass in light/dark desktop/mobile modes. Publisher retains all
cumulative installation prerequisites and verified source/package/live hashes.
