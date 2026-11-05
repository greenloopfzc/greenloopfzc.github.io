# Compact Issuance row editing

Lab & Glass Issuance > load an IMEI > Edit. The Parts Needed and Service Needed
cells become dropdown lists styled like Initial QC, each with plus/minus.
Change the selected part directly, add another dropdown with plus, or remove the
last selection with minus. Save and Cancel stay in that phone's Actions cell.
No separate editor panel opens and no quantity input is shown. New parts use
one unit for the IMEI. Existing business quantities are not reset by this layout
update. Saving and transferring remain separate actions.

The existing guarded, revision-checked Issuance Edit API is retained. Audit,
updated reports and Lab / Parts handover, permission checks, retries and stale
edit protection remain. Dropdown options are cached briefly between edits and
invalidated by Refresh or a managed-option storage change. Errors stay on the
same IMEI line; canceled or failed saves retain the correct saved/draft state.

Frontend-only update; no additional SQL, Edge, JWT, secret or tick. The publisher
checks the preceding Issuance Edit installation and includes its existing SQL if
missing. Existing 50-record report pagination, full downloads, bulk paste /
scanners, separate QC / Issuance badges and supplier labels remain.
