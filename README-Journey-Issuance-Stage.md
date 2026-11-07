# Journey destination and current stage

IMEI Search and Stock Journey now distinguish Lab & Glass Issuance from the shared Initial QC physical location in their compact journey. Recorded B-DEPT return destinations take priority over that location. The native event titles B Dept Passed Issuance and B Dept Passed Initial Qc are recognized; matching movement rows use evidence only from the same job and exact recorded time. INITIAL-QC and FINAL-QC code aliases are also recognized.

The current stage is passed from the newly read device record to the shared summary. It is explicitly marked at the end. Where the last dated milestone differs from the current stage, a current-stage row is displayed without inventing a timestamp or actor. Earlier visits, dates, raw activity counts and saved records stay unchanged.

This is presentation only. No stock or workflow is moved or renamed in the database. No new SQL, Edge Function, JWT, secret or permission tick is required for this fix. The publisher checks and can install missing earlier updates, including Sidebar Counts.

Run outputs/Publish-GreenLoop-Journey-Issuance-Stage.ps1. After LIVE - VERIFIED, press Ctrl+F5 and search again.
