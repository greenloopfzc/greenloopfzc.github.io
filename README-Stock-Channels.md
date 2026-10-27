# Stock Received categories

Adds Repair Stock and RMA Stock to the existing database-backed Stock Channel dropdown. Existing equivalent names are reused and enabled; re-running the installer does not create duplicate choices. Existing receipt IDs, stock, suppliers, permissions and workflow are unchanged. These choices label receipts; they do not create a separate RMA repair workflow.

Run the supplied SQL in a new Supabase SQL Editor query. Required result: installed_stock_channels_version = 20261027-stock-channels-1. Refresh Stock Received afterwards. No GitHub publication, Edge Function or JWT change is required because the current page reads these database options on load.
