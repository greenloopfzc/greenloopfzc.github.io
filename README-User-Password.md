# Admin password management

User Access > Greenloop Accounts with Page Permissions > select an account > Password.
Authorised administrators can Show/Hide a recorded password or Change Password.
Passwords newly created or changed here must contain 6–20 characters. Numbers alone
are accepted by the application; Supabase's project Auth policy also applies.
Existing login passwords are not restricted retroactively.

## Existing accounts

Supabase stores password hashes, so the previous passwords cannot be recovered.
Accounts without a recorded encrypted copy display “Not available”. Set a new
password once to enable Show. A password changed outside this service invalidates
its recorded copy. A mismatched or lost encryption key also prevents viewing;
setting a new password creates a fresh encrypted copy.

## Access

The signed-in account must be active, have Owner or Super Admin role, User Access
page edit access and its existing Edit users & permissions capability. View-only
and create-only accounts cannot view or change other passwords. Office Only rules
are checked at the service for every request. Only Super Admin may view/change a
different Owner/Super Admin account. An Owner can manage staff or their own password.
Changing your own password signs this browser out after confirmed success.

## Installation

Run the accompanying Publish-GreenLoop-User-Password.ps1. It checks all pinned files,
existing database versions and GitHub history before installation and publishing.
It stops on unverified, changed, or newer versions; it never force-pushes.

1. Run its complete SQL in a new Supabase SQL query. Required final result:
   installed_admin_password_change_version = 20261030-user-password-1.
2. Replace index.ts in the existing admin-create-user Edge Function with the complete
   copied file and deploy. Keep its existing Verify JWT with legacy secret OFF:
   the function verifies the signed-in user and server permissions itself.
3. Add the new GREENLOOP_PASSWORD_VAULT_KEY Edge Function secret when prompted.
   The publisher generates 32 random bytes on this PC and copies the base64 value
   directly to the clipboard. It never prints it or writes it to disk/source.
   Paste it only into the secret Value field and save. Do not replace an existing
   key: it must remain stable so recorded passwords can be decrypted. Retain a
   protected backup under your organisation's secret-management arrangements.
   Existing Supabase service secrets must not be changed.
4. Check Authentication > Sign In / Providers > Email password policy. To accept
   6-digit numeric passwords, set minimum length to 6 and no required character
   classes. Leave leaked-password protection unchanged. This dashboard policy is
   not exposed by the public settings API and is not claimed as automatically verified.

The publisher verifies the new database marker, Edge version and encryption-key
readiness before uploading. A green LIVE - VERIFIED result additionally confirms
published website files match the tested source. No live accounts or passwords
were changed while preparing/testing this release.

## Storage and audit

Login hashes stay in Supabase Auth. New admin-set passwords have AES-256-GCM
encrypted copies in a private table, with a fresh random nonce and user/request
binding. The encryption key exists only in Edge Secrets. Browser/anonymous roles
cannot read this table or invoke the service-only functions. Only a successful,
audited Show returns plaintext to the authorised browser over TLS. It is cleared
after 30 seconds, when hidden, when switching users, and when office access locks.
Passwords are never saved to localStorage/sessionStorage. No secret key is shipped
to the website.

Permanent audit metadata records requesting administrator, target, time and outcome
for changes and reveals. It stores no plaintext password. Requests are idempotent;
an interrupted response stays unconfirmed and Check status never replays a reset.
The Auth update and database audit use separate APIs; an ambiguous Auth response
can remain pending rather than falsely reporting success. After five minutes a new
manual change may be attempted; only confirmed records become viewable.

This update creates private management tables/functions. It does not alter current
passwords, delete accounts, change stock, or grant new page permissions.
