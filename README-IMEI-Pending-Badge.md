# IMEI Entry pending badge

The IMEI Entry badge previously subtracted entered IMEIs from every receipt's original quantity. This could include inactive receipt suppliers/channels or units already reserved/returned without an IMEI, even though IMEI Entry's actual batch selector excluded them.

The badge now sums remaining_quantity from get_open_stock_entry_batches_with_lines(), exactly the same eligible receipt list that IMEI Entry uses. A genuinely unentered available unit still counts as one; an empty scan tray alone does not mean all receipts are complete. Returns for already entered IMEIs are not subtracted twice. Zero counts continue to hide the badge.

The additive SQL patches only the reviewed sidebar count helper and its exact office/integrity references. It preserves all stock, original receipt quantities, phones, returns, history and selected permissions. Unreviewed definitions stop installation. Office enforcement and page visibility remain in place. No Edge Function, JWT or secret changes are needed.

Run outputs/Publish-GreenLoop-IMEI-Pending-Badge-Fix.ps1. If prompted, run the clipboard SQL in a NEW Supabase SQL Editor query, confirm installed_imei_pending_badge_version = 20261107-imei-pending-badge-1, then press Enter in PowerShell. Wait for LIVE - VERIFIED, then Ctrl+F5. The package also includes the preceding User Access refresh fix.

Installer compatibility: normalize both the stored function and the replacement literals before matching, so first installation works with either Windows CRLF or Unix LF SQL. The earlier test only repeated a CRLF install after LF was already installed; fresh installations are now tested separately.
