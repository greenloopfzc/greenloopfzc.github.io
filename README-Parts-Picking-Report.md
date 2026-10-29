# Parts picking report

Open Parts > Technician Parts Report. Technician and Parts Wise dropdowns work together. Every technician shows required part units, including 0; phone counts remain separate. Part counts beside each technician respect the selected part. Part dropdown counts respect the selected technician. Choosing All Technicians gives a part/model/color list across the team; choosing one technician produces that technician's picking list.

PDF View, Download PDF and Download Excel use the current technician/part selection and current pending quantities. Download links carry the report's explicit technician_download permission. Report refreshes wait during export so a background refresh cannot silently cancel file generation. PDF View also offers Open PDF for browsers that do not display an embedded PDF. Download permissions remain separate from issuing permissions.

Accounts with Parts > View Technician Parts Report and Issue parts can select report lines and choose Review Bulk Issue. The review lists the exact IMEIs, parts, colors, technicians, current quantities, optional inventory source and optional per-part price. Adjust or uncheck individual requests, then choose Confirm Bulk Issue. The server supports up to 50 selected report groups / 200 requests per confirmation, verifies current revisions and assignments, and uses the existing part issuer for every request. All issues commit together; a failed line rolls back the whole batch. The existing checks for reviewed replacements, pending balances, stock, prices, Office Only, TV-only and active accounts remain in effect. An old review cannot issue the same quantities twice.

No parts are issued merely by opening the report, filtering it, downloading a file or opening the review. Prices remain in Parts. The report and its exports contain no supplier/customer names or hidden phone identities. Existing Parts Ordered, Parts Returned, IMEI correction and other workflow updates are preserved.

Run Publish-GreenLoop-Parts-Picking-Report.ps1. It checks pinned files and existing updates, includes the existing verification/save repairs if needed, then copies the Parts picking SQL. In a new Supabase SQL Editor query paste the clipboard directly and run the complete SQL through:

installed_parts_picking_version = 20261029-parts-picking-1

Return to PowerShell and press Enter, then let GitHub and website verification finish. Refresh the website with Ctrl+F5. No Edge Function or JWT setting change is needed.

Validation uses disposable PostgreSQL, browser fixtures with actual download events (no anchor-click bypass), downloaded PDF/XLSX content checks and rendered PDF review. The old generic download permission failure is covered separately. No live business data is used or issued by those tests. Live installation and publication occur only when the user runs the publisher successfully.
