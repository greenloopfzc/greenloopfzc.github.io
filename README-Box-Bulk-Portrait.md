# Box Entry bulk paste and Portrait print

Box Entry sends one RPC for the complete validated pasted list and renders the returned box snapshot once. It no longer performs one HTTP scan plus two reloads per phone. Invalid, duplicate or unavailable IMEIs are reported individually; accepted phones retain their normal draft Box Entry reservation. Save Box, printing confirmation and Accounts verification are unchanged. Single scans and draft line removal remain available.

The new endpoint serializes against the same existing box scanner lock, checks the selected box/revision before writing, calls the existing single-scan rules inside the database and returns the canonical workflow snapshot. It does not change prior routine definitions or installed business records. Page scan/edit and office-network checks remain required. A saved box or a stale revision cannot receive pasted lines. The in-flight write cannot be cancelled halfway. A lost response triggers one read-only box refresh, never an automatic write retry.

Print uses a named A4 Portrait page with compact header, seven visible packing columns and footer. Standard 50-phone sheets fit one page; each next 50 rows starts the next page. No IMEI is omitted. Printed counts tested: 1, 50, 51 and 100. Long arbitrary custom values may need additional paper rather than clipping text.

Validation: first CRLF/repeat LF installation; pre-existing routine/data/access snapshots unchanged; actual Ready Stock workflow and 50-phone batch; mixed errors; stale and saved boxes; single scans/removal; view-only, anonymous, private and Office Only denial; one-call browser paste; lost-response reconciliation; actual A4 PDFs with page counts and each IMEI exactly once.

Version: 20261109-box-bulk-portrait-1.
