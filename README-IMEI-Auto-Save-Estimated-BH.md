# IMEI Entry Auto Save: include estimated BH

Version: 20261103-imei-auto-save-estimated-1

The previous entry handlers intentionally stopped Auto Save when the cable reader tagged Battery Health as a capacity estimate. At the owner's request, complete estimated-BH readings now use the same Auto Save queue as other complete readings. Switching Auto Save ON also saves an already-loaded complete phone with estimated BH.

The entered BH remains the reader's value; it is not changed to 100 or described as verified. Pending/saving context and the saved row identify Estimated BH. The single-entry success message and shared saved-row event carry the same indication. This indication is session UI only; this frontend-only change does not add a permanent provenance column or modify the database save API.

Auto Save OFF still requires Save. Missing/invalid fields, invalid BH, duplicates, dual-IMEI reader compatibility, permission checks, receipt changes and cancellation checks continue to apply. Editing BH manually clears its estimate marker as before. IMEI1, IMEI2 and serial identity save atomically through the existing API and route the phone to Initial QC.

The print/review popup remains removed. Existing records and other workflow pages are unchanged. No SQL, Edge deployment, secret, JWT change or new permission is required; the publisher verifies earlier required installations.
