# Cable Reader speed and Battery Health

Version: 20261111-fast-bh-1

Run the supplied publish command on the Windows cable-entry PC. It first validates the installed reader and creates byte-for-byte backups, then updates only the recognized reader functions and matching launcher pins. It restarts only verified Greenloop processes, checks live version/health, and publishes only after successful verification. New PCs receive the same correction through IMEI Entry > Setup Cable Reader.

AppleSmartBattery direct MaxCapacity is now recognized as device-reported Battery Health. Explicit reported percentages take priority over raw/design capacity estimates. Any valid percentage above 100 is capped at 100. Values below 100 retain their normal reported percentage. Charging CurrentCapacity, raw LPEMData capacity in mAh and BatteryHealthMetric are not substituted for Maximum Capacity. Missing data remains unavailable. Capacity estimates remain labelled as estimates.

A five-second, per-device memory cache avoids repeating optional USB queries on every browser poll. Phone discovery and the multiple-device guard still run each time. Disconnects, discovery failures and different devices cannot inherit an old phone reading. Incomplete reads retry after one second. Read phone again bypasses the cache.

The connected iPhone was tested read-only using patched functions in memory: device-reported BH 100, successful first/cold reads around 5 seconds, forced fresh reads 1.8-2.5 seconds and same-device repeat reads 0.17-0.31 seconds. Timings vary with USB, Trust, phone and driver readiness. No phone settings, stock records or installed reader files were changed during preparation.

No new SQL, Edge deployment, JWT setting or secret is required for this reader update. The publisher preserves and verifies previous required installations. Auto Save and existing duplicate checks remain unchanged. Browser field validation and Complete Device Details also cap health above 100.

Verification: synthetic battery/XML and cache/discovery tests; preserved Android/HTTP/CORS boundaries; idempotent AST patching; eight local installer rehearsals; eight GUI setup rehearsals; read-only installed-source CheckOnly; browser UI/identity/refresh tests; setup payload and SHA pins; publisher no-force/tamper/failure/live verification rehearsals.
