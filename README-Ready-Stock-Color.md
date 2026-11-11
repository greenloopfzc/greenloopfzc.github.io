# Ready Stock: Show / Hide Color

12 November 2026

- All Ready Stock card popups open with Color hidden and different colors combined into one Model / GB / Grade / original Batch / Supplier line. Example: 14 / 128 GB Black 1 + White 1 = one line of 2. Different stocks, grades, storage sizes and suppliers remain separate.
- Show Color splits the summary by actual color. Hide Color combines it again. Totals remain unchanged; each summary is grouped and paginated on the server, not by merging only the visible page.
- Clicking a combined model line opens its exact IMEIs across all colors. In the IMEI view, Show / Hide Color only changes the visible column; it preserves the selected phones and independent 50-row pagination. Returning to the summary applies the current color choice. Reopening a card defaults to Hide Color.
- Total, grade, Daily Ready Stock and Daily Export share the same behavior. Raised design, whole-card clicks, silent cable handoff, date windows, Sunday-excluding averages, supplier name permissions and original receipt quantity labels remain in place.

One additive, read-only SQL installation is required for server grouping. It creates a separately guarded read endpoint and version check, preserves existing endpoints and integrity checks, and does not change stock, IMEIs, colors, grades, costs, history or access records. Uses existing Ready Stock view permission; no new permission tick, Edge Function, JWT or secret.

Run the prepared publisher. When it copies Ready Stock Color SQL, open a NEW Supabase SQL query, paste the clipboard directly, and run the complete query. Required final result:

`installed_ready_stock_color_groups_version = 20261112-ready-stock-color-1`

Return to PowerShell and press Enter. Wait for LIVE - VERIFIED, then Ctrl+F5. Preparation and local tests do not mean the public website is updated.
