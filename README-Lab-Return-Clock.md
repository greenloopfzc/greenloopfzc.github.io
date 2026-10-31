# Lab return clock

Release 20261031-lab-return-clock-1.

A phone returning from Final QC to Lab/Glass continues its elapsed clock from the first recorded Lab/Glass arrival in the same repair job. Repeated returns, internal transfers and technician reassignment do not reset that clock. It measures elapsed calendar time since that arrival, including the time spent in Final QC.

The workbench, 48-hour dashboard report and ongoing IMEI/stock-journey delay evidence use the same clock. Completed individual stays and original movement history remain unchanged. A separate new repair job starts its own clock. Missing arrival evidence keeps the existing explicitly labelled technician/work-line fallback; no timestamps are invented.

This is a read-only reporting change. It does not edit phone history, assignments, stock, parts, grades, battery health, users or permissions. Existing access checks and Office Only restrictions remain in place. Existing phones with recorded movements receive the corrected clock immediately after installation; refresh the page.

Run outputs/Publish-GreenLoop-Lab-Return-Clock.ps1. It preserves the preceding GL Grade / Housing and Diagnostic Battery update and installs that prerequisite if missing. Required new SQL result: installed_lab_return_clock_version = 20261031-lab-return-clock-1. No new Edge deployment, JWT setting or secret is needed for this release.

Installer compatibility: reviewed predecessor routines may contain Windows CRLF or Unix LF line endings. The installer normalizes line endings before exact code-boundary checks; all integrity and access checks still apply.
