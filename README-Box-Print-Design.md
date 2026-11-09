# Box Entry print design

Box Entry and its saved/recheck packing-sheet Print Box actions now use an isolated A4 Portrait document with the same Greenloop branding, typography and restrained colours as Damage Report. The preview and downloaded PDF use the same measured drawing operations. Printing uses an isolated frame, so application tables, clipping, themes and global landscape styles cannot affect the packing sheet.

- All seven packing columns remain: S.No, IMEI, Model, GB, Grade, Color and Box Number.
- Standard lines fit fifty per A4 Portrait page, with a repeated logo, box number, opened date, total phones, column headings, page quantity, Checked by line and page number. Long custom text wraps without truncation and can require additional pages.
- There is a 12.7 mm outer margin. Use A4, Portrait, Actual size / 100%, one page per sheet. Printer-specific unprintable areas still depend on the selected printer/driver.
- Print Box reads a fresh canonical box/revision before creating the sheet. Printing completed remains a separate manual acknowledgement. Saving/resending a box still requires the matching printed revision. Preview generation never marks a box printed, saves it or exports it.
- Download PDF and Print require the existing Box Entry print permission. Closing, signing out, office lock or permission changes remove the preview and revoke its local PDF URL.
- Draft deletion, bulk scanning, single scanning, Accounts verification and existing supplier/batch name permissions are unchanged.

This is a frontend-only update. No new SQL, Edge Function, JWT setting, secret or permission tick is required. The publisher preserves the previous required installation checks. It does not install or publish anything in CheckOnly mode.

Verification: fictional 46/50/51/100-line PDFs; independent PDF extraction and A4/page counts; rendered-page visual review; native Chrome desktop/mobile preview and isolated one-page fifty-line print; download/Close/Escape/permission revocation; actual draft/recheck print and manual revision acknowledgement; existing one-request bulk/single-scan/view-only regression. No live SQL, real phone data, physical printer or website deployment was changed during development.
