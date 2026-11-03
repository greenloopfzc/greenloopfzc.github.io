# Initial QC dropdown save feedback

Version: 20261103-qc-dropdown-feedback-1

Live admin testing confirmed that Housing without Back cover already exists in the managed Part list. The save RPC returns its canonical existing name with changed=false. Matching is case-insensitive, so Housing Without Back Cover intentionally does not create a second duplicate.

The dialog's success/error paragraph had the form-message class, which defaults to display:none. Changing only its hidden property did not make the message visible. Its message handler now toggles the existing is-visible/is-success classes. Pending saves also display Saving and disable the submit control until completion. Saved, already-available and failed outcomes are visible, and errors retain the entered name for retry.

No saved part is renamed or duplicated. Phone entries, Grade D default/replacement behavior, permissions, database APIs and previous IMEI/Lab/Final QC updates are unchanged. No additional SQL, Edge Function, secret, JWT change or permission tick is needed.
