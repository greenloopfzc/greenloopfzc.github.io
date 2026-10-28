# Shared Initial QC and Lab work choices

Initial QC has Manage Parts & Services for accounts with its Manage names & dropdown choices permission. Choose Part or Service, enter a name, and save. Adds are normalized and duplicate-safe, and names cannot conflict between a part and service. Existing Initial QC selections, IMEIs and grades remain in the tray. Existing per-row + buttons still add another selection.

Parts use the existing shared part-name options. Approved services have their own protected catalog, including the four existing Initial QC defaults and the Lab-only defaults. A new service is available in both pages and recognized by the server's Initial QC classifier, so it stays a service through QC findings, Lab service review and reporting. Services never become Parts orders. Name changes are audited.

Lab receives updated choices in its existing combined workbench read, with no extra per-row or polling requests. Timer metadata and drafts are retained. Other open tabs refresh on a local catalog event; other PCs receive choices on their next normal workbench read or when opening/refocusing Initial QC. The save API independently enforces Manage Options, active account, TV and Office Only guards.

Install the selected additive SQL through installed_qc_work_options_version = 20261028-qc-work-options-1 before publishing. Pending earlier updates are included. No Edge Function/JWT change is needed.
