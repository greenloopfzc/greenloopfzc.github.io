# Parts: cancel an unissued requirement

Run `outputs/Publish-GreenLoop-Parts-Cancel.ps1` in PowerShell. It checks the pinned source and previous database installations before offering this additive SQL. Paste each supplied SQL directly into a **NEW** Supabase SQL Editor query, run the complete query and wait for its exact version result before pressing Enter in PowerShell.

Final SQL result: `installed_parts_cancel_version = 20261110-parts-cancel-1`.

After `LIVE - VERIFIED`, press Ctrl+F5. Open **Parts > Parts Ordered > an IMEI**. Each wholly unissued part has **Cancel Part**. Expand it, optionally enter a reason and press **Confirm cancellation**. Cancellation and Issue share the existing **Issue parts** permission. No extra permission tick, Edge deployment, JWT setting or secret is needed.

The part disappears from active requirements in Parts and Lab; pending distinct-IMEI badges and picking reports use the remaining active requirements. An order with no remaining parts stays readable while open, showing **No Parts Pending** and its audit history. Lab may order the cancelled part again. Actor, time, original quantity and optional reason are kept in Parts activity and device history.

Already issued or partially issued parts must use the existing Return Part workflow. Completed or historical repair cycles, supplier-return holds and concurrent/stale requests retain their protections. Cancelling a requirement does not issue/return stock, change any issued price or alter services.

Normal lists stay paginated at 50; bulk issue selection and complete exports retain their existing behavior. Original receipt quantities, supplier-name permissions and all prior updates are preserved. Installation itself does not change business records; cancellation occurs only when an authorized user explicitly confirms it.
