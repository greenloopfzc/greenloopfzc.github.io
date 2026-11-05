# Returned phone current location

Supplier Return handover used to update job/device statuses while retaining the
last workshop location. IMEI Search could therefore show Returned to Supplier
beside Laboratory. This release corrects the current location at both levels.

A completed supplier return displays Returned to Supplier in IMEI Search and
Stock Journey. Requested / approved returns remain at their workshop location
until physical handover. Legacy Laboratory department labels display Lab & Glass.
Internal Laboratory / Glass location IDs remain distinct for saved history.

The database creates a Returned to Supplier location and assigns it atomically
whenever an authorized return sets the existing returned_to_supplier status.
Both one-step Stock Return and approval/handover APIs are covered. Their existing
authorization, parts reconciliation, idempotency and return-hold guards remain.

Existing current completed returns receive a narrow location-only repair using
their actual completed return record and the existing private return scope. A
private repair ledger retains old/new location IDs and the original handover
date. No new handover or movement time is invented. Return dates, receipt counts,
supplier references, prices and original workflow history remain intact.
Requested, approved, cancelled, rejected, archived and subsequently received
phones are excluded from that backfill.

Run outputs/Publish-GreenLoop-Return-Location-Fix.ps1. Missing prerequisites are
combined with the new SQL. Required final result:
installed_return_location_version = 20261105-return-location-1.
No Edge deployment, JWT setting, secret or new permission checkbox is required.
Wait for GREENLOOP RETURN LOCATION LIVE - VERIFIED, then Ctrl+F5.
The previous Ready Stock / box-stage fix, inline Issuance editing, supplier
quantity/name permissions and 50-record pagination remain included.
