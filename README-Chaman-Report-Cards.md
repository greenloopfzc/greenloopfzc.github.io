# Chaman receipt / return report counters

Stock Balance Data is removed from both sections' report cards for now. Each section keeps its three main entry/Reports cards, and Reports opens two cards. The underlying stock-balance data/API and inventory math stay preserved; no records are deleted. The browser restricts report navigation to the two visible directions.

Every visible report has three summary cells:
- Greenloop Transferred Stock Data: Transferred to Chaman / Received by Chaman / Balance Pending.
- Greenloop Received Stock Data: Return From Chaman / Received By GL / Balance Pending.
- Chaman Received Stock Data: Transferred From GL / Received By Chaman / Balance Pending.
- Chaman Returned Stock Data: Returned To GL / Received By GL / Balance Pending.

Migration299 extends the already protected, filtered summary to return documents and return-phone details. Received on an outbound delivery means Chaman receiving; received on a return means Greenloop receiving. Pending is dispatched minus confirmed receipt. Totals aggregate all matching delivery quantities or filtered detail phones before50-row pagination. Completed receiving remains historical after a later trip. Empty matches produce zeros. PDF/Excel summary labels and document-list column labels follow the selected section/report. Missing or inconsistent totals cause an explicit error rather than an estimated result.

The installer is atomic, updates only matching routine integrity receipts and keeps the previous summary/flow/access markers valid. No user, stock, transfer, receipt or history records change during installation. Validation covers outbound50 /40 /10 after returns; return20 /10 /10 and aggregate75 /50 /25; reference/date/detail/empty filters; return55 /40 /15 over50+5 UI pages and full55 exports; original51-document and60-phone pagination cases; history after re-dispatch; unchanged installation/repeat snapshots; atomic rollback. Chrome checks both sections, all four label sets and counts, two report cards, Admin section switching, export data, desktop/mobile, missing-total handling and lock cleanup. No live SQL or publication was performed by Codex.
