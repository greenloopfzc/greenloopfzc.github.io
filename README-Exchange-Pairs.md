# Stock Replacement: one exchange per row

The Stock Replacement report now shows returned and replacement phones side by
side in one row. One S.No identifies one exchange. Returned IMEI/Model/GB/Color
have a pale red background; the exact linked replacement has pale green cells.
An arrow separates them, and original supplier/stock/invoice appear once. Pending
replacement cells remain gray with an explicit status. Dates have no time component.
Each IMEI and Details opens the read-only popup, authorized by replacement_view
without granting Accounts, Reports, IMEI Search or any write permission.

The server groups by supplier_returns.id. Duplicate, missing or inconsistent
identities fail closed. Missing returned IMEI stays Not recorded plus its own
return reference; its saved replacement link is retained. The actual old/new GB
is preserved. Model prefixes such as iPhone14 Pro are normalized for display only.

Migration305 adds paginated exchange_rows and an exchange snapshot to the existing
history reader while preserving its legacy phone_rows, totals and old snapshots.
The new protected report API exposes50 complete exchanges per screen page and a
complete snapshot-checked download. A current note/date/link change invalidates
the exchange export. The installer changes read routines/metadata only, preserves
earlier integrity receipts and leaves all business data/access assignments intact.
Success marker: `20261113-exchange-pairs-1` after verified Stock Report Links304.

PDF and Excel use one row per exchange, separate old/new colored cells, shared
stock identity and both actual dates. PDF pairs stay together on one page. Long
notes get a compact table reference and a full Exchange Notes appendix so no notes
are discarded or pair broken. Excel contains full notes with adaptive column/row
sizes and separate returned/replacement/date/status fields. Normal and60-pair PDF
outputs were rendered and visually checked, including the long-note appendix.

Validation uses actual public save/read/correction/popup APIs and real browser
page code with the shared RPC guard/catalog. Cases include256GB return/128GB
replacement, missing old IMEI, exact-ID links, pending status,50+10 complete pairs,
complete export, stale export denial, unauthorized read denial, old API
compatibility, current per-phone notes, read-only behavior, mobile containment and
stale popup cleanup. Windows CRLF atomic rollback/per-statement repeat leaves stock
and user snapshots unchanged. No live SQL or Git push was executed by Codex.
