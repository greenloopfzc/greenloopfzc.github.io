# Work Options and IMEI Auto Save

Prepared 28 October 2026. Live deployment is verified only by the publisher's final green result.

Initial QC and Lab & Glass offer the most-used saved Parts and Services first, separately. Equal counts sort alphabetically. Each nondeleted phone counts once per name across requirements, requests, saved services and repair cycles; quantities do not multiply popularity. Supplier Grade and GC Grade retain their own ordering. A private shared 15-second cache avoids a full history rebuild on each workbench refresh; updated rankings appear on the next ordinary list refresh. Existing selections, quantities, open phone cards, Lab clocks and routing remain intact.

IMEI Entry: switching either Auto Save toggle ON also checks rows already completed. Valid bulk rows save sequentially after a 650 ms pause. Both toggles and ON/OFF labels stay synchronized. OFF cancels queued work; a save already sent to the database can finish. Incomplete rows explain what is missing. Manual Save remains available when OFF. Battery Health 0–100 is accepted, including single-digit values; estimated cable readings still need review. Android Not available, duplicate checking and private IMEI2/serial cable identity are preserved. Permission and selected receipt are checked again after the network duplicate check, before any write.

Run outputs/Publish-GreenLoop-Work-Options-Auto-Save.ps1 in Windows PowerShell. It verifies pinned code and preceding database versions, copies only required cumulative SQL, waits for installed_work_option_usage_version = 20261028-work-option-usage-1, then publishes without force pushing and verifies all live files. No Edge Function or JWT setting change is required. Refresh with Ctrl+F5 afterwards.

Checks: native disposable PostgreSQL, browser integration of dropdown ranking/drafts/permissions, bulk and single Auto Save cases, source mirrors/syntax, installer hashes and isolated publishing rehearsals. Tests do not write to the live database or GitHub.
