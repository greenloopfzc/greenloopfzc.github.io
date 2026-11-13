# Stock Return capture permission mapping

Stock Return submits `record_stock_return_with_capture_v1` so cable identity details remain attached to the saved return. The runtime RPC permission catalog did not contain that newer write function. The shared client correctly rejected it as an unmapped write, producing the reported permission-mapping error before any server request.

Both runtime catalog mirrors and the JSON catalog now map this exact function to `supplier_returns / entry`, matching `record_simple_stock_return`. The Stock Return page loads the updated catalog with a new cache version. The generic unknown-write block, view-only behavior and server authorization remain intact. No return workflow, stock eligibility, export eligibility, receipt, quantity, identity, idempotency or database routine changes are made. No new SQL is required for this fix; the publisher retains the preceding installed database checks.

Chrome validation uses the actual supplier-return form, capture preparation, page-capability resolver and shared config RPC guard. It reproduces the old error before a server write, confirms both prepared IMEIs remain, then loads the corrected mapping and checks the real capture RPC payload, identity details, retry key reuse, successful form clearing, and denial for view-only, unrelated entry grants, no access and unknown write functions.

Synthetic PGlite validation invokes the actual server RPC for two eligible Final QC phones against a 342-unit original receipt. Exactly two returns are saved, replay is idempotent, original receipt quantity and phone/job row counts are preserved, unauthorized staff and wrong-stock submissions are rejected, and cable identity capture remains valid. No live return or stock changes were made by Codex.
