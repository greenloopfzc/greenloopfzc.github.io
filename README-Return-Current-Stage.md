# Return Stock prepared IMEIs: Current Stage

Version: 20261111-return-imei-stage-1

The Return Stock bulk/scanner list now shows S.No, IMEI, Stock / Batch No, Current Stage, Status / reason and Remove. Current Stage comes from the same canonical stage helper used by IMEI Search, including Lab & Glass Issuance, Lab & Glass, Final QC, B-DEPT and Ready Stock. Active supplier returns take precedence and show Supplier Return Requested, Return Pending or Returned to Supplier. Unknown phones show Not recorded; a failed/pending check never displays an invented stage.

The existing bulk preflight returns stages in the same request. No extra per-IMEI browser requests, automatic saves or workflow transitions are introduced. Wrong-stock rows remain red and block Save. Optional reasons, batch original quantities, aliases, permission checks and the existing atomic save are preserved.

The additive stage endpoint reuses the previous private stock check and leaves its implementation, version marker and public endpoint byte-identical. No business data is changed by installation or the stage read. Only the existing Return Stock entry permission and Office Only rules are used. No supplier/customer names or unrelated private fields are added.

Run outputs/Publish-GreenLoop-Return-Current-Stage.ps1. If needed, it first installs the previous stock check and then copies the Current Stage SQL. Paste each copied query directly into a NEW Supabase SQL Editor query and RUN it. Required last result: installed_return_imei_stage_version = 20261111-return-imei-stage-1. Press Enter in PowerShell after that result. No Edge Function, JWT, secret or permission tick is required. After LIVE - VERIFIED, Ctrl+F5.
