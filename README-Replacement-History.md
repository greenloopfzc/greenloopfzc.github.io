# IMEI Search replacement history

Search either a returned or replacement IMEI in IMEI Search. The history shows a Return / Replacement History section: Returned IMEI in red, Replacement IMEI in green, with their exact saved pairing. The same section appears in the bulk results' Open history dialog. Replacement chains show both immediate links on a phone which was itself returned and replaced again.

Original batch with original receipt quantity, invoice, supplier code with original receipt quantity and received date are shown when available. Missing values are not invented. Supplier/customer names are not returned by this new read-only endpoint. IMEI identifiers retain the selection/copy exception.

The section reads existing permanent matched-pair and legacy allocation records; it does not rewrite operational history, receive a replacement, change a stage, grade, stock quantity or return. Phones without a replacement link show their normal history. If the replacement lookup fails, the phone history remains available with an explicit retry message and no stale pairing.

Run `outputs/Publish-GreenLoop-Replacement-History.ps1`. Earlier installations, including Original Stock Replacement, are verified first. When requested, run the complete clipboard SQL in a NEW Supabase query. Expected result: `installed_imei_replacement_history_version = 20261111-imei-replacement-history-1`. After LIVE - VERIFIED, refresh with Ctrl+F5.

One atomic installation statement plus a final version query avoids temporary-table lifetime dependencies. The existing IMEI Search View permission and Office Only boundary protect the new RPC. No new permission tick, Edge Function, JWT setting or secret is needed. Previous updates and publish integrity checks remain in place.

Validation: isolated PostgreSQL first/repeat LF/CRLF install and late rollback; original business and audit snapshots unchanged; exact old/new and IMEI2 lookup; legacy pairings; reservations awaiting intake; optional different color; replacement chains; view-only access and missing-permission, anonymous, private-table and Office denials; prior version seals. Chromium light/dark/mobile checks cover single search, bulk popup, missing/error results, stale-response and Office clearing, original quantity labels, identifier markup and no writes or browser errors. Publisher source/bundle pins and stubbed deployment failure paths are checked separately; Codex performs no live deployment.
