# IMEI scan replacement and current location

The next complete keyboard-scanner IMEI replaces the previous IMEI in the active search/scan field. Exact 15-digit pastes also replace it. The shared handler supports scanner Enter/Tab suffixes and scans without a suffix, including fields limited to 15 characters. It buffers rapid digits so a short browser delivery pause does not lose the beginning of the new scan. Ordinary model/invoice typing, deliberate caret edits, passwords, quantities, disabled controls and multiline IMEI lists retain their existing behavior. Bulk trays keep their normal separate phone rows.

Stage-specific search fields show the existing phone's current location when it belongs elsewhere. Initial/Final QC, Lab, IMEI Entry and Box Entry retain their native identity/queue checks; other relevant searches use the existing minimal get_imei_duplicate_stage_v1 reader. Parts and Lab may legitimately share a phone. History and all-stage reports do not treat other stages as errors. IMEI 2 still identifies the same primary phone and displays the duplicate warning.

Open Current Stage is available only when the signed-in account may view the destination page. Its destination comes from a fixed page map, with the primary IMEI safely encoded in the URL. The destination pre-fills a visible permitted finder; it does not save, receive or transfer a phone automatically. Existing server permissions and transition checks remain authoritative. Stale asynchronous results cannot overwrite a newer scan's notice.

## Installation

Run outputs/Publish-GreenLoop-IMEI-Scan-Location.ps1 from the original workspace. This update needs no new SQL, Edge Function, JWT change, secret or permission tick. Existing cumulative prerequisites are still checked by the publisher. It stops on an unreviewed newer GitHub version and verifies published assets before reporting live success. Press Ctrl+F5 after successful publication on each open workstation.

## Verification

Browser fixtures exercise repeated scans, old 30-digit concatenated values, maxlength fields, scanner timing variation, deliberate manual edits, single IMEI paste, protected fields, linked queues, current-stage permissions, IMEI 2, stale responses and mobile layout. Additional real-page tests exercise IMEI Search with real autocomplete and client permissions, QC native checks, Lab technician switching and destination pre-fill. Existing Lab/Parts, cable review/printing and manual Auto Save flows are regression checked. The accompanying package TEST-SUMMARY records the final results.

Tests use local fixtures and do not modify business records. Local verification does not claim live publication. Browser keyboard-wedge scanners and clipboard input are supported; scanner hardware was not available for a physical-device test.
