# One IMEI correction editor

Reports > IMEI Data Correction keeps its process cards as read-only recorded-workflow views. The phone header now has one **Edit Details** button. It opens all server-authorized editable records in one window, grouped by process, with one correction reason, code and **Save changes** action. Sections with no editable records remain available in the process views.

Phone identity/specifications, initial battery health and GL grade, receiving/supplier grade, saved QC details, part requirements and any other existing editable workflow records use the same server-provided field definitions and immutable source IDs. Final QC fields appear when that phone has a saved eligible Final QC record. No new fields or permissions are invented. Large workflows show 50 editor records per page and retain prepared changes when paging or jumping between sections.

The existing atomic `save_full_imei_workflow_v2` call saves the complete reviewed change set with the original snapshot/revisions. Its stock, custody, linked-record, permission and permanent correction-history checks remain authoritative. Errors retain the prepared edits. Cancel discards only unsaved edits. Only changed fields are validated, so unrelated historical blank fields do not block a correction.

Move back to Initial QC remains on the Issuance process view and uses the unchanged audited stage-action API. Authorized Delete entry actions are inside each saved record's collapsed Record actions section in the single editor; they still require the existing deletion permission, reason/code and server checks. Save or discard edits before any stage action.

The editor closes and clears private data on office lock, sign-out or permission changes. Supplier names and prices retain their existing server masking. Operational Initial QC, Issuance and other sidebar entry pages are unchanged.

This is a frontend-only update. No new SQL migration is required. The publisher checks the previously required database versions, including the already installed Initial QC grade report update; it never treats a missing or mismatched marker as verified. Run the accompanying PowerShell publisher yourself to publish. Codex did not run live SQL or Git push.

Validation: actual protected database fixtures for atomic edits and immutable grade history; guarded full Reports page in headless Chrome; captured browser payload replayed against the actual save API; process views, one editor, cancel, error/retry, paging, supply-source handling, delete/move-back, restricted fields/access, office lock, desktop and mobile dark layout. Root asset mirrors and cache references are kept aligned.
