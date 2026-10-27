# iPhone entry choices and storage

Version: 20261027-iphone-entry-options-1

Daily Production and IMEI Entry sort storage by numeric capacity: 64 GB, 128 GB, 256 GB, 512 GB, 1 TB, 2 TB. Existing custom capacities remain in their numeric position. Unknown legacy labels follow recognized capacities. Daily Production IDs, saved selections, voice choices and historical entries are retained.

Single and bulk IMEI entry display TB labels and submit whole GB: 1 TB = 1024 GB; 2 TB = 2048 GB. Adding a storage choice accepts labels such as 1 TB or 128 GB and stores the native integer convention. Cable readings and planned receipt lines use the same normalization. Invalid storage is blocked before intake. The existing manual/automatic save choice, dual IMEI checks and receiving batch links remain intact.

At installation, all active Daily Production model names are added to IMEI Entry, including custom active names. Existing IMEI choices remain available. This is an installation copy, not continuous cross-page synchronization. No historical model strings are rewritten.

The color catalog adds 45 official color names across iPhone generations, retaining existing custom choices and IDs. Catalog provenance: Apple Identify your iPhone model (https://support.apple.com/en-us/108044) and iPhone 5 Technical Specifications (https://support.apple.com/en-ie/112016), checked 27 October 2026. The color list is in permissions/iphone-entry-catalog.json. Colors are general selectable choices; this update does not enforce model/color combinations.

The installer records seeded names so replay does not restore choices subsequently removed through Manage Options. It preserves existing records, production quantities, permissions, Office Only checks and private data boundaries. The new read API requires IMEI Entry View permission; option changes retain the existing Manage Options server checks.

Validation: disposable PostgreSQL with migrations through 207; native 1 TB/2 TB intake, receipt links, options, replay, privacy, View Only/Office/TV checks and earlier version receipts; 12 browser cases covering single/bulk entry, cable reading, adding storage, numeric order, selection preservation and mobile dark mode; JavaScript syntax and root/js mirrors.

Run outputs/Publish-GreenLoop-iPhone-Entry-Options.ps1 from the chat workspace. The publisher selects the necessary SQL, verifies the database, safely publishes the pinned source and compares live assets. Required final SQL result: installed_iphone_entry_options_version = 20261027-iphone-entry-options-1. No Edge Function or JWT setting change is needed. Local validation does not confirm live installation.
