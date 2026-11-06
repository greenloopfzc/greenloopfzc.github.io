# Box print and Accounts source columns

Box Entry prints across the full usable A4 landscape width, with repeated column headings, complete rows and the phone total / checked-by footer. Draft Delete controls never print. Screen content sizing and raised styling are unchanged.

Accounts / Stock Exported box details include the canonical Stock/Batch No already supplied by the existing workflow RPC. Shared serial detection recognizes sortable native S.No headings and removes only previously generated duplicates; original box serial numbers survive sorting and filtering. Detailed box print uses landscape paper so invoice and batch remain visible.

No new SQL, Edge deployment, JWT, secret or permission tick is required. Supplier-name authorization, original receipt quantity labels, 50-row normal report pagination, explicit bulk trays and manual print confirmation / verification gates are preserved. Includes the preceding Issuance widths, red overdue card and Bulk IMEI updates.

Validation: actual Accounts renderer/sorting DOM test; shared serial regression; Issuance layouts at 1900/1280/390px; five Chrome PDFs with 1/50/120-row, portrait fallback, dark-theme print and Accounts cases. PDF extraction checks every sample IMEI exactly once and repeated headings; rendered pages inspected for width, batch and footer. Publisher rehearsals use stubs with no real push, SQL or clipboard changes.
