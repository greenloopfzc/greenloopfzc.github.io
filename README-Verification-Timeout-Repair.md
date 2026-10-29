# Database verification timeout repair

The Full IMEI Correction publisher previously called release-version functions that recursively rechecked earlier releases. Shared dependencies were evaluated repeatedly. Supabase returned HTTP 500 / PostgreSQL 57014 when this work reached its statement timeout. Retrying did not reduce the repeated work.

Migration 218 adds a metadata-only verification endpoint. Its private reviewed catalog contains 75 version components and their dependency order. A result is computed once for each component and reused within that request. The verifier checks original function bodies, settings, language, execution grants, existing routine receipts, RLS, triggers and other original integrity conditions. Caller parameters, session settings and persistent cached success flags are not trusted. Its private functions and receipt table are inaccessible to application users. The public endpoint exposes only version check outcomes.

Original version getters and business routines are not replaced. No existing stock, employees, entries or permissions are changed. Definition mismatches, missing dependencies, changed security boundaries and network errors still stop publication.

The revised publisher first requests `get_installation_verification_version`. If it is missing, it copies `Repair-Database-Verification.sql` to the clipboard and pauses for the user to run it in a new Supabase SQL Editor query. Required result:

`installed_verification_engine_version = 20261029-verification-engine-1`

After Enter, the script verifies the result, selects the required Full IMEI Correction SQL and continues normal database and published-file verification. No Edge Function/JWT changes are needed. CheckOnly never contacts the database or copies SQL; VerifyDatabaseOnly does not install the engine.

Validation uses disposable PostgreSQL and mocked HTTP/PowerShell. Local timing is evidence of reduced duplicate work, not a measurement of the live Supabase project. The live repair is complete only after the SQL result and publisher verification succeed.
