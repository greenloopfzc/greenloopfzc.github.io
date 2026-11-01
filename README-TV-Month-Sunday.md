# TV switching, monthly Damage and Sunday-free overdue clock

Release `20261102-tv-month-sunday-1` follows the TV Overdue release. No damage,
phone, job, arrival, price, payroll or historical business record is changed.

The TV window switcher uses a 250 ms deadline heartbeat. Five-second settings
work independently for Damage and Overdue, including during slow data reads.
Duplicate visible-state events and unchanged data refreshes do not restart the
countdown. Actual tab hiding pauses it; returning gives the view a fresh interval.
Manual employee/summary/phone details pause switching. The displayed Resume
switching button closes those details and resumes; Back also resumes. Auto View
does not block rotation. Pausing, sign-out, Office Only lock, account settings and
stale-response protections remain in place.

Damage TV employee cards, incident ticker, original/copy values, employee detail
pages and summary cards now use only the current UAE calendar month. Payable
keeps the existing separate monthly allowance formulas for both valuations.
At a UAE month change the browser clears the old damage display and fetches
again immediately, rather than waiting for the next 30-second refresh. Monthly
filtering occurs server-side before counts, totals and pagination. Previous
damage incidents remain in the ordinary Reports/PDF readers and original
all-history readers; no monthly reset deletes any data. TV labels say This month.

Only overdue TV counts/details use the new Sunday-free elapsed time. One counted
day is 24 hours outside Sunday, using Asia/Dubai midnight boundaries. Saturday
10 AM to Monday 10 AM is one counted day; Tuesday 10 AM is two counted days.
The threshold remains strictly greater than the configured days. Original Lab
arrival continues across Final QC returns. Dashboard 48-hour reporting and all
stored timestamps remain unchanged. Sunday partial hours and full weeks are
calculated without a per-day loop. Employee allowlists and existing masked TV
fields apply before monthly/overdue aggregation.

Run `outputs/Publish-GreenLoop-TV-Month-Sunday.ps1`. The cumulative publisher
checks existing releases first, including TV Overdue. Paste copied SQL into a
NEW Supabase SQL query; do not paste PowerShell output. Required final result:
`installed_tv_month_sunday_version = 20261102-tv-month-sunday-1`.
No new Edge Function, JWT setting, secret or account permission is required.
After verified publication, press Ctrl+F5 on the TV. In User Access choose both
TV windows and set each to 5 seconds, or keep either view on its own.
