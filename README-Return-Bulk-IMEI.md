# Return Stock: bulk IMEIs and receipt labels

Version: 20261111-return-bulk-imei-1

Return/Replacement > Stock Return > choose supplier and received stock > Bulk IMEIs > paste the Excel IMEI column > Add IMEIs. The original Scan IMEI field also accepts the full pasted column. Add is a preparation action; Stock Return remains the explicit save action.

The prepared list shows S.No, IMEI, status/reason and Remove. Duplicate IMEIs are ignored and shown for review; malformed values must be removed/corrected before saving. A blank quantity follows the unique prepared count, while an explicitly typed return quantity is preserved. Single scanning clears the scanner for the next phone. The existing 1,000-phone atomic return maximum is unchanged; oversized input stays intact for splitting rather than being truncated.

The supplier selector identifies the company only: SUP-01, plus its name for authorized viewers. Once received stock is selected, its supplier code uses that receipt's own original quantity, for example SUP-01-(342). The received-stock option also includes its invoice and batch with original receipt quantity. Separate 100- and 342-piece deliveries cannot contribute quantities to the company identity label. Supplier IDs, receipt IDs and canonical batch/invoice records are unchanged.

Eligibility, receipt ownership, return balances, IMEI2 aliases, held/returned phones, parts clearance, permissions and idempotency remain enforced by the existing atomic backend when Stock Return is saved. Unknown IMEIs can retain the existing return-before-IMEI-entry behavior. Server rejections identifying an IMEI appear beside that prepared line, and the existing current-location notice remains available.

No new SQL, Edge Function, JWT setting, encryption secret or permission tick. Previous updates, including Ruby Obsidian Glass and the Cable Reader download, are preserved. This publisher does not install or restart the Cable Reader. Existing required database installations are checked before publishing.

Run the matching outputs/Publish-GreenLoop-Return-Bulk-IMEI.ps1 script. After LIVE - VERIFIED, press Ctrl+F5 and open Return/Replacement > Stock Return.
