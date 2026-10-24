# Lab & Glass — 2+ Days

Version: 20261024-lab-delay-1

Dashboard adds the Lab & Glass 2+ Days card immediately after Lab & Glass. It counts unique phones still in Laboratory/Glass whose current continuous stay has reached 48 elapsed hours. Open it for one IMEI per row: model, GB, color, grade, supplier code, department, current technician, arrival time and elapsed waiting time. Dates use Asia/Dubai. Search and date/technician/model/department filters remain inside Filters; table headings sort, and results paginate 50 per page.

The start is the saved external-to-LAB/GLASS movement (including Initial QC routing). Technician reassignment and internal LAB-to-GLASS movement do not restart it. A recorded exit closes the stay; another entry starts a separate visit. Duplicate entry records without an exit are grouped into one stay. Active rows require the phone and its latest live job to still be in Lab/Glass. Deleted devices/jobs, completed stays and phones with no recorded arrival evidence are excluded from the current count. No arrival date is guessed from device creation or a technician's mutable assignment time.

IMEI Search and Stock Journey show a 2+ Days section for qualifying current or historical stays, including arrival, exit, elapsed time and job. Historical durations stop at the recorded exit, so they remain visible after the phone moves on and do not keep growing. No business entries, transfers or staff actions are created by this report. Existing recorded movement history is used; missing historical movements cannot be reconstructed.

Existing page permissions apply: Dashboard View opens the card/table, Search controls filters and Sort controls heading sorting. IMEI Search or Stock Journey View permits its corresponding delay history. Pagination, refresh, close and error retry are read navigation. TV Only and Office Only restrictions remain enforced on every new API. No new user grants or Edge Function change is required.

The live count and an open report refresh every 30 seconds while visible and on window focus. Filtering is retained. An unavailable count shows a dash rather than a false zero.

Installation: run Publish-GreenLoop-Lab-Delay.ps1. When it copies the new SQL, paste directly into a NEW Supabase query and RUN. Required final result:
installed_lab_delay_version = 20261024-lab-delay-1
Then press Enter in PowerShell. No Edge Function/JWT step is needed. The installer verifies existing Box Recheck support, pinned sources, Git history and published files.

Local verification includes the previous migration chain in a disposable PostgreSQL database, repeated migration replay, permission boundaries and isolated desktop/mobile browser fixtures. Live installation and deployment are pending the publisher run.
