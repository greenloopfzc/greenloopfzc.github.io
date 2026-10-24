# Box Status and Accounts Recheck

Version: 20261024-box-recheck-1. Requires the verified Office Access database already used by this checkout. No new Edge Function, JWT, user roles or permission grants are required.

## Workflow

Box Entry has two raised cards: Box Entry and Box Status. Box Entry retains its current open box, scanner, printing and Save flow. Box Status lists previously saved boxes with Box number, quantity, saved date, status and verification date. From/To and status/search filters are inside Filters; headings provide sorting. Saved-date boundaries use Asia/Dubai. A resubmission keeps the saved date and records a separate last-sent timestamp. Older closed boxes retain their Historical label; they are not declared verified or returned automatically.

Accounts retains mandatory customer selection for Verify Box. The same authorised verifier can instead select Send for Recheck and enter a required reason. The existing box number is retained. The returned box disappears from the verification queue until it is resubmitted and remains reserved, outside Ready Stock and Stock Exported.

Box Status opens the returned box with its reason. An operator with Box Entry Scan permission can remove an incorrect IMEI (returning that phone to Ready Stock) and scan the correct Ready Stock IMEI into this same returned box. This does not alter the separate current draft box. Model/GB/grade/color remain loaded from the selected phone; changes to canonical device details continue through the existing authorised Reports > Export Boxes > Box Correction flow and its correction code. Those source changes keep a returned box in Recheck and invalidate its prior print.

The corrected revision must be printed and explicitly confirmed before Resend to Accounts. Accounts then reviews it again and selects a customer before verification. Recheck/correction/resend can repeat until verification succeeds. Verified and historical boxes are read-only in Box Status. Changes, decisions, membership changes, printing and resubmission retain audit records and device journey events.

## Existing permission ticks

- Box Entry View: list and open saved boxes.
- Search & date filters: search, dates and status selection.
- Sort records: heading sorting.
- Scan IMEIs into boxes: remove/rescan returned-box membership.
- Print: print and confirm the corrected revision.
- Save box to Accounts: resend a returned box.
- Accounts Verify boxes for export: verify or request Recheck.

No existing user receives extra permissions. View Only and TV Only users cannot mutate boxes. Office Only is enforced on every new API through the existing trusted network boundary. New APIs are registered in the Office guard and permission-rule receipts. No business records are changed merely by installing this migration.

## Integrity

Mutations use the existing export workflow advisory lock plus box/workflow row locks and an expected revision. A stale Accounts tab cannot verify a returned/corrected box. Empty, unprinted or subsequently changed revisions cannot be resubmitted. Secondary IMEIs and phones already boxed/unavailable in Ready Stock are rejected. Removing a phone follows the existing Ready Stock restoration semantics. Correction source triggers retain Recheck until explicit resubmission. Migration replay preserves box states, lines, decisions and user access.

## Installation

Run Publish-GreenLoop-Box-Recheck.ps1. It verifies the pinned checkout, checks GitHub history before installation, confirms the existing Office Access versions, copies the new complete SQL only when its marker is missing, verifies installed_box_recheck_version = 20261024-box-recheck-1, pushes without force and compares published assets. No Edge service deployment is requested.

Local verification uses a disposable PostgreSQL database with the previous migration chain plus isolated browser fixtures. Live business data, physical printed sheets and the deployed website are not claimed verified by local preparation.
