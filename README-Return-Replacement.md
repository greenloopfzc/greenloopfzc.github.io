# Return/Replacement

Sidebar Stock Return is renamed Return/Replacement. The same page opens two cards: Stock Return and Stock Replacement. Existing return entry, permanent history and approval/handover workflows are retained.

Replacement workflow: choose Supplier, original Stock/Batch and completed return; enter replacement quantity and save. A new, linked receiving receipt is created atomically. Original received quantity and returned phone history do not change. Receive 1 against 2 returned phones and the report shows 1 received / 1 pending. Multiple deliveries are supported; quantities cannot exceed unsettled, active returned units. Credit/refund and earlier settled returns do not become new replacement entitlements.

Open the new receipt in IMEI Entry to read/scan its new phones. Existing dual-IMEI checks and the normal Initial QC process apply. No phone is invented, restored from the old returned identity or moved straight into Ready Stock. The replacement report shows original stock and return references, replacement receipts, new phone details, received/pending quantities, optional date/search filters, portrait PDF preview/download and Excel.

User Access > Return/Replacement has separate View Stock Replacement, Receive Stock Replacement and Replacement PDF / Excel ticks. Existing grants are preserved; Owner/Super Admin accounts with this page get the new actions during installation. Other users need explicit grants. Supplier names remain confidential. Server-side action grants, Office Only checks, immutable audit links, locked remaining quantities and idempotent retries are enforced. Existing settled records are not re-received automatically.

Run the PowerShell publisher. It first verifies existing installations, then copies the additive Stock Replacement SQL if missing. In Supabase SQL Editor run the complete clipboard query. Required result: installed_stock_replacement_version = 20261104-stock-replacement-1. No new Edge Function, JWT change or secret is needed. After LIVE - VERIFIED, use Ctrl+F5.
