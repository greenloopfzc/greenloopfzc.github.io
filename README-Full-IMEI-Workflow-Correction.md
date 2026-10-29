# Full IMEI Workflow Correction

Open **Reports > IMEI Data Correction**. Accounts with **Reports > View page** and **Full IMEI Workflow Correction (Reports only)** see the new workspace. The existing phone-only and box correction permissions remain separate. No departmental correction buttons were added.

Search a primary IMEI, an existing secondary IMEI alias, or a device number. The workspace displays the primary IMEI only. Select the department, edit a recorded entry, and choose **Add to changes**. Prepare any other linked corrections, enter a reason and the existing correction code, then choose **Save audited correction**. All changes commit together or none commit. Reload first if another user changed the phone after it was opened.

The workspace covers 23 recorded entry types across IMEI Entry, Receiving, Initial QC, Lab & Glass assignments/work/timers/services, ordered/issued/installed/returned parts, Final QC, Frame and movement dates through Ready Stock. Existing records can be corrected; it does not create/delete workflow records or directly override lifecycle states. Use the normal workflow for new work, returns, approvals and Rework.

Quantities must remain consistent across requests, issues, installations and returns. Warehouse quantity corrections adjust stock by their difference. For an old Parts Flow issue with an ambiguous stock source, choose whether it originally came from warehouse inventory or direct supply. Reviewed return corrections also update the linked return ledger and restocking balance. Issued physical stock identities cannot be renamed into another part; use return/replacement instead. Receiving supplier codes must match the selected batch. Movement dates must retain cycle order, and Ready Stock must retain a passing Final QC and completed requirements. For a phone already in an export box, editing device or Final QC data also requires the existing Box Correction permission.

Part prices/costs require existing **Parts > View page** access. They are omitted from entry fields and correction history without that access. IMEI2 and serial remain hidden. Existing Office Only, TV-only and active-account protections apply on the server. A permanent, private correction audit keeps the actor, time, reason and old/new approved values. General activity logs contain an audit reference rather than confidential price payloads.

The migration grants the new action initially only to existing Owner / Super Admin accounts that can view Reports. Other accounts must receive the new Reports tick in User Access. Existing phone-only correction remains available to accounts with its old permission.

## Installation

Run the provided `Publish-GreenLoop-Full-IMEI-Workflow-Correction.ps1` script. If the optimized verification engine is missing, the first clipboard query is the database verification repair. Run that complete query and confirm `installed_verification_engine_version = 20261029-verification-engine-1`, then return to PowerShell and press Enter. The script uses one read-only result map rather than repeatedly rechecking the same dependency chain. Original version functions and business data remain unchanged. It checks pinned source files and installed versions, then copies the required cumulative SQL only when necessary. In Supabase SQL Editor, use a new query, paste the clipboard directly, and run the complete SQL through:

`installed_full_imei_workflow_version = 20261029-full-imei-workflow-1`

Return to PowerShell and press Enter. The script fetches GitHub history, stops on divergence without force pushing, uploads the pinned release and verifies the published file contents. Refresh the site with Ctrl+F5. No Edge Function or JWT setting changes are required.

Validation uses a disposable PostgreSQL database and browser fixtures, not live business data. Deployment and live verification occur only when the publisher succeeds.
