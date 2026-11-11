# Stock Replacement: match new IMEIs within the original batch

Version: 20261111-replacement-auto-match-1

Return/Replacement > Stock Replacement now starts with a supplier identity (base code and authorized name only) and original receipt/batch. Batch labels show that receipt's original quantity. Report supplier labels use the correct receipt quantity, never another delivery's or a model subgroup's quantity. Return, replacement and pending figures remain separate.

Choose supplier and original batch. Enter the default Model, GB and Color, then scan new replacement IMEIs or paste an IMEI column. Mixed phones can be pasted as Excel columns IMEI, Model, GB, Color. All prepared rows stay visible in the entry tray, with editable fields and Remove. Replacement quantity comes from this list. A transaction supports up to 1000 phones; an oversized paste is retained with a message rather than silently shortened.

Check matches previews the old/new IMEI pairs without saving anything. Matching is restricted to completed, unsettled, unallocated returns in the selected supplier receipt with the same Model, GB and Color. The oldest matching return is used first. iPhone prefixes, spacing and letter case are normalized. Storage must match in GB; the form accepts GB/TB text. Duplicate, existing, reserved, mismatched or unavailable IMEIs appear as red rows and prevent Save. Missing original model/storage/color is not guessed.

Receive Replacement explicitly saves the reviewed pairs atomically, creating replacement receipts against their original completed return groups. It reserves the new IMEIs and records the old/new mapping. If the original batch contains several return groups, one normal replacement receipt is created per matched group. There is no mandatory Completed Return selector. Notes are optional.

Open the generated replacement receipt in normal IMEI Entry to receive the reserved phones, read cable details/BH and continue Initial QC. This screen does not create a device/job before normal intake. The receipt accepts only its reviewed identities and matching details. The pairing remains exact even when new phones are entered in a different order; historical returned phones and original receipt balances remain linked. Existing older replacement receipts keep their native intake behavior.

Report tables show 50 return groups per page with Previous/Next and visible ranges. Complete selected PDF/Excel downloads are independent of screen pagination and include saved old/new pairs and Awaiting IMEI Entry / Entered status. S.No is leftmost. Existing replacement entry/view/download permissions, name privacy and Office Only restrictions remain in force. No new permission tick is required.

Installation adds private immutable reservation/audit tables, guarded RPCs and a narrow intake trigger. Installing/reinstalling changes no business records. Existing functions and version checks remain intact. Atomic retries prevent duplicate receipts; stale previews, changed return settlements or metadata must be checked again before saving.

Run outputs/Publish-GreenLoop-Replacement-Auto-Match.ps1. The script verifies its source, earlier database installations and Git ancestry, then copies required SQL only when missing. Paste the clipboard directly into a NEW Supabase SQL query and RUN the whole query. Required final result: installed_replacement_auto_match_version = 20261111-replacement-auto-match-1. Return to PowerShell and press Enter only after that result. No Edge deployment, JWT change, secret change or Cable Reader restart. After LIVE - VERIFIED, Ctrl+F5 > Return/Replacement > Stock Replacement.
