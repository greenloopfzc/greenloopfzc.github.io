# Lab and Parts action permission mappings

Fixes the browser error: "The permission mapping for this action is missing."
The shared client failed closed before sending new Lab/Parts write RPCs to the existing database. The database checks already existed; the browser catalog lacked their newer names.

49 explicit Lab/Parts rules now match existing backend requirements. This includes additional and original part orders, issue with Local/China source, bulk issue, returns/review, Lab services and Job Completed, employee assignment, pending prices and the associated readers/downloads. Forty-two rules match the existing native capability registry exactly; seven newer wrappers use their reviewed explicit backend checks (Parts Issue or Lab Entry). Existing grant values are not modified. Unknown writes still fail closed; Lab Entry does not grant Parts Issue and Parts Issue does not grant Lab Entry.

Every HTML page using the shared RPC catalog requests its new version, including Lab & Glass and Parts, so stale cached mappings are replaced together. No layout, existing phone, request, issue, price, stock, return, history, employee or account data changes are included. Server duplicate/replacement rules and Office Only checks remain in place. The cable review and 60 x 40 mm labels from the previous release remain unchanged.

## Publish

Run outputs/Publish-GreenLoop-Parts-Action-Access.ps1 in the original workspace. This is a frontend-only repair. No NEW SQL, Edge Function, JWT setting, secret or User Access permission tick is needed. The publisher still checks existing prerequisite installations and stops rather than overwriting a newer remote branch. After live verification, press Ctrl+F5 in both Lab & Glass and Parts. Retry the additional order, then issue it from Parts.

## Validation

- Reproduced the missing-mapping error for permitted accounts before the fix.
- 49-rule matrix, 42 exact native server rules, unmapped-write protection and cross-page grants checked.
- 294 calls through the real browser client guard across six grant profiles; denied calls never reached transport.
- Nine Initial QC / Lab UI cases: additional order, pending cancellation, issued-part protection, return/reorder, view-only and mobile dark layout.
- Ten Parts UI cases: normal issue with source wrapper, return review, queues, supplier/batch metadata, search/filters, legacy returns, missing metadata and view-only/mobile dark.
- Source mirrors, cache versions, publish package hashes and four publisher rehearsals checked separately.

Local tests do not claim a live website publication. No real customer/workflow records were modified by test fixtures.
