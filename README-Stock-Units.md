# Original stock units and compact exchange reports

Original received quantity remains fixed. Supplier Stock, IMEI DATA and shared stock readers group linked replacements into the existing immutable original unit instead of adding them to purchased stock. Historical return events and old/new phone details remain available. Example:342 original +7 replacements retains342 units,41 historical returns and308 stock balance before other movements. Current workflow availability includes the replacement, and legacy replacement receiving awaiting IMEI remains in pending company stock. Initial QC grade analysis retains original phones.

Accounts opens Verify Box, Supplier Stock, Customer Stock and IMEI DATA with closed detail tables. Explicit cards/search/filters reveal data. Supplier and IMEI use one8-card summary. Chaman has two centered rows of dispatched, historical received and pending balance cells. Dispatch removes availability immediately; confirmed Greenloop receiving restores it.

Returned phones in Accounts and Stock Replacement have one exact paired row: old IMEI/Model/GB/Color, arrow, actual new IMEI/Model/GB/Color. Accounts retains its original Supplier, Batch, Invoice, Date Received and Stage fields. Both IMEIs and Details use the originating page's authorized popup. Composite headers opt out of generic serial injection. Columns use their content and fill the available width; narrow screens scroll horizontally.

UI pages remain50 complete units/exchanges. Complete snapshot-checked PDF/Excel exports keep original counts, actual different GB and exact exchange links; pairs never split across PDF pages. This changes read/display routines only, preserving stock, access, saved return/replacement records and prior fixes.

Install supabase/migrations/20261113_306_stock_units.sql after the verified Exchange Pairs305 update. Expected marker:20261113-stock-units-1. The installer is atomic, repeatable and tested with LF/Windows CRLF; integrity receipts update only when their reviewed before-hash matches.
