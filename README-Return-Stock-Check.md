# Return Stock: immediate IMEI receipt checks

Version: 20261111-return-imei-stock-check-1

Return/Replacement > Stock Return > select the supplier and received stock > scan or paste IMEIs. Added lines immediately enter Checking stock, followed by a read-only batch check. The list includes each phone's actual Stock / Batch No and that receipt's original quantity.

An IMEI belonging to another stock appears in a red row with its actual batch and a Different stock reason. Remove that line or select its correct receipt. Save is blocked while any stock checks are pending, unavailable or rejected. Check stock again retries the read without changing records. Adding/removing phones while a check is pending triggers a fresh check of the current list; old receipt responses cannot change a newly selected stock.

Reason is optional for the return. A blank reason is saved as Not specified, including when Other is selected without details. Existing meaningful selected/typed reasons remain unchanged. No per-IMEI reason editor is introduced.

Unknown IMEIs retain the existing return-before-IMEI-entry workflow: the row explicitly says that ownership could not be confirmed, uses Not recorded for its batch, and is highlighted in amber. No batch is invented. Existing save-side receipt/quantity/parts checks remain authoritative. Known IMEI2 resolves its canonical phone; listing both identifiers for one physical phone is blocked.

The new read RPC returns only IMEI, canonical IMEI, receipt identity/original quantity and status/reason. Supplier/customer names and unrelated phone details are not returned. It requires the existing Return Stock entry permission and approved office connection when Office Only applies. Anonymous calls and direct access to the private implementation are denied. The public version marker checks exact function hashes, ACLs and the office/capability mappings.

This additive migration does not change business rows or the existing atomic return/save functions. Install SQL when the matching Publish-GreenLoop-Return-Stock-Check.ps1 script copies it to the clipboard. Supabase SQL Editor > NEW query > paste directly > RUN the complete SQL. Expected final result: installed_return_imei_stock_check_version = 20261111-return-imei-stock-check-1. Then return to PowerShell and press Enter. No Edge Function, JWT, secret or new permission tick is needed. After LIVE - VERIFIED, Ctrl+F5.
