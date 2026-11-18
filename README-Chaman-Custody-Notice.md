# Chaman custody notices

Current-stage labels use the exact active, nonvoided Chaman custody record for
the physical phone. Dispatch and each receiving direction are separate:

| Saved phase | Current stage | Transfer-blocking reason |
| --- | --- | --- |
| out_pending | Chaman receiving pending | Chaman receiving pending |
| shop | Chaman Shop | At Chaman Shop |
| return_pending | GL receiving pending | GL receiving pending |
| company / no active custody | Existing saved company stage | Existing workflow checks |

A phone already received by Chaman is not pending Greenloop receiving. It may
remain at Chaman; no return is assumed or created. Only an actual saved return
dispatch creates GL receiving pending. Confirmed GL receiving restores the
saved company department. Completed and voided trips cannot override the active
trip. This update does not infer a sale or add a sales workflow.

The protected general IMEI stage reader and Lab handover preview share the same
private phase reader, keeping the main Lab lookup, generic stage notice and
Bulk Transfer popup consistent. Bulk/individual Final QC transfer stays blocked
while the phone is outside company custody. An unverified legacy label is not
translated into an invented receiving-pending claim.

The installer changes only function definitions and reviewed installation
receipts. It does not change Chaman phase, documents, receiving timestamps,
assignments, original stock quantities, counters, parts, timers or history.
Existing Chaman counts already distinguish shop stock from dispatched returns.

Validation uses disposable PostgreSQL fixtures:34 received shop phones produce
zero Chaman receiving pending and zero GL receiving pending; returning one makes
only that phone GL receiving pending while33 remain at Chaman. Confirmed return,
later trips, both protected readers, current workbench identity, permissions,
atomic installation and existing bulk handover checks are verified. These are
test records, not a new live inventory audit.

Run the cumulative publisher and install its prompted SQL in the same Supabase
project. Required new result: `20261119-chaman-custody-notice-1`. Then finish the
publisher and refresh open tabs. Codex has not installed SQL or changed live
business records.
