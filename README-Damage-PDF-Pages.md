# Damage PDF page count

Version: 20261027-damage-pdf-pages-1

Damage Report View PDF and Download PDF now retain every measured A4 portrait page instead of rejecting selections that exceed four pages. The helper text no longer advertises a four-page maximum. Existing font sizes, wrapped cells, continuation headings, page numbers, all/individual technician selection, UAE dates, independent original/copy calculations and permissions remain unchanged. No records are truncated to meet a page count.

This is a PDF layout update; the existing complete-data validation and database export contract are preserved, including the separate 2,000-entry export safeguard. No new SQL or Edge Function is needed for this layout. The publisher retains verification/installation support for preceding Performance updates if still pending.

Validation includes combined and individual reports over four pages, long text continuing onto later pages, parsed PDF page counts and entry coverage, original/copy totals and payables, vector bounds, rendered first/continuation/last pages, and browser View/Download behavior. Existing small-report cases and permission/stale-response controls are also checked. Sample reports contain fictional data only.
