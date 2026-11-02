# Overdue TV card appearance and oldest phone age

UI release `20261102-overdue-cards-1` retains the existing raised card shadows,
rounded shape and centered employee names/counts. Light cards use the normal
white/slate gradient; dark cards use the existing dark slate palette. The overdue pulse uses a neutral border while the raised shadows stay constant.
Red fill, red pulse colors and the red motion-preference border are removed.

Each employee card shows its total overdue phone count and `Oldest Pending: N
Days`, using the existing server-provided maximum `oldest_seconds`. Days are
completed 24-hour periods of the existing Sunday-free counted time. This is the
oldest phone's age, not the age of every phone. Clicking the card retains all
qualifying phones and their individual elapsed times in the details table.

No database definition, entry, permission, employee selection, switching timer,
monthly Damage rule or Sunday calculation changes in this release. It uses the
verified TV Month / Sunday database update. The cumulative publisher checks
previous installations, but this card update adds no new SQL or Edge service.

Run `outputs/Publish-GreenLoop-TV-Overdue-Cards.ps1`, then refresh the TV with
Ctrl+F5 after the published-files verification succeeds. TV settings belong to
the signed-in account; sign in using the Lab Damage account whose settings were
saved in User Access.
