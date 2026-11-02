# Cable phone review and 60 x 40 mm label

IMEI Entry now opens one review after cable data arrives for the selected supplier receipt. It uses the existing iPhone + Android reader, including late color/identity updates. Review Model, GB, Color, Battery Health, Serial Number and Region; IMEI 1 is read-only to keep the cable identity consistent. Missing details may be completed before saving.

- Save: runs the existing atomic identity/receipt save and sends the phone to Initial QC.
- Save & Print: saves first, then opens the browser print dialog for the 60 mm wide x 40 mm high label. Failed or unconfirmed saves never print.
- Label: approved black-and-white design with model, GB, color, SN, region, IMEI 1 Code128 barcode and PARTS / SERVICE rows with six blank cells each. IMEI 2 stays hidden and is saved only in the existing backend identity link.
- Reprint Label / Reprint Last Label: prints the last successfully saved phone again without creating a new device. The last label stays in memory for this page session only.
- Cable entries require an explicit review click even if Auto Save is ON. Manual entry Auto Save stays unchanged. Both single and bulk cable entry use the same review.
- Entry permission is required. Existing server roles, Office Only checks, dual-IMEI duplicate checks and supplier receipt limits remain authoritative. No new permission tick or public save API is added.

Use a 60 x 40 mm label roll and choose the label printer, matching paper, Actual size / 100%, no margins, headers or footers. The browser print dialog remains part of this flow. If blocked, allow pop-ups and use Reprint Last Label. Printer hardware and drivers still need their normal setup; no silent driver installation or unattended printing is added.

## Publish

Run outputs/Publish-GreenLoop-Cable-Label.ps1 from the original workspace. This is a frontend-only update: no new SQL, Edge Function, JWT setting or encryption secret is needed. Existing installation prerequisites are still checked by the publisher. It preserves every preceding update through f7404d97fb88abf1f7850953f674fd80b630dc2e; the paused Damage PDF TV Source change is not included.

After verified publication, press Ctrl+F5 on IMEI Entry, select the receipt and connect one unlocked phone. Save & Print opens a new print window; Save creates no print window. A paper-printer test is still required on the actual label printer.

## Validation

18 headless browser cases cover single/bulk Save, Save & Print ordering, duplicate/revoked permissions, retained edits and late reader data, Android missing BH, print blocking, failed save, old reader, receipt switching (including an in-flight duplicate check), stale earlier-phone responses, mobile dark layout and next phone. Twenty manual-entry regression cases verify Auto Save, sequential writes, server errors, secondary IMEI errors and access guards. Code128 symbols were compared against ReportLab for 100 IMEIs; actual rasterized browser barcode bars/spaces were verified too. Browser print is one 60 x 40 mm page within Chromium sub-pixel paper rounding; label content fits. No physical printer result or live publication is claimed by local tests.
