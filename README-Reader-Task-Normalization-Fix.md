# Reader startup verification correction

The reported error was Triggers/LogonTrigger/Enabled. The installed task backup confirms Windows omitted Enabled=true, and stored the logon account as a Windows name. The previous verifier compared literal fields and rejected this valid normalization. Windows schema defaults are documented at https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-schema .

The verifier now resolves omitted defaults, XML booleans/durations, SID/account names and equivalent Windows paths. It still rejects unsafe missing/non-default settings, disabled tasks/triggers, wrong identities/actions, battery restrictions, elevated privilege and finite execution limits. Action/principal bindings remain checked. Registration ownership and rollback behavior are preserved. The installed USB reader code is not changed by this repair.

Verified with the actual saved Windows XML format in memory (only the intended non-default new settings added), normalized registration/repeat/rollback rehearsals, numeric booleans,18 changed-setting rejections and6 unsafe missing-setting rejections. No native task registration or reboot is claimed from this sandbox.

The one-time repair command is unchanged: outputs/Fix-GreenLoop-Reader-AutoStart.ps1. Its helper hashes and the existing combined publisher/package are regenerated. New ZIP downloads use an updated cache query. No database SQL or stock/battery business data change is needed for this correction.
