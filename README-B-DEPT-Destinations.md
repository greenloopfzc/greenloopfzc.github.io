# B-DEPT routing-only destinations

Issuance accepts saved parts/services and any GL grade for B-DEPT. The immutable saved inspection remains linked to the phone; this transfer does not publish Parts orders or save Lab work. B-DEPT Pass destinations are Ready Stock, Lab & Glass and Final QC. Ready Stock retains its Final Grade requirement; Lab requires an active technician; Final QC activates the pending QC step directly. Fail stays B-DEPT.

B-DEPT no longer edits or assigns parts/services. The database rejects such payloads. On a Lab transfer, original saved inspection requirements are published without duplicate requests and services arrive saved through the existing Lab service seeding logic. Initial BH, histories, supplier-return protections, office access, entry permissions, stock quantities, report pagination and explicit bulk trays remain unchanged. No new permission tick is introduced.

Install migration 257 using the publisher's clipboard SQL, only when its verified marker is absent. No Edge, JWT, encryption key, driver or cable-reader installation is needed. Earlier reader port / battery details and Box print fixes are retained.

Validation: additive migration install and prerequisite integrity pass in the offline PostgreSQL fixture. Six transaction groups cover Grade D with saved requirements, each Pass destination, preserved Initial BH, no duplicate transfer, no early Parts orders, saved services, Fail retention, rejected parts edits, technician requirement, entry/office restrictions and private ledger access. Five actual DOM groups cover Issuance and all B-DEPT route controls / RPC payloads plus view-only. Mirrored scripts, cache tags and source pins are verified. No business records modified or live publication by Codex.
