# Accounts and Export Data reports

12 November 2026. Built on 66b52b6.

Supplier Stock and Customer Stock now offer PDF View, Download PDF and Download Excel under the existing Accounts Print grant. IMEI Data retains its independent imei_download grant. Box Entry, saved Box Status details and Stock Exported offer the same three report actions under their existing Print grants. Stock Exported also downloads all phones in all filtered boxes.

Dates stay visible (11 Nov 2026); time is removed from Accounts, export and report presentation. Device Number columns are removed from export detail/print, report audit tables and phone-history display. Internal identifiers, timestamps and business records remain intact. Shared table cells are centered horizontally and vertically. Accounts IMEI and return/replacement PDF/Excel cells and new reports use centered alignment.

Screen stock tables retain 50-row pages. Explicit stock downloads fetch every filtered page twice and reject inconsistent or partial reads. Names remain permission-controlled; IMEIs and formula-looking values are literal spreadsheet strings. New PDF previews close on lock, sign-out or permission change. Report downloads do not confirm printing, save boxes or verify Accounts.

Validation: isolated Chrome fixtures for supplier/customer, Stock Exported, Box Entry and Box Status; 51-row full stock versus 50-row screen; 141-row IMEI PDF/Excel; denied/revoked access; partial/changed-read rejection; Unicode multipage PDF; PDF raster review; centered CSS computed styles; syntax and mirrored assets. No live database writes or deployment were performed. No SQL migration is required.
