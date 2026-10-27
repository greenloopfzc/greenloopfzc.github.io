# Lab pending counts

Version: 20261027-lab-pending-card-1 (frontend only; database version remains 20261026-employees-1).

Lab & Glass shows Total Pending in a compact raised card next to Open phone, with a phone icon, muted label, large red count and phones unit. The card matches the Open phone button height (46px), with icon, label and value on one horizontal row. It uses the current theme background, rounded corners and raised shadows; mobile uses the full available width while keeping the same height. It uses the full employee board, including Unassigned, and is independent of selected employee, IMEI search and table filters. The summary remains available to users with Lab View permission, including accounts without Search permission. Existing board refresh updates the summary and employee badges together. Failed refreshes keep the last successful count.

Nonzero employee badges are larger, solid red with bold white numbers in light and dark themes. Zero badges stay neutral. Exact counts are displayed above 99 as well. Employee names and raised cards retain their layout.

No new SQL or Edge Function change is required when the Shared Employees update is installed. The pinned publisher can install the earlier Employee prerequisite when missing, then publish the cumulative tested files. All earlier workflow and access rules remain in effect.
