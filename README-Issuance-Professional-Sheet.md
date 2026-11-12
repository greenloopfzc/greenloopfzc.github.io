# Lab & Glass issuance sheet

The handover sheet uses compact A4 portrait with up to 50 phones per page, equal 32pt print margins, centered table cells, wrapped text and repeated page headings. Column widths follow the actual contents: S.No/GB/Grade stay narrow and longer text receives more space. Columns include S.No, IMEI, model, GB, color, GL Grade, exact original stock/batch quantity, required parts and services. Technician, total phones and page numbers remain visible.

Loaded saved inspections with selected Lab & Glass technicians can be printed or downloaded before transfer. Printing does not issue phones. Confirmed transfers remain available in the current page session after transfer and tray clearing. Draft rows are merged by job ID with confirmed rows; mixed or missing technicians are still rejected. Unsaved Parts/Services editing blocks output. Access loss closes PDF previews.

Validation: isolated Chrome issuance flow before/after actual mocked transfer, direct PDF download, Print, correct grade and BATCH-2026-0002-(342), deduplication, tray clearing, no extra write RPCs, 1/49/50-phone single-page PDFs, 51/100-phone two-page PDFs, matching browser print page counts, and text inside A4 margins. No new SQL is required for this change.
