# Ready Stock grade card View phones controls

Prepared 11 November 2026. Frontend-only update; no new SQL or permissions.

Grade A, B, D, BA, BB and RMA Stock cards show plain centered counts, with
no clickable digits, raised digit buttons or underlines. A separate centered
View phones action opens the existing grade-specific current stock list.
Empty grades show 0 and a disabled View phones action. Existing model table
quantity links and current/daily stock calculations remain unchanged.

The raised card surface, theme support, existing permissions and 50-row detail
pagination are preserved. No business records are modified by this update.
The package includes and verifies previous Ready Stock Daily / QC Fast updates.

Run outputs/Publish-GreenLoop-Ready-Stock-Grade-Cards.ps1. If an earlier update
needs SQL, follow the existing clipboard instructions. This appearance change
adds no new SQL, Edge deployment, JWT setting, secret or permission tick.
After LIVE - VERIFIED press Ctrl+F5 > Ready Stock.
