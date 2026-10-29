# IMEI save access and error reporting

Version: 20261029-imei-save-access-1

A browser reproduction with IMEI Entry permissions granted failed before making any save request. The identity-aware receiving RPC existed only in the legacy `rpcs` section; the browser guard resolves top-level entries or `rpc`. Its missing action mapping was treated as an unmapped write. The save popup then concealed that reason as "IMEI check unavailable".

The existing `receive_stock_batch_imei_with_identity_v1` Entry permission is now also mapped where the runtime resolves it. No new permission grant, database function, schema or record is added. Other legacy RPC mappings remain unchanged.

Single and bulk entry display the actual service message and error code using textContent. Duplicate-check failures still block saving and retain their own check dialog. Save failures retain entered fields. Uncertain network saves ask the operator to check IMEI Search before trying again; no automatic retry is introduced. Valid secondary-IMEI conflicts retain the primary-IMEI duplicate notice. Existing post-save refresh warnings are preserved.

The page cache version covers the mapping and both entry scripts. Root script mirrors match js/ files. The cumulative publisher preserves all earlier verified database installers and Lab phone card changes; this fix itself requires no SQL.

Verification: reproduced the previous exact popup with zero backend writes; 21 browser cases cover manual and automatic entry, incomplete fields, receipt changes, duplicate blocking, restricted users, cable dual IMEI, service/check/network errors and secondary-IMEI conflicts. Publisher rehearsals and CheckOnly verify release integrity. Browser tests use fixture data; no live business records are saved. Live publication is a separate step through the publisher.
