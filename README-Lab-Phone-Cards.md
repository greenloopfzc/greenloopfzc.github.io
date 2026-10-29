# Separate Lab phone cards

Each Lab / Glass phone has its own bordered, raised work card with a 24px gap between phones (22px on small screens). The card header prominently shows the IMEI and model with the existing elapsed time and parts status. All original device details, parts, services, returns and job controls remain inside the same card.

Clicking within a phone card or focusing one of its controls highlights only that card and shows Active phone. The highlight survives normal re-rendering for the same step; switching technicians clears the selected phone. An IMEI scan selects the matched card. Assignment cards use the same phone identification and separation. Frame tables retain their existing layout.

No RPC, database schema, business calculation or access grant changes are made by this visual update. QC-to-Parts ordering, additional part / returned replacement rules, price privacy, report filters and totals remain included. The cumulative publisher verifies earlier required updates first and installs them only if missing.

Run outputs/Publish-GreenLoop-Lab-Phone-Cards.ps1, wait for GREENLOOP LAB PHONE CARDS LIVE - VERIFIED, then refresh with Ctrl+F5. This layout change needs no new SQL, Edge Function or JWT setting. Live publication remains pending until the publisher succeeds.
