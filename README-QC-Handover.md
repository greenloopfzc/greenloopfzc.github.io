# Initial QC technician handover sheet

Release: 20261030-qc-handover-1

Initial QC now offers Print, PDF View and Download PDF below the work tray. Outputs use A4 portrait. The heading includes technician name, prepared date/time in UAE and total phones. Each phone row contains IMEI 1, model, storage, color, required physical parts with quantities and services/work required. Supplier/customer names, prices and secondary device identifiers are not included.

There are no selection checkboxes. Each successful Initial QC save is captured once by job ID in a private in-memory page-session list, including individual Save and bulk completion. Failed saves and unsaved rows do not enter that list. A page refresh or new page load begins a new list; the database records remain saved. Clear tray and Auto pick do not reset the session handover list. Save fields, grades, technician name and work requirements are snapshotted at submission time.

Every output validates the complete session list. Different technician IDs block all three actions and show an English warning naming each technician and phone count, for example: "This list contains different technicians: Lu - 8 phones, Akram - 2 phones. Please check the technician assignments before generating the sheet." Unassigned phones also block sheet generation. No technician correction or database write is performed by printing/exporting.

The existing Initial QC Entry permission controls this session-only feature. Saves in progress block output; a list change during PDF preparation invalidates the result. PDFs use the existing local pdf-lib asset, loaded on demand. PDF View provides an embedded preview, Open PDF and Download PDF. Object URLs are revoked when previews close/change. Office locking clears the session list and preview, including when the page body has already been replaced by the access lock.

PDF text wraps within cells. Headers and technician names repeat on subsequent pages; long single-phone work lists can continue across pages, and there is no fixed page cap. Print uses an escaped HTML sheet with A4 portrait print styling. Unsupported PDF font characters yield an explicit message and preserve the entries; browser Print remains available.

No SQL, schema, Edge Function, JWT or workflow routing change is required. Existing Initial QC sends physical parts directly to Parts alongside the Lab route; services and the existing technician assignment remain unchanged. This cumulative package includes previous permission fixes and Lab phone card updates.

Validation: 12 browser cases covering ten same-technician saves, 8/2 mixed warning for each output, unassigned phones, partial bulk failure, save locks, tray clear, page refresh, printing, mobile dark mode, View Only, office lock and PDF load failure. PDF tests inspect five portrait sample outputs, including a handover exceeding four pages and long continued work lists. Tests use fixture data only. No live QC entries or assignments were created.
