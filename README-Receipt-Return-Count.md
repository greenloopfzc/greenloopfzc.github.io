# Receipt returned phone count

IMEI Search invoice and Stock/Batch results now include Phones returned beside Phones entered. The number counts completed, active supplier-return units linked to that exact receipt, including quantity-only returns before IMEI entry. Pending/cancelled/rejected, archived and operationally deleted units do not count, matching the current Stock Return report. Each physical unit counts once; grouped quantity returns are not counted again as groups.

The read delegates to the existing receipt API, preserving receipt visibility, phone pagination, supplier-name masking and batch identity. IMEI Search View permission, signed-in account, Office Only and TV-only restrictions are enforced on the server. No new write permission, names, costs or IMEI2 fields are exposed.

Run the supplied publisher. It checks existing versions, copies the necessary additive SQL, and waits for the exact installed_receipt_return_count_version result before publishing. No Edge Function/JWT change is required. Existing records are retained. Live installation is performed by the operator; local verification is not a claim of live deployment.
