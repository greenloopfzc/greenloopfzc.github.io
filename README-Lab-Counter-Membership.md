# Lab technician counters and phone membership

The supplied read-only live audit found matching current technician totals and
membership, with no duplicate active assignments, missing active Lab steps or
mismatched phone/job identities. The saved bulk handover commands matched their
responses and audit events. These findings describe that snapshot; the local
audit result file keeps the business counts separate from the website source.

Review found a latent difference in the existing readers: the card counts
require a current Lab/Glass job, but the employee phone reader could also return
an old in-progress Lab step after the job moved to Final QC. The disposable
native database reproduces this difference. This update filters the employee
reader to the same current job, step, physical phone and company custody
membership. It preserves every field of a retained phone, including parts,
services, visit timers, damage marks and history. The shared legacy technician
reader used elsewhere is unchanged.

In the browser, a successfully loaded complete technician list reconciles its
selected red counter. A focused IMEI or pasted subset cannot replace the full
card total. Roster signals use the coordinated card-and-list refresh, retaining
the existing draft/editor/bulk guard and trailing refresh. Show all fetches the
complete technician list after an IMEI search; unsaved changes must first be
saved or cancelled. Malformed count or
duplicate phone responses show an error instead of a fabricated zero/partial
list. Permission/Office lock discards late data.

No business records, assignments, statuses, parts or stock quantities are
rewritten. Individual and bulk transfer APIs retain their current server
checks, locks, idempotency and all-or-nothing behavior. Validation covers actual
Initial QC/Issuance, Final QC failure reassignment, B-DEPT, Ready Stock rework,
Reports technician change, Chaman dispatch/confirmed return, individual outgoing
handover and the protected bulk-transfer error/retry/rollback cases. Tests run
in disposable local fixtures; they do not perform production transfers.

The cumulative publisher verifies prerequisites and prompts for the exact SQL
in the affected Supabase project. Required result:
`20261118-lab-counter-membership-1`. The user installs the SQL and runs the
publisher; no live database change or publication is performed by Codex.
Refresh open software tabs after successful publishing.
