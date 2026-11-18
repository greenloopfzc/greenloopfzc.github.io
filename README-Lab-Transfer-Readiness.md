# Lab to Final QC readiness

Lab & Glass and Bulk Transfer use the same protected fresh phone readiness
preview before adding a scanned or pasted phone for handover. A blocked phone
does not become a new transfer row. A modal names the IMEI, exact saved reason
and current stage: parts/services pending, pending part return review, Initial
QC, saved Issuance, Final QC, B-DEPT, Ready Stock or Chaman custody.

Mixed paste adds only verified ready phones and groups rejected IMEIs in one
popup, one phone per row. Invalid tokens and duplicate physical phones are
reported too. A saved IMEI2 resolves to its IMEI1 without a secondary-only
warning. Closing the popup returns focus to the same empty scanner when its
request still owns the field and access is valid. Existing prepared phones are
retained; a later main-window paste also rechecks previously prepared phones.

The technician's ordinary work list still includes pending work so its parts
and services can be edited through the existing workflow. View/search users
keep that read-only workflow; this update grants no handover action. Eligible
phones can still be completed individually in the main window or through the
explicit bulk transfer action. Scan/paste never transfers automatically.

Recheck removes confirmed blocked phones. A failed/unverified read retains a
previously prepared phone with a visible recheck requirement and blocks transfer
until verification succeeds. A stale server rejection opens a popup and requires
recheck; an uncertain bulk response preserves the exact actor-bound request and
retry command instead of silently changing or replaying it. Main completion has
the same fresh preflight and retains the original atomic write/revision checks.

The SQL enriches the existing private Lab preview with a version and readable
stage, including saved Initial QC Issuance. Active Chaman custody adds a blocking
reason until confirmed Greenloop receiving. The existing bulk writer reuses that
private preview before and after its locks. No assignment, stock, part, service,
history or timer is repaired or rewritten by a preview or by installation.

The existing meaning of saved services is preserved. Initial QC services that
the workflow already saves do not become unsaved merely because a different
screen is opened. Ordered/partially issued parts and pending return reviews
remain blocked by the existing authoritative server rules.

Install through the cumulative publisher, following its SQL prompts. Required
new result: `20261118-lab-transfer-readiness-1`. Refresh open tabs after the
publisher verifies the live assets. Codex prepares and tests the package locally;
the user installs live SQL and publishes.

Validation: actual protected workflow cases in a disposable PostgreSQL database,
current-stage and Chaman dispatch/return tests, all 18 existing bulk business
groups, browser scan/mixed-paste/duplicate/recheck/stale/retry/main-completion/
late-lock cases, mobile/dark popup inspection, and LF/CRLF/repeat/rollback/
registry integrity checks with generated implementations renamed. No production
phone was moved during testing.
