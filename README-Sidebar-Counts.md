# Sidebar counts

One permission-filtered aggregate read supplies 14 operational badges.

| Sidebar | Meaning |
| --- | --- |
| Stock Received | Original quantities in recorded receipts, including separately received replacement receipts |
| IMEI Entry | Receipt units still awaiting an IMEI entry |
| Initial QC | Inspection pending, excluding saved inspections awaiting issuance |
| Lab & Glass Issuance | Saved inspections awaiting transfer |
| Return/Replacement | Unique phones with requested/approved supplier returns |
| Lab & Glass | Unique phones with active Lab/Glass steps |
| Parts | Unique IMEIs awaiting parts issue or pending return review, counted once across both |
| Final QC | Unique phones with active Final QC work |
| B-DEPT | Unique phones with active B-DEPT work |
| Ready Stock | All currently eligible ready phones, including direct Initial QC releases; no date filter |
| Box Entry | Nonempty draft/recheck boxes |
| Accounts | Boxes whose workflow state is awaiting Accounts verification |
| Stock Exported | Distinct shipped phones in verified/exported boxes |
| Stock Journey | Distinct recorded phones in undeleted jobs |

Accounts > Verify Box uses exactly the same count as the sidebar Accounts badge, independently of date/search filters and 50-row table pagination. Draft, recheck, historical and already verified boxes are excluded. Resubmitting a recheck box puts it back in the Accounts count.

Exact counts are displayed, never 99+. Zero badges are hidden. Confirmed writes refresh immediately in the active browser; other tabs use commit tokens and a token-only Realtime signal. Office-only sessions retain their existing short polling fallback. Temporary count failures retain the last verified counts. Sign-out, office lock and permission changes clear counts safely.

Reports, settings, search and overview shortcuts have no invented pending counters. Counts do not grant access to a page or action, disclose names, or change a record.

Run outputs/Publish-GreenLoop-Sidebar-Counts.ps1. Run any copied SQL in a NEW Supabase query, then press Enter in PowerShell after its exact version result. Final new result: installed_sidebar_counts_version = 20261107-sidebar-counts-1. Wait for LIVE - VERIFIED and press Ctrl+F5. No Edge, JWT, secret or new permission tick is required.
