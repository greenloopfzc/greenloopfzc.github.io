# Initial QC managed choices and changeable Grade D Housing

Version: 20261103-qc-choice-defaults-1

Manage Dropdowns now maps its save/read RPCs to the existing Initial QC Manage Options/View grants. The previous missing write mapping blocked Add Part in the guarded shared client. Part, Service, Supplier Grade and GL Grade keep their separate lists and permissions. Housing Without Back Cover can be added as a normal part; names are not hardcoded. All pages refresh the shared permission catalog cache.

GL Grade D still selects Housing automatically. A user can replace that default in the same part dropdown, for example with Housing Without Back Cover. The replacement remains through Save and the existing first-row carry/new-row flow. Other rows with explicit exceptions stay isolated. Clearing the only part brings back the Housing default. Grade D still routes through Lab/Parts, retaining its existing B-DEPT restriction.

The new SQL changes only the private Grade D default helper: an empty parts list gets Housing; a supplied parts list is preserved. This prevents the server silently adding Housing again after an explicit choice. No existing phone, order, quantity, price, assignment, history, battery health or permission is changed. Diagnostic Battery Final BH 100 and original Initial BH remain intact. Existing private helper permissions, Office checks and audited order APIs are retained.

The publisher installs the small QC Choice Defaults SQL only when its version marker is missing, verifies it and then publishes. Required result: installed_qc_choice_defaults_version = 20261103-qc-choice-defaults-1. No Edge Function, JWT setting, secret or new permission tick is needed.
