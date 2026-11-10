# Full-width workspaces and consistent Ready Stock counts

Normal authenticated workspaces use the available width with a small consistent inset. Tables wrap within that width. When too many columns would become unreadable, each existing record uses labelled fields on multiple lines, retaining the original inputs, actions and sorting controls. No fields are clipped or hidden to remove the horizontal scrollbar. Stock Journey's forced 2980px screen minimum is overridden. Complex grouped technician workbenches retain their own record structure. Raised themes and light/dark appearance remain available.

Dashboard previously used a legacy Final QC-only Ready Stock summary and did not refresh with the sidebar. Both now count eligible, non-deleted physical devices with the same private canonical outcome helper, including no-work Initial QC releases. Dashboard listens to verified sidebar snapshots and has an authorized overview-only fallback. A late response cannot replace a newer snapshot. Installation does not edit device, inspection, quantity, supplier, arrival, history or permission records.

Regular reports remain paginated at 50 records with Previous/Next and ranges. Complete downloads and bulk/scanner trays remain independent. Screen-only styles do not change PDF/print sizes or standalone TV/login layout. Supplier/batch labels, confidential names and inline Issuance editing retain their existing behavior.

Run `outputs/Publish-GreenLoop-Workspace-Ready-Counts.ps1` from the existing workspace. `-CheckOnly` validates pinned source and package without publishing. Previous installations are checked first. If required, the publisher copies additive SQL and waits for `installed_dashboard_ready_counts_version = 20261110-dashboard-ready-counts-1`. No Edge Function, JWT, encryption key or new permission tick is required. Modified database definitions, newer GitHub changes, bad hashes and incomplete publication stop verification. No force push.

Preparation tests use disposable PostgreSQL and native Chromium with representative data. They do not install live SQL or publish the website. Run the supplied publisher to apply and verify the update.
