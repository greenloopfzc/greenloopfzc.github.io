# IMEI Entry: previous save flow restored

Version: 20261103-imei-entry-no-print-1

The connected-phone review popup, Save & Print and Reprint Last Label controls no longer load on IMEI Entry. Cable readings fill the existing entry fields/phone line directly. Use the line's Save button, or enable Auto Save to save complete confirmed readings automatically, as before the label update.

This is a targeted reversal of the label integration in the single and bulk entry handlers. It retains current IMEI scanning, duplicate/secondary-IMEI checks, atomic IMEI1/IMEI2/serial storage, supplier receipt selection, entry permissions, error details and editable/incomplete/estimated battery safeguards. The cable reader setup and detection are unchanged.

Existing database records, Initial QC routing and all later Lab/Final QC updates are preserved. No new SQL, Edge Function, JWT setting, secret or permission is required. The publisher checks previous required installations and refuses to overwrite newer unrelated GitHub changes.

Historical label assets remain unreferenced for compatibility; the IMEI Entry page does not load their code or styles and creates no label, print window or review dialog.
