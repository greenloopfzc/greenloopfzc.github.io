# Final QC failure reasons and return technician

Tick Fail on a loaded phone to show its Failure Reason dropdown, + / - controls and Return Technician dropdown. The previous active technician is preselected from the completed Lab/Glass step. Each phone keeps its own reason and technician; a failure reason is mandatory. The return controls/column remain hidden while no loaded phone is failed. The raised light/dark design and horizontally scrollable work tray are preserved.

Final QC's existing Entry permission allows a failed phone to be returned with the chosen technician. Its existing Manage names & dropdown choices permission controls reason add/remove. No new User Access tick is introduced. The employee list reads the central active technician roster. Refresh updates this list and the reason choices. Removing a reason archives it for future selection; saved inspections and audit snapshots retain the reason text. Normalized duplicates reuse an existing reason.

The new return RPC validates the phone's current Final QC step, reason, active technician and an assignment context token. It calls the existing complete_final_qc_with_final_grade_v2 workflow, then assigns the reopened Lab/Glass step in the same transaction. A failure rolls everything back. It preserves native role, capability, Office Only, supplier-return, Parts, stock and Battery Health guards. Pass and B-DEPT continue using their existing APIs. Initial BH and the original Lab arrival clock remain intact.

The return audit records the inspection, reason, previous and selected technician, actor and timestamp. A readable device event also records the change for existing phone history. Old technician timer rows remain; active work is assigned to the selected technician. Private audit snapshots intentionally have no cascading business-record foreign keys, preserving permanent audit history and the existing reviewed scoped-delete boundary.

## Installation

Run outputs/Publish-GreenLoop-Final-QC-Failure.ps1 in the original workspace. The publisher verifies the cumulative prerequisites and copies Install-Final-QC-Failure.sql to the clipboard. Paste it directly into a NEW Supabase SQL Editor query and run the complete query. Required result:

installed_final_qc_failure_version = 20261103-final-qc-failure-1

Then return to PowerShell and press Enter. No new Edge deployment, JWT setting, encryption secret or permission tick is needed. After LIVE - VERIFIED, press Ctrl+F5 on Final QC. Code is published only after the new database marker is verified.

Local PostgreSQL/PGlite tests cover atomic return/reassignment, Lab and Glass, stale/repeated requests, removed choices, timers/history, rollback after a late error, permissions, Office Only and unchanged previous installation seals. Browser tests exercise the real frontend client guards, required reason, original/default/new technician, add/remove, row isolation, error drafts, Pass/B-DEPT and mobile/dark layout. Package TEST-SUMMARY lists the final results. Tests use disposable local data and do not modify live business records.
