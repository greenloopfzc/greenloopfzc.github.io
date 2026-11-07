# User Access refresh fix

The report-permission refresh inside tvModeChanged referenced checkbox, which only exists in the change-event handler. This caused the initial account editor and post-save reload to fail with "checkbox is not defined" even after the atomic save had succeeded.

The refresh now disables report actions using the actual TV/page lock and report selection, preserving saved choices. Event-driven unchecking still clears dependent actions. Successful verified account reloads clear stale top-level errors. Genuine save or read failures remain visible; no retry or second save is performed automatically.

No permissions, accounts, passwords, stock or business data are changed by installing this presentation fix. No new SQL, Edge Function, JWT, secret or permission tick is required. Earlier pending updates are checked by the publisher.

Run outputs/Publish-GreenLoop-User-Access-Refresh-Fix.ps1. Wait for LIVE - VERIFIED, then Ctrl+F5 > User Access. Permissions already saved do not need to be re-entered because of the old refresh error.
