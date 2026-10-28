# Initial QC Manage Dropdowns

The management button is now Manage Dropdowns. Its Type selector offers Part, Service, Supplier Grade and GC Grade. Grade lists are independent: adding D to Supplier Grade does not add it to GC Grade. Names are normalized and grade codes are stored in uppercase. Existing defaults (including supplier-only Unsorted), stock grades and open tray selections are retained. New rows receive the latest choices. Part/service management and shared Lab choices continue to work.

The existing reviewed Initial QC grade validator now checks its saved catalog instead of fixed A+/A/B/C allow-lists. Only its two allow-lists, normalization and error messages change; existing role and entry guards, row locks, workflow routing and atomic updates remain intact. New grades work on normal Lab, no-work Final QC and direct Frame paths. Unknown grades are rejected. Grade additions require Initial QC Manage names & dropdown choices, are audited, and honor Office/TV restrictions.

Install the publisher-selected additive SQL and confirm installed_qc_dropdowns_version = 20261028-qc-dropdowns-1. Earlier pending updates are included conditionally. No Edge Function/JWT changes are needed. The route and existing permission keys remain the same.
