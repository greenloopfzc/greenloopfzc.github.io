# Explicit Reports permissions

Reports View opens the sidebar page only. It grants no report data or cards.
Each of the 19 reports has its own View tick in User Access > Reports. Select
its Search & date filters, Sort headings and available correction/download
permissions separately. Deselecting a report clears its child ticks in the UI.
Search, sort and download ticks without their report View never grant access.

For AZIZ, select Reports, then Stock Grade & Work Analysis. Select its Search
& date filters action to enable Supplier / Batch / Invoice selection, and its
PDF action if PDF View / Download is needed. Leave other report View ticks off.
The Reports page then shows that report alone. A parent-only account sees
No reports assigned. A forbidden report URL does not fall back to Overview.

The server authorizes each selected report, returns only its dataset, and
projects the legacy aggregate reader to permitted sections. Unticked export,
audit, supplier progress, correction and management readers are guarded too.
Remote Damage and Available Stock Correction filters require their own search
permissions. Existing serial number and region fields remain on allowed rows.
Dashboard has a separate, narrowly projected reader under Dashboard View.
Office Only, inactive-account, TV-only and existing action-role checks remain.
Business stock, IMEIs, workflow history, employees and damage data are unchanged.

Existing Owner / Super Admin accounts with Reports retain their previous full
report visibility through explicit stored View ticks. Other users receive no
new report views automatically. After installation, configure their report
sections in User Access and save. Existing stored child grants remain inactive
until their report View is selected. Export-box deletion is now separate from
Restricted Data deletion.

Install SQL 20261104_244_report_section_access.sql after the verified B-DEPT
Lab Transfer update. Required database result:
installed_report_section_access_version = 20261104-report-permissions-1

The existing admin-create-user Edge Function also needs the included code so
new users can receive more than the old 30 Reports actions. Reports is bounded
to 128 actions; other page limits and server catalog validation remain intact.
Its existing password version, encrypted vault, Auth checks and atomic account
initialization are preserved. No JWT or secret change is required. The publisher
checks database and service support before publishing any new page files.
