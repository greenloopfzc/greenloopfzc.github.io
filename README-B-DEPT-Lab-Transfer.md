# B-DEPT Pass destinations

B-DEPT > Pending Work keeps Ready Stock as the default destination after Pass.
A Ready Stock pass still requires Final Grade and Final Battery Health.

Choose After Pass > Lab & Glass for phones requiring additional Lab work.
Select an active Lab technician, then use Assign parts / services to choose
required parts with quantities and saved services. Requirements stay in that
phone's draft until its Save button is pressed. Empty requirements are allowed
when only technician work is needed. Lab transfers do not require Final Grade.

Saving a Lab pass performs one transaction: record the B-DEPT pass, assign the
Lab technician, reopen/create the Lab visit, submit selected parts directly to
Parts Ordered and save the selected services in Lab & Glass. The phone does not
enter Ready Stock in between. Normal Lab completion sends it back to Final QC.
A part already pending or outstanding on the same job must use the existing
return process before it can be ordered again. Services remain separate from
Parts; no part prices are exposed on B-DEPT or Lab pages.

Fail records the result and keeps the phone in B-DEPT regardless of the selected
Pass destination. Existing Ready Stock APIs and validation are preserved.
Final Battery Health changes do not overwrite Initial Battery Health.
Previous Lab records, the original Lab-arrival clock and audit history remain.
Supplier-return holds, inactive accounts and Office Only rules still apply.

This uses the existing B-DEPT page and entry permission. No new permission tick,
Edge Function deployment, JWT setting or secret change is required.
Install 20261104_243_b_dept_lab_transfer.sql after verified Stock Grade Analysis.
Required result: installed_b_dept_lab_transfer_version =
20261104-b-dept-lab-transfer-1.
