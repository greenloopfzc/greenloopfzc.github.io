# Box Entry printable scan issues

Failed single scans and bulk-paste attempts appear in the Box Entry packing-sheet table as red rows with IMEI, the exact available reason and Delete. This replaces IMEI error popups and the separate scan-error banner/list for this tray. The scanner clears and remains ready for the next phone. Client-side duplicate and invalid pasted values are also shown as review rows.

Print Box and Download PDF include these rows in red with a dedicated Issue / Reason column. The header/footer separate valid phone quantities from scan issues. An issues-only sheet can be printed. A clean sheet retains the existing seven-column layout and fifty standard IMEIs per A4 Portrait page; reasons wrap and may require extra pages.

Review rows are local to the current open Box Entry session and are not saved export items. Their Delete button removes only the failed attempt; it makes no phone/business-data deletion request. Valid phone quantities, database stock and sidebar counts continue to use canonical box items. Draft-item Delete retains the existing separate server action.

Save Box and Printing completed cannot be used with unresolved issue rows. After removing the issues, print and manually confirm the clean sheet before saving to Accounts. Printing issue rows never marks the box printed. The existing revision, permission and Accounts verification checks remain in force. Recheck packing sheets keep their normal print/confirm workflow.

Only Box Entry opts in to inline issue handling; other bulk-paste adapters retain their existing validation/status behaviour. The existing one-request bulk scan, single scanner, lost-response reconciliation and view-only guards are preserved.

Frontend-only update: no new SQL, Edge Function, JWT setting, secret or permission tick. The publisher verifies earlier required installations and preserves their existing install path if missing.

Checks: single wrong-stage issue; mixed and all-invalid bulk; duplicate/not-found/invalid reasons; local issue deletion; valid counts; issues-only and mixed red PDFs; native Chrome actual page and isolated red print; independent PDF text/page-size checks; clean fifty-line print; manual clean confirmation, draft/recheck gates, existing bulk/single scanning and other bulk-adapter regressions. No live SQL, physical printer changes or website publishing performed during development.
