# Remove only the generic Housing part option

The exact part name Housing is retired from the shared active part-name catalog used by Initial QC, Issuance, Lab, Inventory and other part selectors. Matching ignores case and surrounding spaces. Housing (4G), Housing (5G), Housing 4G, Housing 5G, Housing Accessories and all other distinct names remain unchanged. Housing repair services are unchanged.

Initial QC no longer creates or selects generic Housing automatically for GL Grade D, on either the screen or server. Nothing is automatically renamed or replaced with a 4G/5G variant. Select the actual required variant manually. Existing Grade D routing/direct-ready restrictions remain.

The master option is deactivated without deleting historical part requirements, issues, installations, inventory quantities, prices or audit records. Historical saved Housing entries remain readable and usable for completing existing work. All option creation/reactivation APIs share a database guard so Manage Dropdowns cannot bring the exact name back. Specific variants remain available for normal creation, selection and saving.

SQL315 preserves private helper permissions and matching existing integrity receipts. It also verifies retries of pre-update Grade D saves whose empty part payload previously auto-generated Housing; these retries return their exact saved result without recreating parts. Changed/new requests still use existing checks. New Grade D empty saves contain no Housing requirement.

Run the accompanying publisher yourself. When it copies Install-Remove-Generic-Housing.sql, paste the complete SQL into a NEW Supabase SQL Editor query and run it. Required result: `20261116-generic-housing-retired-1`. Return to PowerShell and press Enter only after that successful result. The publisher verifies the database version before publishing. This branch also includes the preceding Returned Grade Report and single workflow editor fixes. Codex did not run live SQL or push.

Validation: actual protected master-option readers, create/reactivate RPCs, intake/QC saves and old receipt replay in a disposable PostgreSQL-compatible database; exact variants/catalog IDs preserved; no historical phone/QC/issuance records rewritten; LF/repeated/Windows CRLF install, atomic rollback and disabled-trigger detection. Actual shared Initial QC access/RPC guard and native catalog fixtures verify no Grade D auto-add, manual 4G/5G selection, row carry and exact save payloads. Assets and root mirrors use the same code.
