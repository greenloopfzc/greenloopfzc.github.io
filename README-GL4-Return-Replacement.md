# GL4 Return / Replacement

12 November 2026. Built on 65c0f7b (Ready Stock Color), in an isolated worktree.

Stock Replacement selects supplier identity, then the canonical original stock. Manual/cable phone rows capture model, GB, optional color, battery, serial and region. IMEI2 stays in the payload only. Cable handoff never submits. Editing IMEI clears its bound cable identity. Save atomically allocates the oldest compatible unresolved completed return, creates the phone/job at Initial QC in the original batch, and preserves supplier/invoice/original quantity. Private immutable allocation IDs are audit records; no receiving batch or business invoice is created. Existing duplicate identity guards and exact original-stock validation remain in force.

History has red returned rows and green replacements directly below, sharing one leftmost S.No. Server pagination is 50 physical rows; PDF/XLSX fetch complete snapshot-matched phone history separately. Return history uses a server-paged phone table. Existing Reports exports remain independent. Other work trays and Parts selections are untouched.

Install `20261112_291_direct_replacement_intake.sql` using Supabase SQL Editor. Prerequisites: verified Original Stock Replacement (288) and IMEI Replacement History (289). The installation is one atomic DO statement, verifies prior markers, updates only matching existing definition seals, and publishes `20261112-direct-replacement-intake-1`. Repeat installation is supported; altered installed definitions stop it. Existing linked legacy replacements are repaired through the previously reviewed `sro_rehome` guard; ambiguous ownership, returns or box assignments cause rollback. No records are deleted or merged by labels. Original receipt quantities are not edited.

New private return-capture records preserve cable metadata even for an unentered returned phone, so model/GB matching can use captured facts. Known phones use the existing dual-IMEI/serial identity writer. Capture/replacement failures roll back atomically. Legacy reservations without captured phones remain identified as pending intake rather than fabricated as completed.

Validation: isolated PGlite business-workflow tests, Chromium interaction fixtures, actual PDF/XLSX generation, JS syntax and root/js/css mirrors. No live Supabase business data or physical phone was accessed in GL4. GitHub DNS was unavailable; publication must check remote ancestry and live assets. The publisher never force-pushes and never installs SQL automatically.
