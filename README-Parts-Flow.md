# Finalised Parts workflow

Version: 20261026-parts-flow-1. Requires the verified Lab Delay database (20261024-lab-delay-1). No Edge Function, JWT or secrets change is required.

## Day-to-day flow

1. Initial QC's parts/quantities and services appear in Lab & Glass. The technician may add/remove requirements, adjust part quantities and send the final list to Parts. Subsequent edits update that same versioned order until the first issue.
2. Parts appears immediately after Lab & Glass in the sidebar. Inventory remains outside the sidebar. Each order row opens its phone details, parts, services, returns and history. Search/dates/status live inside Filters; headings sort and the queue paginates.
3. Parts can issue a partial or full quantity. Optional AED unit price may be blank (Not entered) or an explicit zero. After the FIRST issue, the ENTIRE parts and services list is locked. The Lab add/remove controls disappear. Stale screens cannot issue a different/older requirement version.
4. Services have Pending / Confirmed / Completed statuses controlled by Parts Edit permission. Lab completion waits for part issuance, service confirmation and all pending return reviews. Job Completed sends the phone to Final QC and records completed service statuses.
5. Lab requests a return against an actual unused issue, with quantity and notes. Parts chooses Not Needed, Damaged or Faulty and approves/rejects it. Pending return quantities are reserved against double requests. Not Needed becomes usable stock only after approval. Damaged/Faulty quantities do not become usable stock. Parts may select Replacement required, which adds precisely that returned quantity to the same part's remaining requirement.
6. Existing pending returns have a separate compact review table. Their original issue/return records are retained. Existing issued active phones receive private tracking records so their lists are locked immediately. Historical manual-part records are retained and shown as earlier records rather than requested again automatically.

## Issue source and price privacy

Supplied part records a direct physical issue without a prior Inventory receipt requirement. It does not deduct an unrelated inventory lot. Its approved usable returns accumulate in a named return-stock lot. Available matching existing lots and usable-return stock are optional sources; selecting a lot atomically deducts its quantity.

Actual optional NEW issue prices are stored only in a private, RLS-enabled table without anon/authenticated grants. Only the Parts detail API, protected by Parts View, returns them. Lab APIs, shared device events, public audit payloads and public issue/install/return ledgers contain no actual new price. Public stock ledgers use a zero placeholder; other financial reports do not include these restricted new prices. Pre-existing historical costs are preserved rather than repriced or erased.

## Access

- Lab & Glass View: requirements/issued quantities/returns, without prices.
- Lab & Glass Entry: finalise/update an unissued list, request a return and complete a ready phone.
- Parts View: queue, details, recorded prices and history.
- Parts Issue: quantities, optional price and issue action.
- Parts Edit: service statuses.
- Parts Return / review returned parts: approval/rejection and classification, including older pending returns.
- Search and Sort retain their separate existing ticks. No user receives new grants automatically.

View Only, TV Only, Office Only and active-staff checks remain enforced at the database. Old issue/manual/completion paths cannot bypass the finalised flow. Private transaction capabilities guard managed request, issue, service and installation writes. Recorded continuous Lab/Glass visits identify separate repair cycles; technician reassignment and internal Lab/Glass movements do not reopen an issued list. An authorised rework starts a fresh order while preserving earlier history and prices. Existing protected IMEI reset retains its preview, code and selection-token checks and receives a scoped private capability for cleanup; no deletion runs during installation.

## Installation

Run Publish-GreenLoop-Parts-Flow.ps1. When prompted, paste the clipboard SQL into a NEW Supabase SQL Editor query and RUN the complete query. Required final result:

installed_parts_flow_version = 20261026-parts-flow-1

Return to PowerShell and press Enter only after that exact result. The script verifies installed versions, safely pushes the pinned tested commit without force, and verifies published assets. After LIVE - VERIFIED, Ctrl+F5 the working PCs so they use the new screens. No Edge/JWT step is requested.

Local verification uses a disposable PostgreSQL engine and isolated browser fixtures. Live installation/deployment is pending the publisher run.
