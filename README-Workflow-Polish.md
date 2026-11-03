# QC services, sidebar counts and draft box lines

Initial QC saves its incoming service list as the Lab & Glass default in the same transaction as the handover. Lab may subsequently add or remove services. Installing this update saves existing pending defaults once and preserves existing Lab saves; services remain separate from physical Parts orders.

Sidebar notifications show the complete pending count, including values above 99. Counts retain the existing live refresh and IMEI-based counting rules.

Box Entry provides Delete on each unsaved draft line. Removing a line returns the phone to Ready Stock, resequences the box sheet and invalidates the previous print confirmation. Device and workflow history remain. Saved, Accounts and returned-for-recheck boxes cannot use this draft deletion API. Delete controls are omitted from printing. The existing returned-box correction workflow is unchanged.

Supplier labels use the receipt/batch quantity: `SUP-06-(342)`. Supplier names are appended only for accounts with the separate Supplier & Customer Names permission. Quantity is resolved by individual phone or batch, so two receipts from one supplier keep different quantities. The read APIs enforce page access, Office Only restrictions and confidential-name masking on the server. Raw supplier codes used by filters remain unchanged.

## Install

Run `outputs/Publish-GreenLoop-Workflow-Polish.ps1`. It verifies the previous installation, copies the new SQL to the clipboard when required and waits for this result:

`installed_workflow_polish_version = 20261103-workflow-polish-1`

Paste the clipboard directly into a new Supabase SQL Editor query and run the complete query. Return to PowerShell and press Enter after the exact result appears. The publisher verifies the database before uploading and compares the published assets with the tested files. No new Edge deployment, JWT change or secret is needed.

Existing data, users, permissions, stock histories, prices, Initial BH, password setup and unrelated workflows are preserved. No live business entries were created or removed during testing.
