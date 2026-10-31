# B-DEPT and editable Final Battery Health

Release 20261031-b-dept-1.

Frame Department is displayed as B-DEPT (B Department) throughout navigation, dashboard cards, Initial QC and Final QC routes, reports, workflow correction and User Access. Existing saved identifiers, links and permissions remain compatible. Physical part/service names are preserved.

The B-DEPT pending table shows Initial BH and editable Final BH separately. Final BH loads the current saved routed inspection value, including the existing 100% Diagnostic Battery default. Phones routed directly from Initial QC also show their saved value. If no saved Final BH exists, the Initial BH is available as the starting value; a missing value remains blank for review. Android supports explicitly unavailable Battery Health.

A B-DEPT Pass validates Final Grade and Battery Health, saves the final value and transfers the phone directly to Ready Stock in one transaction. Initial BH is unchanged. Each B-DEPT result records previous and reviewed Final BH with its operator and time; the device event provides linked audit evidence. A Fail retains the phone in B-DEPT and keeps the reviewed BH available on its pending line.

Existing B-DEPT entry permission controls editing. View Only users can read values without changing them; Office Only and supplier-name permissions still apply. No extra permission tick is added.

Run outputs/Publish-GreenLoop-B-Dept.ps1. It checks preceding installations and includes the fixed CRLF/LF-compatible QC and Lab return clock prerequisites when needed. Required new SQL result: installed_b_dept_version = 20261031-b-dept-1. This release needs no new Edge deployment, JWT change or secret. Installation preserves existing operational data and does not backfill or rewrite historical results.
