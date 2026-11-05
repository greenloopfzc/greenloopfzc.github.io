# Issuance sidebar and B-DEPT scanner

Lab & Glass Issuance is a sidebar link immediately after Initial QC. The old
Initial QC toolbar card is removed. The link opens the existing full page, with
its existing Initial QC View / Entry permissions. No new permission tick.
Only Issuance is active on its page. Its red badge uses the existing authorized
saved-inspection count, displays the exact number above 99, hides zero and
refreshes through the same committed-write, cross-tab, Realtime and polling
signals. A temporary read error retains the last verified notification.

B-DEPT has a dedicated Scan / paste IMEIs field separate from table search.
Each scan adds another selected native work line and empties the scanner for
the next phone. Pasting an Excel column loads all valid 15-digit IMEIs as
individual lines. Duplicate, IMEI2, missing and wrong-stage entries are blocked
and explained; current-location details are available. Show all pending returns
to the original pending queue. Scanning never saves, passes or transfers phones.
Earlier line grade, BH, Pass/Fail, destination and technician choices survive
later scans and reads. Each phone still needs its existing Save action.
View Only cannot use the entry scanner or save work. Native server actions,
Office Only, supplier-code quantities and confidential-name rules remain.

Frontend-only changes. No additional SQL, Edge, JWT, secret or permission tick.
The publisher verifies the prior Complete Stock Lists installation and supplies
that prerequisite SQL only if it was not installed. No reset or cleanup.
