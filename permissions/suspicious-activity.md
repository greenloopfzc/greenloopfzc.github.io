# Suspicious Activity

The page records explainable review alerts from new database activity after migration 177 is installed. It never automatically deducts pay, blocks a phone, or concludes that a user committed misconduct.

## Detection rules

| Rule | Trigger and evidence |
| --- | --- |
| Fast completion | A phone that required repair reaches Ready Stock within 10 minutes of its recorded IMEI/job entry. The threshold is configurable from 1–120 minutes. Stock receipt time is shown separately. No-repair and direct-export jobs are exempt from this timing rule. |
| Missing workflow | Ready Stock lacks Initial QC, a current Final QC pass, or still has unfinished Laboratory, Glass or Frame steps. The latest failed QC and Ready Stock rework invalidate an older pass for this check. |
| New login combination | A successful authenticated session uses a browser/device-type combination absent from that user's earlier recorded sessions. The first recorded session establishes a baseline. This is user-agent information, not a unique physical-device identity. |
| Outside working hours | Successful login outside configured UAE working hours. Disabled initially; supports overnight shifts. |
| Damage correction | An employee, department, part, quantity, original/copy price, currency or incident date changes, or a damage entry is removed. Evidence includes the correction reason and changed values. |
| IMEI correction | Permanent device-correction audit records a changed IMEI. Old/new identifiers and correction reason are retained. |
| Verified box correction | Packing or linked source data changes after verification/historical export. The pre-correction state and before/after values are captured before the existing workflow returns the box to Accounts. |

The source observers run in the business transaction. Ready Stock checks are deferred until the transaction finishes so they see QC and work-step writes in their final state. Event keys suppress repeated detection of the same event; reviews do not modify evidence. Detector failures are recorded in monitoring health rather than silently represented as successful monitoring.

## Access and review

User Access contains separate View alerts & evidence, Search & date filters, Sort alerts, Review / resolve alerts, Download alert report, and Manage detection rules checkboxes. These are checked by the database as well as the UI. Existing Super Admin accounts receive initial access; other accounts require an explicit grant. View includes sensitive evidence such as user names and corrected original/copy prices, so grant it to appropriate reviewers.

Reviewers choose Needs investigation, Valid activity, Resolved, or Reopen and add a required note. Each decision retains the reviewer, time and prior status. A revision check prevents overwriting another reviewer's concurrent decision. Rule changes also retain an audit trail and apply only to new activity.

The sidebar shows the number of new alerts. Visible pages refresh the summary every 15 seconds and after local confirmed workflow changes. The main table supports live search, yellow matches, date/department/rule filters, heading sorting and pagination. CSV download requires its own permission; exports over 5,000 alerts require narrower filters instead of silently truncating.

## Coverage limits

- No historic backfill: installation does not turn existing dummy entries into new alerts.
- Historical Excel import needs a dedicated import path and explicit historical context before use.
- Failed-password attempts, exact device identity, IP/location anomalies, rapid QC batches, stock theft and unlogged activity are not claimed to be detected.
- This release uses recorded facts and configured rules, not an AI verdict or automatic punishment.
- Backend changes require migration 177. No Edge Function deployment or JWT setting change is required.
