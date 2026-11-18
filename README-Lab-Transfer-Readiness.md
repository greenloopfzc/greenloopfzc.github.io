# Lab phone finder and compact handover notices

Find phone by IMEI in the main Technician workbench opens the exact current
phone and its assigned technician, including when parts, services or a part
return review are pending. It reads work details through the existing protected
workbench API, without calling the handover preview or requiring Entry access.
The phone's saved work remains available for the existing editing workflow.

A single scan/paste selects the real technician even after a multi-IMEI result
list. IMEI2 resolves to IMEI1. Multi-paste opens all matching current Lab/Glass
phone details; a wrong-stage/not-found IMEI receives a lookup notice. A partial
or late read cannot silently erase existing work or restore data after a lock.
Search never transfers a phone or labels pending work ready for Final QC.

Bulk Transfer preparation still accepts only verified ready phones. The main
Job Completed action still makes the fresh readiness preflight and then uses
the original protected atomic completion API. Parts/services/return review,
custody, revision, duplicate and current-stage checks remain in force. Bulk
uncertain responses retain the exact actor-bound retry command.

Warnings use a compact IMEI / short reason / current stage table. Examples:
Parts pending, Services pending, Part return pending, Not in Lab & Glass, or
Chaman receiving pending. The long server paragraph is not repeated above and
inside the table. Mixed-paste results retain every rejected IMEI; cells wrap and
single-phone notices omit an unnecessary repeated summary. OK/Escape returns
focus to the same empty scanner when its request and access are still valid.

The owned Bulk Transfer scanner does not also launch the generic stage popup.
Lab and generic IMEI notices dismiss the older notice before showing a newer
one. Dismissal invalidates its pending response and callbacks, so an older
warning cannot remain underneath or reopen after OK. A stale notice request
cannot close the currently relevant popup. Other workflow confirmations remain
independent.

This correction changes browser behavior only. No new SQL migration is needed;
the cumulative publisher verifies the existing prerequisites, including the
previous Lab readiness version `20261118-lab-transfer-readiness-1`. No stock,
parts, services, assignments, timers or history are rewritten. Refresh open tabs
after successful publishing.

Validation uses actual browser pages with the shared permissions/RPC guards:
pending parts/services/returns find the correct technician, canonical identity,
mixed search paste, switching back to a single phone, wrong-stage lookup,
Show all, view-only search, late Office rejection, compact grouped bulk warnings
and explicit Job Completed readiness. Existing server SQL is byte-identical to
the previously tested readiness package. No production phone is moved in tests.
