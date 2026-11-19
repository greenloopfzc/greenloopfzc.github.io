# Parts pending count and table membership

The Parts Ordered badge and Pending tab now use the same fresh, canonical order
membership. It counts each phone once, requires a current Lab / Glass job and
repair visit, and excludes active Chaman custody, other stages, deleted records
and cancelled work. Old order records are retained. Confirmed Greenloop receiving
restores the saved pending order; Chaman return dispatch alone does not.

Pending means an active request still needs issuing. A return-review-only phone
does not inflate that count: it remains in Parts Returned, and its issued order
can still be opened from Issued. The sidebar retains its existing meaning:
distinct phones needing issue **or** return review, deduplicated across both.
Consequently a filtered table or a separate pending return can legitimately
differ from the global Parts Ordered badge. This update does not copy a badge
number into the table or hide a real pending order to make numbers look equal.

Filtering, facets, tab totals, sorting and50-row paging all apply after the
shared eligibility check. Completed history remains available. Invalid or
incomplete queue responses show an explicit unavailable / retry message rather
than a fabricated zero or a partial complete-looking list. Counts continue to
use the existing coalesced background refresh; no new polling or persisted stage
cache is introduced.

The Reports Lab-to-Final-QC correction also uses the finalized Parts completion
API, retaining its locked readiness and revision checks and its Completed order
history. Original quantities, supplier/batch labels, requests, issues, returns,
prices, damage marks, custody and work history are preserved. Installation makes
no business-record repair or backfill.

Run `Publish-GreenLoop-Parts-Queue-Membership.ps1`. Run any prompted SQL yourself
in Supabase SQL Editor; the new result must be:

`20261119-parts-queue-membership-1`

After successful publication, use Ctrl+F5. `-CheckOnly` is local verification and
does not publish, run production SQL or change the clipboard.

Validation in `tools/parts-queue-membership` uses synthetic PGlite and actual
Chrome fixtures. `PQM_BASE` can point to a disposable synthetic database after
SQL331 or332. Never use production data for these tests. `PQM_VERIFY_MARKERS=1`
checks previously valid cumulative installation markers as well. The renamed
badge fixture demonstrates runtime resolution with the old generated name
absent. Browser fixtures are synthetic; regenerated evidence belongs in the OS
temporary directory. Local tests are not a live database audit.
