# Damage PDFs: generating account's selected employees

Release `20261102-damage-pdf-selection-1` applies the employee checkboxes saved in
User Access to the account generating a Damage PDF. It does not borrow another
TV account's choices. For example, an admin-generated PDF uses admin's selection,
while a Lab Damage-generated PDF uses Lab Damage's selection if that account has
the existing PDF download permission.

User Access exposes `Employees in Damage PDF / TV` for ordinary and protected
administrator accounts, without converting them to TV Display Only. The account
username is shown in the selection help. Existing full-access save, role,
protected-admin, Office Only and stale-edit checks remain unchanged. The existing
employee selection field is reused; no additional permission or account is added.

The PDF technician dropdown, combined/individual exports and their original/copy
values and monthly payable totals all follow the same selection. Selected active
employees with zero damage remain in the zero-damage section. Unticked employees
and their incidents are excluded before counting, pagination/export limits and
PDF calculations. All legacy PDF export versions apply the same filter. A direct
individual request for an excluded technician is rejected. An empty selection
returns no names or rows and disables PDF View/Download with a clear message.

NULL/All employees retains the existing meaning, including future employees;
Clear All is explicitly empty. Archived and unambiguous legacy-name incidents
remain available when selected. Employee catalog IDs are not merged. All original
damage history, prices, payroll formulas and operational records are preserved.
TV reader behavior, monthly TV damage, Sunday-free overdue time and fullscreen
layout are unchanged. Reports outside the Damage PDF export are unchanged.

Run `outputs/Publish-GreenLoop-Damage-PDF-Selection.ps1`. Paste the copied SQL into
a NEW Supabase SQL query and run the complete installer. Required final result:
`installed_damage_pdf_selection_version = 20261102-damage-pdf-selection-1`.
No new Edge deployment, JWT setting or encryption secret is required. After LIVE
- VERIFIED, press Ctrl+F5. In User Access select the account that will generate
the PDF, tick its employees and Save access. Reopen PDF View / Download.
