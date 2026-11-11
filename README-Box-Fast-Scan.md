# Box Entry: one-request scans and popup-only errors

Version: 20261111-box-fast-scan-1

A complete 15-digit scan starts immediately, removing the previous 180ms wait. Single scanning uses the already-installed scan_imeis_to_export_box_v1 endpoint with one IMEI. This one request performs the existing validation/reservation and returns the confirmed box, current revision, results and complete sheet lines. The former single-write + separate lines read + separate workflow read sequence is removed from the success path. Busy state updates controls without rebuilding the table, then the confirmed sheet is rendered once. No optimistic phone rows or unconfirmed saves are shown.

Problematic, duplicate, invalid or unavailable IMEIs are not added to the sheet as red rows. A styled reason popup shows the scanned IMEI and reason instead. For a mixed bulk paste, valid phones are saved normally, and all rejected/duplicate/invalid entries are listed together in one popup. Only valid sheet rows are printed. OK or Escape closes the popup and restores scanner focus after the identifier-copy display settles. The scanner remains disabled while the popup is open. Enter/Tab suffixes and continuous scan focus from the preceding update are preserved.

The existing transaction still enforces Ready Stock, current box/revision, scan permission and Office Only. No new SQL or database rules are introduced. If a reply is lost or malformed after a possible commit, the browser performs one canonical workflow read and never repeats the write automatically. Confirmed saved phones are retained; unresolved entries get a reason popup. If verification itself fails, the scanner stays disabled until the box is reloaded.

Print format, valid draft Delete, print confirmation, Save Box/Accounts, existing stock/history, replacement features, copy/screenshot preferences and unrelated layouts remain unchanged. Source and root mirrors are identical. The publisher verifies preceding installations and safe Git ancestry, then checks the published files. No additional SQL, Edge deployment, JWT, secret, permission tick or reader restart is needed for this frontend fix.

Run outputs/Publish-GreenLoop-Box-Fast-Scan.ps1. After LIVE - VERIFIED, Ctrl+F5 > Box Entry. Scan consecutive phones; only confirmed valid IMEIs appear on the sheet. Any issue appears in a popup.

Validation: isolated PostgreSQL fixtures exercise the existing endpoint for a one-phone snapshot and 50-phone paste, invalid/repeated/unavailable phones, stale revision, saved boxes, draft removal, Office Only, view-only and anonymous denial. Real Chromium fixtures include actual permission guards, content protection and shared scanner/bulk handling. They confirm one request and one sheet update per normal scan, popup-only issues, continued focus, mixed paste reasons, read-only recovery after lost/malformed replies and valid-only print data. No live records or website were changed by those tests.
