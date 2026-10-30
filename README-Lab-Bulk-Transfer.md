# Bulk Transfer to Final QC

Release / database marker: 20261030-lab-bulk-transfer-1
SQL result: installed_lab_bulk_transfer_version

Lab & Glass has a raised Bulk Transfer to Final QC card immediately after Total Pending, with the same 46-pixel height. It opens the dedicated lab-bulk-transfer.html page, which inherits the Lab & Glass permission key. The main workbench has no bulk entry panel. On the dedicated page, scan or enter a 15-digit IMEI. Complete scans add automatically; Enter / Add phone also works, and a pasted list of IMEIs is queued. Each physical phone appears once with IMEI 1, model, storage, color, technician, supplier code and readiness/reasons. Phones from different technicians can share one handover. Remove only changes the proposed list. The scanner remains ready for the next phone.

Transfer All to Final QC completes the selected saved Lab work and moves every phone together using the existing complete_parts_only_lab_v1 / Job Completed path. It retains parts installation, service completion, Final QC steps, location history and device events. Phones leave the Lab queue and enter the existing Final QC queue. Existing individual completion is unchanged. The card is not added to Frame Department.

No new permission checkbox or grant is added. The existing Lab Entry / Job Completed action authorizes scanning and transfer. Reports, Parts, supplier-name and other permissions are unchanged. View-only Lab accounts retain their existing read-only behavior. Office Only and TV-only restrictions remain authoritative on the server.

Missing/partially issued parts, pending return reviews, unsaved services, non-Lab phones or ambiguous work lines block handover with reasons. The workbench link blocks navigation while its lines have unsaved edits or saves in progress. Returning to a cached workbench refreshes the counts and phone lines. Snapshot tokens are rechecked after all relevant phones are locked. One rejected or changed phone rolls back the complete transaction; no partial handover is committed. Recheck list refreshes readiness and tokens without losing the proposed list. A handover supports up to 500 phones per transaction.

An exact per-user request UUID and phone list are recorded in a protected immutable handover ledger. Retrying after a lost/uncertain response returns the original result instead of completing phones twice. An unconfirmed request keeps its handover list fixed until the same transfer is retried. No transfer list is persisted in browser storage; keep the page open while confirming an interrupted request. Office lock removes the protected UI and ignores late responses.

Migration 225 adds the new RPCs, protected helpers, handover ledger and office wrappers. It changes no existing workflow function or permission catalog. Installation transfers no phones. The cumulative publisher installs prerequisite updates only when their verified marker is missing, and stops on changed definitions or failed database checks. No Edge Function or JWT change is needed.

Validation uses disposable PostgreSQL and browser fixtures: canonical IMEI aliases, duplicate scans, physical-parts/service completion, pending returns, stale snapshots, rollback after a second-phone failure, idempotent retries, permissions, immutable audit, queued scans, mobile/dark layout and office lock. No live business records are used or transferred in these tests.
