# Diagnostic Battery issued: Final BH 100

An active Diagnostic Battery issue for the same job and phone now sets Final QC BH to 100 without requiring a separate part-installation row or completed Parts order. Ordered-only, cancelled, fully returned or fully pending-return issues do not qualify. Ordinary Battery and Battery Boost do not qualify. Original Initial BH remains unchanged.

The existing Final QC and route-to-B-DEPT server hooks use this same helper, so a stale or altered client value cannot save a lower Final BH when the diagnostic battery qualifies. Existing recorded QC history is not backfilled by installation.

Single scans refresh the battery default instead of reusing an older queue value. Bulk paste and Auto Pick retain batched queue refresh. Verified automatic 100 is read-only on the Final QC row; other phones keep their normal BH input. Missing or invalid defaults stop loading rather than guessing.

The additive SQL only changes the reviewed private battery helper and its own QC integrity reference. No quantities, part issues, returns, assignments, Initial BH, account permissions or historical inspections change. No Edge Function, JWT, secret or new permission tick is required.

Run outputs/Publish-GreenLoop-Diagnostic-Battery-BH.ps1. Run its clipboard SQL in a NEW Supabase query and confirm installed_diagnostic_battery_issued_version = 20261107-diagnostic-battery-issued-1. Press Enter in PowerShell, wait for LIVE - VERIFIED, then Ctrl+F5 and scan again.
