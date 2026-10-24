# Office-only access

Version: 20261024-office-access-1. Existing accounts default to Anywhere. No business records are deleted, rewritten or moved. The approved office network must be registered explicitly by an administrator; no current workstation or guessed subnet is automatically approved.

## Administration

User Access retains its three existing sections. Greenloop Accounts includes a collapsed Office networks panel; existing account and Add User forms include an Office Only tick (unchecked = Anywhere). Manage office networks is a separate User Access permission, restricted to Owner/Super Admin roles. Initially only existing administrators with Manage User Access get that new tick. Existing page, TV, price, employee, appearance, voice, entry and export permissions remain independent.

While on the office Etisalat connection: open Office networks, use the server-detected connection, confirm it belongs to the approved office, and Save. Check Wi-Fi and Ethernet devices before restricting accounts. Multiple public addresses and an explicitly verified IPv6 office prefix can be added; the software never guesses an IPv6 subnet from one address. LAN/private, carrier-private, invalid and excessively broad ranges are rejected. A dedicated/static ISP address is recommended: shared public egress cannot identify one office exclusively, and a changed address requires an approved-network update.

At least one active Super Admin stays on Anywhere for recovery. Network removal/deactivation cannot leave active Office Only accounts without an active approved network. An Office Only administrator cannot change networks so as to block their own current connection. Stale user/network revisions fail atomically with the original permissions preserved. New accounts receive page, partner and network permissions in one DB transaction; the existing Edge service cleans up Auth creation if setup fails.

## Enforcement

The hosted Supabase gateway's overwritten `cf-connecting-ip` is the only source address. There is no X-Forwarded-For, request-body IP, browser lookup, localStorage claim, geolocation or Wi-Fi-name fallback. Missing/malformed context fails closed for Office Only. The publisher must verify, over real HTTPS, that the nonce-bound gateway probe ignores or rejects forged address headers. The anonymous probe returns only a nonce-bound digest, never an allowlist, raw address or company data.

The Data API pre-request hook preserves and chains any prior hook. Restrictive RLS predicates supplement existing row permissions. Readable public views receive an additional network predicate. Callable application routines clone their exact original implementations and add an outer network check, covering function exposure via GraphQL as well as REST. Original role/action/TV guards remain inside. Unsupported invoker routines, unexpected owners or exposed tables without RLS stop installation for review. The harmless classification/own-partner-access predicates, trigger functions, installation version getters and own network status/probe are deliberate exceptions; they do not expose company records.

Office Only clients poll notification counts every two seconds rather than maintain a Realtime subscription without fresh per-message network context. Successful local actions keep their immediate notification refresh. Existing Anywhere clients retain Realtime. RLS also covers existing Storage objects if the schema is present; the current app does not use Supabase Storage. Previously downloaded files or data already observed cannot be revoked. IP rules identify the office internet connection, not physical presence; remote access through an allowed office VPN/proxy must be controlled separately.

The browser checks before entering the application/TV, watches server network denials, removes the page content on lock and checks on focus/online/visibility and periodic refresh. Expired/refreshed tokens are handled without trusting browser-selected network modes. View Only users can use Check connection and Sign out, but gain no entries or settings writes. Direct API attempts still meet the server guard even if the browser code is altered. Auth may issue a credential token; that token alone cannot bypass the company's data restriction.

The existing `admin-create-user` function verifies the caller with Auth, obtains role/action/network approval through a service-only DB context and passes only the original trusted gateway address into the atomic initializer. Never accept a client body IP or expose the service key. Deploy the supplied complete source into the existing function; keep its existing secrets and JWT setting. Only GET version receipt is public.

## Changes and future migrations

Migration196 preserves earlier version receipts while resealing only deliberately guarded function definitions and the three damage schema fingerprints affected by the added RLS boundary. Private original function/view copies and their hashes are retained. Replay preserves account network modes and intentionally unticked management permissions. The office version getter checks guarded routines, private-copy ACLs/hashes, configured pre-request hook, RLS coverage and view fingerprints. Any new data API routines or views must be reviewed and covered in future migrations; do not bypass or forge the installation receipt.

## Deployment and verification

Use the pinned Publish-GreenLoop-Office-Access.ps1 bundle. It checks source hashes, fetches GitHub before ancestry checks, offers guarded cumulative SQL only when needed, verifies the DB, verifies the real gateway anti-spoof behavior, requires the updated existing Edge function receipt, pushes without force and checks published files. Neither Office Only nor a network is auto-enabled by publishing. Configure the office network and selected accounts afterward.

Local tests use a disposable PostgreSQL instance, mocked Edge requests and isolated browser fixtures. They verify inside/outside, forged headers, current sessions, direct API/RLS checks, atomic permissions, stale writes, invalid ranges, IPv6, replay, previous versions, TV, View Only and desktop/mobile display. Live ISP uniqueness/stability, the real hosted gateway and a physical Wi-Fi/Ethernet transition are verified during/after deployment, not claimed by local fixtures.

Primary references: https://supabase.com/docs/guides/api/securing-your-api and https://developers.cloudflare.com/fundamentals/reference/http-headers/
