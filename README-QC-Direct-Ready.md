# Initial QC direct release and stock selection

Each Initial QC row has a Direct Ready Stock checkbox beside Save. The first
row's choice carries into untouched lower rows and new rows. A lower row can
override it. Ticking it never disables or clears the grade, part or service
dropdowns. Saving remains an explicit action.

Direct release requires company stock, a saved non-D GL Grade, recorded BH
(or the existing unavailable flag), and no selected parts or services. If work
is selected, Save explains the conflict and retains the row. The operator can
change the dropdowns or untick the direct route to save for normal Issuance.
GL Grade becomes the stock grade; Battery Health stays unchanged. The database
saves the inspection, stock movement and release audit atomically. A retry of
the same request cannot create a second release. This does not create a Final
QC inspection, repair order, technician assignment, part issue or repair time.
Ready Stock listings and box scans recognize this explicit release. A later
authorized rework creates its first actual repair order when rework is needed.

Initial QC and Lab & Glass Issuance now have visible Supplier, Stock/Batch and
Invoice selectors. Choose a scope and click Load selected stock. Existing
Auto pick / Load all respects the selected scope. Changing a selector only
refreshes its pending count. It does not save, transfer or replace the tray.
The existing confirmation protects a nonempty tray before replacement. Bulk
work trays load the complete selected queue, including more than 500 IMEIs;
regular report tables remain at 50 records per page.

Supplier selectors show base identity codes and authorized names. Specific
stock options use the original receipt quantity in brackets. Permissions,
Office Only checks, supplier-name restrictions and manual transfers remain.
Issuance editing stays within the Parts/Services cells, with no quantity input.

Install through Publish-GreenLoop-QC-Direct-Ready.ps1. The version is
get_qc_direct_ready_version() = 20261105-qc-direct-ready-1. The installer checks
prior versions and copies the required combined SQL. Run it in a NEW Supabase
SQL query, then press Enter in PowerShell. No Edge Function deployment, JWT
change, encryption secret or new permission checkbox is required. Publication
is manual and the publisher never force pushes.
