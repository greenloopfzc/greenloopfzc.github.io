# Stock Grade & Work Analysis

Reports > Stock Grade Analysis shows the Initial QC condition of selected
supplier stock. Select Supplier, then optionally Stock / Batch or Invoice.
Batch and Invoice choices are restricted to the selected supplier, and selecting
one clears the other. No date range limits the selected stock by default.

The header shows supplier, batch/invoice and received stock count. Two matching
model tables show quantities and percentages for A, B, D, Glass and Polish.
Other Grades and QC / Grade Pending columns appear when needed, with an explicit
other-grade breakdown. Entered and unentered stock are reported separately.

- Quantity counts each device once per original batch, even if it has multiple
  jobs, findings or required-part quantities.
- Grades use the current corrected Initial QC GL Grade, not Supplier Grade or
  Final QC Grade. The latest Initial QC inspection within that stock supplies
  the required-work flags.
- Glass and Polish count phones requiring that work in Initial QC, once each.
  They can overlap. Back Glass is not treated as front Glass; later Lab additions
  and Lab completed-work records do not inflate this incoming-quality report.
- Each percentage is count / entered model Qty. Total percentages use total
  counts / total entered Qty, not an average of row percentages.
- Returned phones remain included in their original stock quality analysis.
  This report does not represent current Available Stock.

PDF View and Download PDF generate the same complete A4 portrait report with
Greenloop branding, repeated headers and page numbers. Extra stock receipts are
listed when more than one batch is selected. Long reports have no page cap.
The export rechecks the selected stock and rejects a stale snapshot.

User Access > Reports adds two independent read-only actions:
View Stock Grade & Work Analysis; Stock Grade Analysis: PDF View / Download.
Existing Reports Search and Sort actions govern selection and heading sorting.
Owner / Super Admin accounts with Reports View receive the new actions; other
accounts need explicit grants. Supplier names retain the existing confidential
name permission. Office Only, active-account and TV-only restrictions continue
to be enforced on the server.

Install the additive SQL with version 20261104-stock-grade-analysis-1 after the
verified Stock Replacement update. Business records are not changed. No Edge
Function deployment, JWT setting or encryption secret change is required.
