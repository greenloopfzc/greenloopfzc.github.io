# Shared browser action permission resolution

Release: 20261029-action-permissions-1

The original RPC action rules live under `rpcs`, while newer rules are top-level. The browser resolver read only top-level entries and `rpc`. This classified existing actions such as `execute_greenloop_deletion` and `save_user_access_office_v1` as unmapped writes even when the caller had the required grants. Both admin denials were reproduced before repair without reaching the mocked backend.

The shared resolver now reads top-level overrides, then `rpc`, then `rpcs`. It uses own properties only. Existing action-specific grants, dynamic deletion/reset scope, page capabilities and backend role checks remain authoritative. No blanket admin bypass or new permission grant is added. All literal write RPCs called from js/ have a catalog mapping. Pure read markers remain metadata; office access verification cannot deadlock permission loading.

The shared client uses that same raw rule when publishing successful workflow signals. Read RPCs never announce a write, including read markers and older unannotated get/list helpers. Denied or failed calls never announce success. An unmapped write stays blocked and now identifies the missing mapping instead of claiming the account lacks a configured grant.

Browser scripts and root mirrors match. All 27 HTML entry points referencing these shared scripts receive the new cache version. This client repair needs no SQL, Edge Function or JWT changes. The cumulative installer preserves all earlier verified database components and the IMEI save / Lab phone card fixes.

Verification uses isolated fixture data: full-catalog runtime grant checks, exact old admin denial reproduction, actual browser user access saving (including mobile dark mode), single IMEI and all-IMEI deletion review/confirmation, server rejection handling, restricted users and the 21-case IMEI Entry regression suite. No live IMEI was deleted, no live user permissions were changed, and no live publication was performed during testing.
