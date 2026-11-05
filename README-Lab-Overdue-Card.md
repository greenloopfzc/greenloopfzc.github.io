# Lab & Glass overdue drill-down

Lab & Glass has an embossed Overdue Phones - 2+ Days card directly after
Bulk Transfer to Final QC. The exact count is red; an unavailable count shows
a dash, never a false zero. The launch cards have the same 46px height.

Opening the card uses a separate browser tab, preserving unsaved workbench
rows. The report first shows technicians with overdue phones, including an
Unassigned bucket when necessary. Each centered card shows the overdue count
and oldest pending time. Click a technician for that person's overdue IMEIs,
model, GB, color, BH, supplier/receipt code, batch/invoice, department, original
arrival and individual pending duration. Regular cards and phone lists use
Previous/Next at 50 records; the launch count reads one summary page.

The read-only API uses the installed original-arrival Lab clock and the same
Asia/Dubai Sunday exclusion as TV. A phone qualifies only above 172800 counted
seconds. A device counts once. Returning from Final QC retains the original
arrival. Leaving Lab/Glass or being deleted removes it from the report.
Phone counts are independent of TV employee-selection and TV access settings.
Existing Lab & Glass View access is sufficient; there is no new permission
tick and no operational action on the report. Office Only and TV-only account
restrictions remain server-side.

Supplier labels retain each actual receipt's original quantity in brackets.
Names are included only by the installed partner-name permission. An unknown
quantity is never invented. This update does not modify stock quantities,
assignments, parts, services, histories, timers, TV settings or business rows.

Install via Publish-GreenLoop-Lab-Overdue-Card.ps1. The script preserves all
earlier pinned updates, combines missing prerequisite SQL and checks the final
get_lab_overdue_card_version() = 20261105-lab-overdue-card-1 marker. No Edge
Function deployment, JWT change, secret or new access checkbox is required.
The user runs the publisher; it never force pushes.
