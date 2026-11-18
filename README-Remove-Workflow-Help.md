# Remove workflow help

Removes informational Workflow help, Page help and generated explanatory Details throughout the shared layout and deletes the native Lab/B-DEPT workflow-help panel. Static workflow-side explanations no longer occupy screen space. Existing referenced description nodes stay hidden so their readers continue working. Actual phone/report/history details, connected-phone tools, filters, entry/Save controls, current Glass/Stock Out status, counters and errors remain available. No database/data/validation changes.

This release includes the preceding operational-loading fix. No new SQL is introduced for removing help. The publisher retains prior prerequisite/version gates; if an earlier update is missing, install only the SQL it explicitly copies before continuing. No live SQL, clipboard change or Git push is performed by Codex.
