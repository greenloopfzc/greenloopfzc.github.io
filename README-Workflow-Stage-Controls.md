# Reports-only IMEI stage correction

Open Reports > IMEI Data Correction > Full IMEI Workflow Correction.
Search one IMEI, choose its stage and prepare edits, then enter the correction
reason and existing correction code to Save audited correction.

Fifteen separate tabs follow the sidebar: Stock Received, IMEI Entry, Initial QC,
Lab & Glass Issuance, Return/Replacement, Lab & Glass, Parts, Final QC, B-DEPT,
Ready Stock, Box Entry, Accounts, Stock Exported, Stock Journey and History.
No operational-page correction buttons are introduced. Each stage shows its
actual source records, including separate Final QC and B-DEPT records.

User Access > Reports > IMEI Data Correction has separate Edit, Delete workflow
entries and Move Issuance back to Initial QC actions. Existing Edit access alone
does not grant Delete or Move Back. Existing Owner/Super Admin editors receive
the two new actions. Other accounts can be granted them individually.

An awaiting Issuance receipt has Move back to Initial QC. This removes only its
queue receipt and preserves grades, findings, parts and services. Initial QC then
loads that work for review. Its explicit next Save creates one current inspection
and one new Issuance receipt, or uses the existing direct Ready Stock action when
no work remains. Original snapshots and both actions remain in permanent audit.
Queue counts follow the true stage. No inspection is duplicated by retries.

Delete entry removes an independently removable source record after dependency
checks. Referenced rows, issued parts, movements, return settlements, replacement
receipts and verified/export box records cannot be independently deleted. They
show source explanations or require normal Return/Box Correction/rework actions.
This is not an unrestricted cascade-delete tool. Return reason and notes can be
corrected without changing settlement amounts, quantities or status. Direct Initial
QC Ready Stock grade/final BH can be corrected before boxing, without changing
Initial BH or inventing Final QC history. Actual transfer history remains factual.

Reason, correction code, granular permission, Office access, device ownership and
current snapshot are checked on the server. Private immutable before/after audit
records are not exposed as raw table data. Mixed edits are transactional. Repeated
stage requests replay once; a changed request with the same key is rejected.
Tables remain 50 per page. Receipt supplier quantity/name privacy remains intact.

Installation adds migration 255 after verified 254. No install-time business row
changes, Edge deployment, JWT setting or secret changes are required. Run the
provided publisher, paste its clipboard SQL into a NEW Supabase SQL query, RUN
all of it, check installed_workflow_stage_controls_version, then press Enter.
Wait for LIVE - VERIFIED before refreshing Greenloop.
