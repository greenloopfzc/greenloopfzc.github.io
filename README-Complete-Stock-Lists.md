# Complete stock lists

Supplier identity choices show only the supplier code and permitted company name.
Receipt labels use the specific original receipt quantity; a new 300-phone
receipt generates SUP-01-(300), preserving previous deliveries independently.

Permitted paginated report readers automatically collect all matching pages.
Applied filters/sorting and server permissions remain in force. No Next or
Previous action is needed. Existing scanner trays keep all valid pasted lines;
repeated IMEIs remain visible as blocked lines rather than disappearing.
Phones at another stage stay there and show the current stage. Nothing saves
or completes QC merely because an IMEI list was pasted.

Accounts IMEI DATA uses S.No, IMEI, Model, GB, Color, Supplier, Stock/Batch,
Invoice No and Date Received on screen and in portrait PDF and Excel. Entire
returned rows are red. Actual replacement phone entries are linked to the
native return allocations and grouped in green beneath the original S.No.
Original return rows and history remain. Selecting an original invoice/batch
includes its entered replacements. Nested replacement links preserve the root.

Tables receive serial numbers without shifting existing action-column indexes;
Lab phone cards display their serial in the card header. Existing numbered
trays retain their own numbering. Core PDFs and spreadsheet/CSV exports also
include serials. Table filters and entry controls remain governed by existing
capabilities.

Parts picking no longer caps 50 groups or 200 pending requests. Review lists
include the complete selection. Confirmed issues travel in bounded batches,
keeping all requests for a phone together. Progress and confirmed partial
results are explicit. Native revision, inventory, source, price, return and
issue permission checks remain authoritative. Failed batches roll back and
stale retries cannot duplicate issued requests.

SQL 248 is additive. No reset, supplier cleanup, password, JWT, Edge deployment
or new permission tick is included. Use Publish-GreenLoop-Complete-Stock-Lists.ps1
and wait for LIVE - VERIFIED before Ctrl+F5.
