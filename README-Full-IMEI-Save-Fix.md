# Full IMEI correction save fix

The save operation previously invalidated the single-row QC work-option usage cache with an UPDATE that omitted its WHERE clause. A production database with the safe-update guard rejects that statement with `UPDATE requires a WHERE clause`, rolling back the correction.

The corrected statement targets `where singleton = true`, matching the cache's boolean primary key and check constraint. Database safety protections remain enabled. No technician, phone, stock or correction-history records are changed by installation.

Migration 219 verifies the existing correction implementation and changes only that known cache update. It refreshes the implementation's existing Office and correction definition receipts, then verifies the complete existing workflow and the scoped save statement. Installation is idempotent and supports the Windows line endings already handled by the verification engine. Migration 217 also contains the scoped statement for new installations.

Run the current Full IMEI Workflow Correction publisher. After verifying the existing workflow, it copies the small save-fix SQL when necessary. Run that complete clipboard query in Supabase SQL Editor. Required result:

`installed_full_imei_save_fix_version = 20261029-full-imei-save-fix-1`

Return to PowerShell, press Enter and let publishing finish. Return to the open correction tab and choose Save audited correction again. If another user changed the phone meanwhile, reload it and review the correction first. The earlier failed transaction did not create a saved correction.

Checks use a disposable PostgreSQL database and a regression check of the SQL statement's WHERE clause. The production safe-update extension itself is not bundled with that disposable runtime.
