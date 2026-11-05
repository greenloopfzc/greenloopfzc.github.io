# Separate Initial QC and Issuance badges

Initial QC counts only live phones whose inspection has not yet been saved.
Lab & Glass Issuance counts saved inspections still waiting for transfer.
The two values come from one read-only database snapshot and follow the exact
predicates of the inspection tray and Issuance options. No phone details or
technician list are downloaded for notification counts. Existing realtime,
post-commit, focus and polling refreshes are retained.

If the QC count read fails or returns malformed data, preserve the last verified
QC pair. Never fall back to the legacy inclusive Initial QC number. Other stage
badges still refresh. Both zero counts hide their own badges. Permissions and
Office Only are enforced with the existing Initial QC View access. No new tick.

The additive SQL creates a guarded counts reader and integrity marker. It does
not alter jobs, inspections, saved Issuance entries or transfers. Existing
50-record report pagination, full exports, paste/scanner trays and workflow
behavior remain. No Edge deployment, JWT change or secret is required.
