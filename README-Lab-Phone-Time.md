# Per-phone Lab and Glass time

Each technician phone card and the Unassigned queue show a live elapsed-time strip. Time in Lab & Glass uses the current recorded LAB/GLASS stay, exactly as the existing delay history: internal moves and employee reassignment retain the stay; leaving and later re-entering begins a new stay. If the arrival movement was not recorded, the UI explicitly labels a saved employee assignment as Time with technician, or a saved work-step creation as Work line age. If none are recorded it shows Time not recorded.

The display uses the server clock anchored to the browser monotonic timer, updates locally each minute, and resumes on focus/visibility. Timer updates add no RPCs and do not rebuild phone forms. The existing combined workbench API supplies all parts/services and authorization data in one read; a read-only wrapper adds timestamps and an indexed current-stay lookup. Frame, business actions, drafts, supplier-name privacy and user permissions remain unchanged. A 48-hour elapsed value has a restrained amber emphasis.

Run the publisher and install the additive SQL it selects, then confirm installed_lab_phone_time_version = 20261028-lab-phone-time-1. Pending earlier updates are included conditionally. Existing records, Available Stock changes, page permissions and Office Only boundaries are retained. No Edge Function/JWT update is needed.
