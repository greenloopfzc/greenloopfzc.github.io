# Specific returned IMEI and different GB replacement

Stock Replacement defaults to Specific IMEI. Choose the original supplier/batch,
add the new phone, then scan its returned IMEI or use Choose to select the exact
pending return. Bulk entry accepts IMEI, Model, GB, optional Color, Returned IMEI.
The pending-return selector searches and pages50 records without loading all pages.
Auto Match remains available and matches the oldest pending return with the same
Model and GB. Existing API callers without a matching mode keep Auto Match behavior.

The replacement Model must match the selected return. GB may differ. Receive
Replacement opens a comparison when any selected phone has different GB, including
an unknown returned GB. The buttons are **Approve** and **Rejected**. Approve sends
an explicit boolean approval for the changed lines. Rejected (or Escape) makes no
write and keeps the prepared entry. Equal GB needs no popup. A changed entry or
preview invalidates the review; repeat the review before saving.

The server independently requires approval, exact pending supplier/batch ownership,
matching Model, current preview and valid identities. Explicit targets are reserved
before Auto matching, cannot be assigned twice or reused after receipt, and are
locked during the atomic save. Retry of an identical successful request replays its
original result. Actual returned256/new128 specifications and links remain separate
in history and exports. The original receipt quantity stays unchanged; the new phone
enters Initial QC against that same original stock. Preview/selection never writes.

Apply migration303 after the verified current Return/Replacement prerequisites.
Successful result: `20261113-specific-replacement-1`. The installer is atomic,
repeatable and tested with Windows CRLF paste; it preserves previous integrity
markers and does not change saved stock or access assignments during installation.
The new pending lookup requires the existing replacement_entry grant and office
access; it grants no additional page or action. Root/js and CSS mirrors agree.

Validation: local PostgreSQL-compatible engine with all delivered prerequisites,
actual public preview/save/history APIs, old failure reproduction, approved256 to128
and128 to256, absent/false/string approval denial, duplicate/stale/foreign target
denial, Model mismatch, mixed Auto/Specific target reservation, original quantities,
idempotency, read-only permission denial and50+10 lookup pagination. Chrome verifies
the actual component and shared RPC guard, selection/scanning, exact popup labels,
Rejected zero writes, sameGB bypass, retry key, stale-response handling and mobile
scroll containment. No live database SQL or Git push was run by Codex.
