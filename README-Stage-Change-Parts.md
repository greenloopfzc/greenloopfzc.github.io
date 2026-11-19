# IMEI stage correction and cancelled-phone Parts notices

Reports → IMEI Data Correction → open the IMEI → **Change Stage**.
The dialog shows **Current Stage → Destination Stage**, a reason and the
existing correction-code field. Lab routing also requires an active technician.
Only freshly verified allowed destinations can be confirmed. Initial QC must
actually be saved before forwarding; Ready Stock / B-DEPT cannot manufacture a
QC pass. Chaman custody, supplier returns and boxed stock keep their existing
guards. Unissued requests must be issued or cancelled in Parts; pending return
reviews must be resolved. Normal Lab completion retains its services/parts and
native Entry checks.

The independent **Change IMEI workflow stage (audited)** Reports permission is
initialized for eligible Owner / Super Admin accounts. Other accounts need an
explicit User Access grant. The existing Move Back action remains available.
Corrections retain the original phone, job, receipt quantity, supplier and batch;
they keep a complete immutable before-scope, From/To, user, UAE date/time and
reason. Initial QC reinspection reuses the existing work order through the
protected native workflow. Timer history and normal handover checks remain.

Parts → **Cancelled Phones** contains **Pending Collection** and **Completed
History**, in snapshot-checked 50-record pages. The badge counts distinct phones
with unused issued parts still to collect. Cancellation records show:

- IMEI / model, cancelled-from stage and the saved technician;
- **Issued Parts** and **Pending Parts** names frozen at cancellation;
- cancellation user, UAE date/time to seconds and reason;
- an English notice, with no part quantity:
  **“This phone was cancelled from Lab & Glass. Please collect any parts that
  need to be returned by [Technician Name].”**

The notice and main cancellation table have no parts-quantity column. Review
Parts separately records the *actual physically collected* quantity and its
condition through the original protected Parts return review. Installed parts
are excluded. Nothing is automatically restocked, cancelled or marked returned
by opening a notice or changing stage. Existing pending return / legacy review
workflows remain available; unsupported legacy issue collection is explicitly
identified rather than silently cleared. New notices come from audited work
abandonment and later real work-order cancellations. Ordinary completed Lab
handover is not a cancellation; installation does not invent past events.

The Parts badge shares the existing coalesced 30-second refresh. No new polling
timer, persisted stage snapshot cache, business backfill or larger timeout is
introduced. Unavailable/malformed reads show errors and never invented zero
counts. Prepared collection values and uncertain-response request IDs survive
failures; permission / Office locks discard late replies.

## Manual installation and publication

Run the supplied `Publish-GreenLoop-Stage-Change-Parts.ps1`. Its package checks
the pinned clean source and existing database prerequisites. If prompted, run
the copied SQL in Supabase SQL Editor yourself. Required result:

`20261119-stage-change-parts-1`

After the script verifies that exact installed version and publishes, refresh
the browser with Ctrl+F5. `-CheckOnly` performs local source/package verification
without production SQL, clipboard changes, network publication or Git push.

## Local validation

`tools/stage-change-parts` contains synthetic DB / installer / actual-Chrome UI
tests. They require the project's PGlite / Playwright runtimes and a disposable
synthetic DB dump **after SQL331**, supplied with `STAGE_CHANGE_BASE`. Never use
a production DB as the test fixture. Browser data in `fixture.json` is synthetic;
screenshots and regenerated evidence go to the OS temporary directory.

The tested paths include blocked/stale corrections, same-job reverse and native
reinspection/re-issuance, Lab/Final-QC repeat visits and timer order, native Parts
collection, installed exclusion, frozen issued/pending names, private grants,
atomic rollback, LF/Windows CRLF/repeat, version integrity, 50-row paging and
desktop/mobile light/dark layouts. Live database installation and publication
remain manual and are not certified by local fixture results.
