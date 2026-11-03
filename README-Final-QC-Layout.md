# Final QC failure details without widening the work tray

Ticking Fail no longer adds an extra table column or forces a wider table. The original 14 phone columns remain, including visible IMEI, result controls and Save. Each loaded failed phone displays its reason, + / - buttons and return technician in a panel below that phone's values, inside the same work row. An IMEI caption identifies the owner of the controls.

The panel reserves its own measured vertical space. Long hints and font/layout changes cannot cover the phone data or the next row. Switching back to Pass/B-DEPT hides the panel and returns the row to its compact height. Empty carried-forward rows do not open failure panels. Tray row counts, scan targets and bulk-save identity remain unchanged because no extra table rows are introduced. Observer registrations are cleared when replacing/resetting the tray.

Desktop Fail toggles preserve the original table width without creating a horizontal scrollbar. Narrow screens retain the original table's mobile scrolling behavior; Fail does not increase its width.

Failure validation, selected technicians, permissions, reason add/remove, audited return RPC and all existing SQL remain unchanged. No additional migration, Edge deployment, JWT setting, secret or access tick is needed. The cumulative publisher still verifies the previously installed Final QC Failure SQL and can install that prerequisite if it is missing.

Run outputs/Publish-GreenLoop-Final-QC-Layout.ps1. After LIVE - VERIFIED, press Ctrl+F5 on Final QC. Local real-browser checks exercise unchanged scroll width, control positions, Save/Pass/B-DEPT, choice management, permissions, drafts, double-save, separate phone selections, reset/add-row behavior and wrapped panel content. Tests do not modify live business data or claim live publication.
