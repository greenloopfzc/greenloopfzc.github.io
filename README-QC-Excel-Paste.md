# Excel IMEI paste in Initial QC and Final QC

UI version: 20261104-qc-excel-paste-1. No new SQL, Edge deployment, JWT, secret or permission tick is required. Existing Accounts IMEI DATA and earlier database installations are verified by the publisher.

Copy the IMEI column from Excel, click an IMEI cell in Initial QC or Final QC, and paste. The list fills separate empty rows from that point; additional rows are created as needed. Existing nonempty, saved and loading rows are retained. Valid phones load their existing model, GB, color, BH and supplier details through the existing secured workflow. A single ordinary IMEI paste and barcode scanning retain their previous behavior.

The import accepts Excel line endings, tab-separated cells, optional IMEI column headings, quoted/text IMEIs and exact IMEIs separated by spaces, commas or semicolons. Leading zeroes are preserved. Scientific notation, decimals and incomplete values are rejected; format the Excel IMEI column as Text and recopy the full original digits. No digits are guessed or recovered from rounded Excel numbers.

Duplicates are skipped with a count. IMEI2 is rejected with its IMEI1 identity. Phones not waiting in the selected QC stage display their current stage on their row, with a review list and an optional current-location popup. A batch does not open a sequence of blocking dialogs. Identity/queue/network errors keep the pasted IMEI available for review and manual Enter-to-retry.

A compact result shows, for example, 20 pasted / 18 loaded / 2 need checking. Up to four phones load concurrently. Stop loading keeps completed checks and lets in-flight checks finish; remaining rows are marked not loaded. Another paste, tray reset or Save cannot interrupt the import. Office lock and sign-out stop further loading. Existing entry permission is required; view-only and dropdown-management-only accounts cannot import.

Initial QC imports do not save inspections. Final QC retains its existing receive-on-scan behavior; receiving a pasted phone records its arrival in Final QC but does not Pass, Fail, transfer or complete its inspection. Save/Complete remains an explicit user action. Existing technician/parts/services/grade defaults, Grade D Housing replacements, Final BH rules and individual Fail selections remain in effect.

Publishing: run outputs/Publish-GreenLoop-QC-Excel-Paste.ps1. CheckOnly validates the pinned local package; the normal command checks existing installations, publishes only against the verified history and compares all live assets. No live QC phone data was used in tests or changed while preparing this update.
