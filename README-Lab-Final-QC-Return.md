# Lab Final QC return label
Phones currently returned from a failed Final QC to Lab & Glass show **Failed & Returned from Final QC** beside their IMEI, in large bold red text. No failure reason is added.
The existing combined workbench read is delegated unchanged and enriched with a boolean derived from the current Lab stay's latest external arrival and latest Final QC inspection. A previous failure, B-DEPT return, generic rework count or supplier return alone cannot trigger the label.
One additive read-only SQL installation is required. No business records are backfilled or changed, no new permission tick, Edge deployment, JWT setting or secret is required. Existing Lab view/search, office, active account, IMEI2, supplier-name and Parts rules are retained.
Run Publish-GreenLoop-Lab-Final-QC-Return.ps1, run its clipboard SQL in a new Supabase query when requested, then press Enter. After LIVE - VERIFIED use Ctrl+F5.
