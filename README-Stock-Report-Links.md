# Supplier Progress and linked return reports

Supplier Progress reads canonical original stock receipts. Legacy replacement
allocation batches stay stored for audit/capacity but do not appear as separate
stock selections. Original stock quantity and original entered IMEIs exclude
replacement intake; the original unentered remainder stays independent. Workflow
counts include replacement phones. Replacement IMEIs entered have their own table
column. Unentered supplier returns remain visible and count once. Supplier selectors
show the supplier identity; stock labels and phone rows retain the original quantity.
Directly opening Supplier Progress now loads its data.

Accounts IMEI DATA's Returned card includes linked replacement phones alongside
the matching returned phones. The card remains a return count, while the heading
states returns and linked replacements separately. A different-GB child remains
visible with its parent even when the parent's Model/GB/query filter differs from
the replacement. Pairs sort together before50-row pagination; complete PDF/Excel
downloads use the same selection and include old/new links. Stock totals, current
phone specifications, original receipt quantity and immutable business history are
preserved. A linked return can still show its pending intake IMEI in the relationship
column and popup before that new phone is entered.

Clickable IMEIs in Accounts and the Supplier Progress return detail table open one
read-only popup. It shows current phone/stock details and red returned/green linked
replacement lines, actual old/new GB, grade, dates, stage and current individual
return reason/notes. Missing IMEIs use their exact return record. It does not perform
a correction or movement. Independent server checks require Accounts view + IMEI
DATA, or Reports view + Supplier Progress, plus office access. IMEI Search access is
neither required nor granted. Names retain their separate privacy permission.
Closing, lock, sign-out, access changes and workflow commits clear the popup and
invalidate pending responses. Invalid/moved records fail closed.

Migration304 is one atomic installer, tested with Windows CRLF, late-failure
rollback and repeat installation. It changes read routines/metadata only and
preserves preceding integrity receipts. Result: `20261113-stock-report-links-1`.
The local publisher verifies this and preceding database versions before publishing.
Codex did not execute live SQL or push to GitHub.

Validation covers actual public report/details/save/correction APIs, legacy receipt
selection failure and original pending-count reconciliation,256GB return/128GB
replacement, exact links, current per-phone notes after a Reports correction,
permission denial, stale exports,50+11 pagination, complete exports, actual shared
browser RPC guard/catalog and both real page components. PDF output is rendered
and reviewed for normal and60-row cases with old/new links inside paper margins.
