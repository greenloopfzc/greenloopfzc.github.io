# Simple Parts orders and returns

Version: 20261026-parts-badges-1. Existing issues, prices, service records and return history are preserved. Services remain independent in Lab & Glass.

- Parts opens two cards: Parts Ordered and Parts Returned. Ordered opens phone requests and issue actions. Returned opens four categories (Damaged, Faulty, Not Needed, Other), with new returns in Awaiting Review until Parts classifies them.
- Lab can order a different part after an earlier issue. The same part needs a prior return request covering the new quantity. Each returned quantity can authorise only one replacement quantity; concurrent/stale/double requests are rejected.
- Lab can place the replacement request immediately after submitting the old part's return. Parts reviews that return before issuing its replacement. Rejecting the return cancels its unissued replacement request. Cancelling an unissued replacement releases its return quantity for a later request.
- Parts reviews classify only. No replacement request is created automatically, and there is no Replacement Required checkbox. Lab explicitly orders every additional/replacement part. Returned quantities no longer appear as active required parts in Lab. Completed returns stay in Parts Returned and history.
- Issued lines are preserved. Lab can remove only an unissued request; an issued part must use Return Part. Active repair cycles, revision checks and transaction guards apply to every action.
- Issued / Completed work is green; pending issue / return review is light red, including dark mode. Search/dates stay inside Filters and headings sort. Actual optional prices are returned only to Parts viewers.
- Existing Parts View, Issue, Return, Search and Sort ticks apply. Lab needs its Entry tick for new/cancelled orders. View Only, TV Only, Office Only and active staff checks remain enforced. No grants are added automatically.

Run Publish-GreenLoop-Parts-Badges.ps1. It chooses the required SQL bundle based on verified installed versions, preserves earlier updates, checks remote ancestry without force pushing and verifies the published files. Paste clipboard SQL directly into a NEW Supabase query when prompted. Final result:

installed_parts_badges_version = 20261026-parts-badges-1

No Edge Function, JWT or secrets change is required. Live installation and publication remain pending until that publisher completes.


Parts card badges count unique IMEIs, not part quantities or request rows. Ordered counts a phone once while any uncancelled part quantity remains unissued in its active Lab / Glass repair cycle. Returned counts a phone once while any of its returns still awaits review, including older pending returns without double counting reviewed copies. Partial issue/review leaves the phone counted until its last pending item is resolved. Counts ignore table filters and pagination. Zero badges hide. Initial loading and failed requests never display a fabricated zero.

Own saved changes refresh the badges immediately. Existing shared token Realtime updates refresh them across computers; private return writes now invalidate only that public token through a deferred trigger. No private return details are published. Office Only retains its existing guarded polling. Hidden tabs pause requests; focus/online/visibility changes refresh. Temporary errors retain the last known number. No new permission tick or Edge Function/JWT change is required; Parts View applies to counts.
