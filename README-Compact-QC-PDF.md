# Compact QC rows and left serial numbers

Initial QC, Lab & Glass Issuance, Final QC and B-DEPT use compact rows with small controls, content-aware widths and the existing raised design. Narrow screens use labelled rows when controls cannot fit. Issuance editing stays in the same IMEI row with dropdowns, plus/minus, Save and Cancel. Failure details retain their space.

Stock Journey is removed from sidebar navigation only. Existing stock records, IMEI Search history and direct links remain intact.

S.No is the first column in B-DEPT Performance, Technician Parts, Available Stock and Return/Replacement PDF exports, including empty and continued pages. Matching Excel columns, widths and totals remain aligned. Other reports already placing S.No first are preserved.

This update is frontend-only: no new SQL, Edge deployment, JWT change, secret or permission tick. The publisher verifies earlier installations and may request a previously missing installation. Regular report tables remain paginated at 50; complete exports and bulk trays keep their existing behavior. Supplier/batch quantity labels and name permissions are preserved.

Run Publish-GreenLoop-Compact-QC-PDF.ps1. Wait for LIVE - VERIFIED, then Ctrl+F5. Preparation checks do not publish the website or modify business records.
