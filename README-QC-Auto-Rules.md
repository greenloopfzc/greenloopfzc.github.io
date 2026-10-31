# Greenloop QC automatic rules

Release: 20261031-qc-auto-rules-1

- The displayed company grade is **GL Grade**, for GreenLoop. Existing database field names remain compatible.
- Selecting GL Grade D automatically adds Housing once. An existing Housing selection stays intact. Changing away from D removes only the automatic selection, preserving manually selected Housing and other work.
- Grade D phones go to Lab & Parts; direct Frame routing is blocked. Initial QC parts continue to reach Parts directly.
- An installed Diagnostic Battery from the current Lab workflow sets Final Battery Health to 100%. The battery must be issued, remain unreturned and be recorded as installed by completing Lab work. A pending order, ordinary Battery or Battery Boost does not qualify.
- Applies to single and bulk Lab completion, Final QC save and Final QC-to-Frame routing. Initial Battery Health remains unchanged for history. Existing Final QC correction tools remain available in Reports.
- Final QC retrieves battery defaults in batches of up to 500 phones, with existing page permissions and Office Only checks. No new permission ticks or secret are needed.
- Installation preserves existing devices, inspections, parts, returns, histories, prices, users and passwords. It does not backfill parts on previously completed Initial QC inspections or change existing saved Final QC inspections.

## Install and publish

Run outputs/Publish-GreenLoop-QC-Auto-Rules.ps1. It checks previous installations first, copies the new SQL only when its marker is missing, verifies installation, then uploads without force push and checks published assets.

Supabase SQL result must be installed_qc_auto_rules_version = 20261031-qc-auto-rules-1. Paste the copied SQL directly into a new SQL Editor query. This release needs no new Edge Function deployment, JWT setting or encryption key.

Local database and browser tests use disposable fixtures, not live business records. A local test pass does not mean the update is installed on the live website.

Installer compatibility: reviewed predecessor routines may contain Windows CRLF or Unix LF line endings. The installer normalizes line endings before exact code-boundary checks; all integrity and access checks still apply.
