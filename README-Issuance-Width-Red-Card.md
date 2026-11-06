# Issuance content widths and combined overdue red card

Based on verified GitHub main 9f2a4b833a55dfe77536a4e92e5a4fbf1275f7c4.
The earlier Overdue Red Card commit branched from e8d535a before Bulk IMEI
Correction. Its four CSS/cache changes have been cherry-picked on top of current
main; all Bulk IMEI source and SQL remain intact. No force push is used.

Lab & Glass Issuance had a fixed percentage colgroup. Shared S.No relocation
moved the header/cells but left these physical column widths unchanged, allocating
the first IMEI column's 11% to S.No. The obsolete colgroup is removed. Issuance
now uses native automatic table layout, compact serials, full 15-digit IMEI space,
content-sized dropdowns and action buttons. Long parts/services grow their own
columns rather than being clipped. Horizontal scrolling stays inside the table
when content exceeds the screen. Empty, populated and inline-edit tables are
checked at desktop, laptop and mobile widths. Save/Cancel buttons also retain
their intrinsic widths on mobile. Existing raised design and 32px controls remain.

The Overdue Phones launch card stays raised and is solid red with white icon,
words and exact count in both light and dark modes, retaining its 46px height.
Internal overdue technician cards and business rules are unchanged.

No new SQL, Edge deployment, JWT, secret, permission or business-data change.
The publisher still verifies earlier installations, including Bulk IMEI Correction,
and offers their existing required SQL only if missing. It accepts only a normal
push descending from the current remote; outside newer changes stop publication.

Run Publish-GreenLoop-Issuance-Width-Red-Card.ps1, wait for LIVE - VERIFIED, then
Ctrl+F5. The old Publish-GreenLoop-Overdue-Red-Card.ps1 entry point forwards to
this combined publisher so it cannot republish its outdated branch.
