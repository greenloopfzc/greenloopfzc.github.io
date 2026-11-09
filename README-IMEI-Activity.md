# IMEI activity presentation

IMEI Search uses a read-only endpoint, get_imei_activity_journey_v1. Existing page-view, office-network and confidential-name checks remain in force. This installation does not change phone, job, inspection, parts, movement, export, access selections or historical timestamps.

Full Activity orders equal-time records within each job by workflow sequence. An explicit Initial QC direct-to-B-DEPT event and its matching system records are presented as one transfer with expandable automatic routing records. Genuine Final QC, failures and later rework remain separate. Every original record is retained.

Supplier labels use the original quantity from the matched receipt. Current saved supplier/GL grades are explicitly labelled; they are not represented as historical inspection snapshots. Saved Initial QC parts and service requirements are included when recorded.

Validation: first CRLF and repeat LF migration; unchanged pre-existing routines and business/access snapshots; actual direct-route workflow; secondary-IMEI lookup; page/name/private/anonymous access; genuine Final QC/rework; all audit IDs retained; real page rendering; existing 50-record report pagination.

Version: 20261109-imei-activity-1.
