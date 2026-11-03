# Final QC: Fail stays on one phone

Fail no longer propagates from the first tray line to the following lines. Checking or unchecking Fail changes only that phone's result. Existing Pass/B-DEPT selections on other phones stay intact.

Pass and B-DEPT retain their existing first-line carry behavior, including the protection for manually corrected or completed later rows. Adding more tray lines inherits Pass/B-DEPT from line 1, but never inherits Fail. Failure reasons and technician choices remain individual to each phone.

The below-phone failure panel, original table width, validation, permissions, Save/bulk-save, history and audited return API remain unchanged. This is a frontend selection change and adds no SQL, Edge Function, JWT, secret or permission requirement. The cumulative publisher checks all existing prerequisites as before.

Run outputs/Publish-GreenLoop-Final-QC-Single-Fail.ps1. After LIVE - VERIFIED, press Ctrl+F5 on Final QC. Local browser tests cover checking/unchecking Fail, existing Pass/B-DEPT defaults, manual exceptions, added rows, individual failure details, Save, permissions and unchanged tray width. Tests do not write live business records or claim live publication.

This combined release is based on GitHub commit b8a84128771f463e8d09e01df06fdd66fc6ddff4 and preserves its complete Lab Pending Workbench update. It integrates the Final QC selection change as a normal descendant commit; it does not replace newer GitHub history or use a force push.
