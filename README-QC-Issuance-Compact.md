# Compact Lab & Glass Issuance

The issuance tray uses compact rows like Initial QC. IMEI, model, GB, color,
battery health, supplier code, grades, parts, services, technician, destination
and transfer appear in separate columns. Controls are 32 px tall; the raised
design, visible row boundaries and light/dark palette remain. Reload details is
a small named button beside Transfer. Long cell values retain their full text
and hover title. Receipt batch/invoice and saved inspection details remain in
the supplier/grade cell titles and accessible supplier label.

Technician and destination choices in the first line automatically carry to
unmodified later lines. Manually choosing a different value on a later line
preserves that field's override when the first line changes again. New lines
inherit the first-line template, including after Excel paste, Add 10 lines or
Load all awaiting. Completed transfers are never changed by carry-down.
Changing to B-DEPT disables the Lab technician field as before. The redundant
global selection/apply panel has been removed.

This is a frontend update. Existing Initial QC Entry/View permissions, bulk
paste, validation, stale-record checks, Lab/B-DEPT transfer and portrait handover
PDF behavior are preserved. No database migration, Edge deployment, JWT change,
secret or permission tick is added. The publisher requires the earlier verified
QC Inspection and Issuance installation before uploading this layout update.
