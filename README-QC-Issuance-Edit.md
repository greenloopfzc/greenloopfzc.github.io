# Edit requirements before Issuance

Each loaded phone has an Edit button. It opens an inline Parts / Services panel
identified by IMEI, model and storage. Choose existing managed dropdown options,
add or remove requirements, set part quantities, then Save Changes. Cancel
leaves the saved list unchanged. Other tray actions wait while this editor is
open. Saving is explicit and does not transfer the phone. Technician and route
choices stay selected; the row receives the fresh inspection revision.

The existing Initial QC Entry permission permits this action. View Only cannot
edit. The server enforces Office Only, active accounts, current revision and
awaiting-Issuance state. No new permission tick. Editing ends after transfer.
Retries replay the same save; stale or conflicting changes are rejected.

Changes update the existing inspection's requirements and findings. Grades,
original QC date, original saved inspection receipt and Battery Health stay.
Removed requirements/findings remain inactive for history; the permanent
amendment ledger records before/after lists, actor, time and revisions. Device
journey receives a change event. Reports immediately use the revised list.
The existing transfer publishes the updated parts once and seeds only selected
services. Lab's Initial QC summary excludes inactive choices for amended phones.

The source retains 50-record report pagination, full exports, bulk paste and
scanner trays, exact separate QC / Issuance badges and supplier quantity labels.
Additive Issuance Edit SQL is required. The publisher includes the preceding QC
notification-count fix if missing. No Edge deployment, JWT setting or secret.
