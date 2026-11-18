# Background read speed update

This update reduces repeated background reads while keeping automatic updates,
complete lists, manual Refresh and authoritative scan/Save/Transfer checks.

- Sidebar badge fallback polling is 30 seconds, including Office mode, replacing
  the Office 2-second loop. Office/network enforcement keeps its own checks.
- Parts badge fallback is 30 seconds. Commit signals, focus and reconnection
  still refresh; bursts share one active read and retain a trailing refresh.
- Failed badge reads keep the last displayed value marked stale. They never
  fabricate zero work. Late permission/Office responses cannot restore counts.
- Lab overdue retains a committed refresh arriving during an active read.
- Counters reuse saved Lab visit counts in a fresh request instead of calculating
  them repeatedly per part request. The set-based visit reader preserves the
  existing initial-entry clock, duplicate entry grouping, same-time exits,
  repeated visits, closed/deleted-job rules and current ongoing eligibility.
- Issuance counts do not construct full editable phone rows. IMEI Entry counts
  retain the existing eligible-receipt and return-adjusted calculation.
- Lab overdue uses receipt labels without calculating all stock balances.
- Damage TV computes the current account-scoped month source once for its board:
  employee quantities, incidents, original/copy prices, currencies and activity.
  Existing selected employees, display masks, detail APIs and 30-second display
  refresh remain. There is no five-minute/manual-only mode.

Original stock quantities, IMEIs, assignments, parts, audits and histories are
unchanged. No business backfill, completed stage cache, automatic write replay,
larger timeout, result cap or count approximation is introduced.

Install the cumulative publisher's prompted SQL in the affected Supabase project.
Required result: `20261118-background-read-speed-1`. The publisher verifies the
actual installed version before publishing. Then refresh open software tabs.

Validation uses disposable PostgreSQL fixtures and a browser. The supplied two
live reports identified the targets; local timings are not live server speed
guarantees. Compare live CPU and response times after deployment. A background
card may show another user's change until its next fallback refresh; each scan
and Save/Transfer still validates current server state.
