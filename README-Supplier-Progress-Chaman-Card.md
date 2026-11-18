# Supplier Progress Chaman card

Adds one full-width mint Chaman Shop card beneath the existing Supplier Progress summary, with Sent to Chaman / Received Back from Chaman in two centered cells separated by a slash. Uses the existing protected server fields chaman_sent and chaman_return_received over the same complete filtered row set as the other cards. Counts follow supplier/batch/invoice/model/search and receipt-date filters. Sent is historical dispatch; received back is confirmed Greenloop receiving. These values are separate from current outside/transit stock. Original quantities, stage counts, existing table/export data, permissions and workflow actions are unchanged.

No new SQL for this card. The publisher includes the previous Issuance grades, loading and help-removal updates with their prerequisite checks. If a prior database update is missing, run only the SQL the publisher explicitly requests. Codex does not install live SQL or push/publish the website.
