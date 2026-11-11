# Original-stock replacements and shared Cable Reader

Prepared 11 November 2026. This package has not been applied to the live database or published by Codex.

## Replacement stock

Replacement jobs now join the exact original supplier receipt, batch and invoice. Already-entered, verified replacement links are corrected by the installer in the same transaction. The old returned phone, its permanent return/settlement records, replacement allocation links, quantities, identity, technician, stage, timestamps and work history remain intact. Each job reassignment has a private immutable before/after audit and a device-history event. Re-running the installer does not duplicate the correction.

Original receipt quantity remains unchanged. Returns, replacements and stock balance remain separate. The permanent technical intake/allocation receipt stays available for audit; it is not another supplier purchase and no new public BATCH/INV sequence is consumed by the current replacement form. Completed replacement intake no longer leaves a phantom incomplete batch. Pending replacement intake uses the original stock's public label and an internal reservation ID, so only its reserved new IMEIs can enter. Original purchase capacity and replacement capacity stay separate.

An existing replacement that is already held/returned again or assigned to a saved box stops the repair for review; the whole transaction rolls back. Guards are not disabled and business history is not deleted.

Model and GB must match a pending completed return in the selected supplier stock. Color is optional and may differ: a Black return can be replaced by a White phone of the same Model/GB. The old returned phone's color is preserved; the new phone records its actual color during normal IMEI intake. Unknown Model/GB, wrong stock, duplicates, stale matching previews and excess replacement quantities remain blocked.

## Cable Reader

Connect one unlocked/trusted iPhone or authorized Android phone to a PC with the existing Greenloop Cable Reader installed. The shared Cable Reader strip shows available primary IMEI, model, GB, color, Battery Health, serial number and region. Missing USB values are left missing.

- Replacement: select Supplier and Original Stock/Batch, then connect the phone. Available Model/GB/Color and primary IMEI fill a new replacement row. Check matches and Receive Replacement remain manual. Open IMEI Entry to complete the reserved phone details and continue Initial QC under the original stock.
- Stock Return: choose the stock first. Cable IMEIs use the same stock validation as scans; wrong-stock rows remain red with their actual batch/current stage. Return submission remains manual.
- Initial QC, Issuance, Final QC and B-DEPT: load the existing phone through the normal stage-checked scan path. Loaded rows are not saved/transferred automatically.
- Lab/Glass and bulk Final QC handover: use the existing phone lookup/handover scan path.
- Box Entry: use the current scan path; existing eligibility/duplicate rules remain in force.
- IMEI Search, Parts and visible report/search filters: search by primary IMEI using existing permissions. Full/Bulk IMEI Correction opens the phone for review; it does not apply corrections or overwrite existing drafts.
- Other report/stock windows display the connected phone strip. Open/focus the required entry/search view and choose Use connected phone when necessary.

Repeated enrichment of the same connected phone does not add duplicate rows. Read again refreshes the reader; Use connected phone retries a handoff. Manual drafts, saved identifiers, permissions and Office Only remain enforced. Office lock/sign-out clears phone data and stops reading. Existing IMEI Entry Auto Save behavior is preserved; this update adds no auto Save/Transfer/Return elsewhere.

## Install

Run outputs/Publish-GreenLoop-Replacement-Cable.ps1 using the supplied PowerShell command. It verifies pinned files and earlier installed versions, copies the complete additive SQL when needed, and waits for the exact version result before publishing. Run the clipboard SQL in a NEW Supabase SQL query. Required result: installed_replacement_original_stock_version = 20261111-replacement-original-stock-1.

No Edge Function deployment, JWT change, secret or new permission tick is needed. No force push. Only after LIVE - VERIFIED, press Ctrl+F5. Reader setup is still required separately on each cable-entry PC.

## Verification

Isolated PostgreSQL tests cover first/repeat installation, all prior marker integrity, exact old/new allocation, original batch ownership after intake, existing-phone repair, full original stock with no phantom pending intake, re-return and replacement of a replacement, optional/different color, Model/GB/stock/duplicate guards, atomic rollback, immutable audit/history, original quantity, balance, 50-row reports, complete exports, Office Only, anonymous/private access, concurrent/stale retries and no public number-sequence consumption.

Actual Chromium checks exercise shared USB handoffs, compact trays, existing draft protection, view-only restrictions, Office lock, freshness/dedup, real Replacement and Stock Return controllers, wrong-stock red rows, actual PDF/Excel generation, canonical batch/receipt quantities and authorized names, and desktop/mobile fit. No live data writes were used for these tests.
