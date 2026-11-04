# Full IMEI correction action mapping

The Reports workflow correction editor could prepare technician changes, but the
shared browser RPC guard rejected Save before contacting the database because
its runtime action map lacked `save_full_imei_workflow_v1`.

The runtime read and save rules now match the existing checked-in server rules:
Reports / Full IMEI Workflow Correction. View Only and other unrelated grants
cannot save corrections. Server authorization, Office Only, correction codes,
snapshot checks and permanent audit remain authoritative.

Prepared technician changes show the selected name instead of a roster UUID.
The Reports script versions are updated so a fresh page loads the corrected map.

No new SQL, Edge Function, JWT setting, secret or permission tick is required.
Publish the tested frontend, then reload Reports with Ctrl+F5. Reopen the IMEI,
prepare the active Lab technician assignment and recorded technician timer,
leave their timestamps unchanged, and save with the existing correction code.
Verify the permanent correction history and the new technician's Lab card.

Validation: real guarded-browser regression (old map reproduces the failure;
admin and explicitly granted staff save; View Only and unknown writes blocked;
backend rejection preserves drafts; light and dark review), plus the native
PostgreSQL-compatible assignment/timer save and Lab card movement reproduction.
