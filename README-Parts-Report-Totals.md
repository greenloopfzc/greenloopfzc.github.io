# Filtered Technician Parts Report totals

The report table now ends with a Total row. Total Pending Qty appears directly under Pending Qty; Total Phones appears under Phones. Both use the currently filtered report, update immediately on filter changes and refresh, and show 0 when nothing matches. Phones are counted once across multiple parts. Sorting does not change totals. The footer clears when the report is cleared or office access locks.

Table heading sort controls and pending quantity detail buttons are flat, scoped only to the Technician Parts Report table. Sorting, clickable phone details and keyboard focus remain available. Other software cards retain their existing raised design.

PDF and Excel already include their filtered totals and remain unchanged. Existing filters, exports, Bulk Issue review and all permissions are preserved. No new SQL, permission tick, Edge Function or JWT change is required for this UI update. The cumulative publisher checks/installs any earlier missing required updates first.

Run outputs/Publish-GreenLoop-Parts-Report-Totals.ps1 and wait for GREENLOOP PARTS REPORT TOTALS LIVE - VERIFIED, then refresh the website with Ctrl+F5. Live installation/publication remain pending until the publisher succeeds.
