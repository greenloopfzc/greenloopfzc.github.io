# B-DEPT Performance Report

Release 20261101-b-dept-report-1 adds a separate card to B-DEPT. The card opens a dedicated report page; pending work and the existing BH/grade/Pass/Fail workflow stay in place.

The report shows one phone job per row: IMEI, model, GB, color, supplier code, first B-DEPT arrival, latest result and recorder, current status, failed attempts, recorded visits, and total time. History opens all recorded Pass/Fail attempts with dates, staff and notes. A phone failing three times and then passing counts as one phone with three failed attempts and one passed outcome.

Summary counts cover the complete filtered dataset, independently of the 50-row table page. They include phones, latest passed outcomes, phones still pending in B-DEPT, failed attempts, average time for passed phones with known arrival data, and phones pending at least 48 hours. Fail-history phones overlap the Passed/Pending groups; attempts are not extra phones.

Time sums recorded location-history intervals inside B-DEPT. A Fail never resets it. Leaving B-DEPT or passing stops that interval; a later visit adds its own interval without counting time spent outside B-DEPT. Missing arrival data is explicitly shown as Time not recorded. No past timestamp is invented or backfilled. This measures elapsed department time, not hands-on technician labor.

Dates use Asia/Dubai (UTC+4), inclusive From/To calendar dates. Choose first arrival or latest result as the date basis. By default searchable accounts see this month. Clear filters to see all recorded dates. The time and attempt totals represent the full B-DEPT history of matching phone jobs, rather than attempts occurring only inside the selected date range. Filters and search are server-side; headings sort. Refresh reloads current data.

PDF View / Download uses the same filters and order, A4 portrait, repeated branding/headers/page numbers, complete phone rows, and no four-page limit. Excel is a real .xlsx file with Performance and Pass Fail History sheets; IMEIs remain text. Exports retrieve all filtered rows, not only the visible page. More than 10,000 rows stops with a clear request to narrow dates; partial exports are never silently created.

Existing B-DEPT View access permits the report and its history. Search and Sort retain their separate existing permissions. A new B-DEPT report PDF/Excel Download checkbox is available in User Access. Ordinary accounts receive no new actions automatically; existing Owner/Super Admin accounts with B-DEPT View receive this download action. View-only accounts can receive Search, Sort or Download independently without entry permission. RPC checks enforce each operation and the existing Office Only boundary. Supplier/customer names, costs and passwords are not included; supplier codes remain visible.

The migration is read-only for business workflow records. It adds reporting functions, two lookup indexes, the explicit download capability and integrity receipts. It preserves original IMEI/BH data, stock, returns, employee merge, damage histories and account permissions. It requires the verified Employee Merge predecessor; the publisher includes all preceding installer components.

Run outputs/Publish-GreenLoop-B-Dept-Report.ps1. Paste its copied SQL into a NEW Supabase SQL query and run it. Required result: installed_b_dept_report_version = 20261101-b-dept-report-1. No new Edge Function, JWT change or secret is required. Ctrl+F5 after publication.
