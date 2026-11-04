# Stock consistency and bulk IMEI lists

Pending Parts Prices groups by original receipt, model, part, source and currency.
GB and color no longer split groups or appear in the main price table/filters.
Per-phone detail/history preserves both values. Existing price locks, exact issue
membership, idempotent saves, source splits and price permissions remain.

The shared supplier label uses the receipt's original quantity: SUP-06-(342).
Names still require the existing name-view permission. Supplier-only pickers may
list the separate receipt quantities; no unknown original quantity is invented.

Relevant receipt/stock reports show received, completed returned, received
replacements and balance. Balance = received - returned + replacements. Pending
returns are shown separately. Selecting an original receipt and its replacement
receipt together never counts replacements twice. Grade/work tables retain their
selected receipt scope; the receipt summary includes its replacement family.
Stock Grade & Work Analysis includes these totals on screen and portrait PDF.
Accounts, supplier progress, receipt search, Returns/Replacement and Stock Parts
Cost also use the shared receipt summaries. Independent Available Stock counts
and ready-phone quantities retain their own business meaning.

Bulk Excel IMEI columns work in IMEI Entry, Initial QC, Lab & Glass Issuance,
Lab workbench, Final QC, Lab Bulk Transfer, Ready Stock rework and Box Entry.
Search/report inputs can match all pasted IMEIs, including Parts, B-DEPT and
IMEI Search. Remote filtered lists fetch every matching page. Invalid/duplicate
values are reported. Each workflow retains its native save, receipt capacity,
current-stage and permission checks. Pasting does not complete QC or handover.
Box Entry scans retain their native immediate draft-box scan behavior. IMEI
Entry honors its existing Auto Save setting once all required fields are valid.
A subsequent scanner read replaces the previous IMEI/list.

Large Lab handovers stage all phones and submit verified, idempotent batches of
up to 500. If a later batch fails, completed batches remain confirmed and the
remaining list is retained for recheck/retry. Ready Stock rework keeps its native
per-phone results and Stop/retry behavior.

The installation adds migrations 246 and 247 and reseals only reviewed readers.
It changes no business records at installation. Existing QC Issuance (245) is
required; the publisher can include that migration if its preceding Reports
Permissions installation verifies. No Edge, JWT, secret or permission tick is
required. The user runs the prepared publisher; tests use disposable fixtures.
