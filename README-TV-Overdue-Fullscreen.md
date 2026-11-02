# Overdue TV fullscreen layout

UI release `20261102-overdue-fullscreen-1` fixes overdue employee cards extending
below the screen after the application's Full screen button enables TV mode.

The wall measures the space below its actual heading and toolbar, then chooses
card columns and readable text sizes that fit the current viewport. It measures
real card contents, including long names, and gives rows a consistent height.
No employee is hidden, removed or truncated to fit. Neutral colors, raised
shadows, oldest pending days and each employee's phone count remain intact.

The layout recalculates on entering or leaving native fullscreen, resizing,
changing TV mode, switching to Overdue, refreshing cards and returning from phone
details. Exiting TV/fullscreen restores the ordinary browser card layout.
On narrow screens where every card cannot fit readably, the card area scrolls;
remote-keyboard focus can reach the last employee and its scroll position is
preserved. Employee phone details retain their normal table and paging layout.

This release changes only TV presentation. There is no new SQL, Edge service,
permission, selection, count, monthly damage or Sunday-clock change. Existing
five-second rotation and account-specific TV settings remain in place.

Run `outputs/Publish-GreenLoop-TV-Overdue-Fullscreen.ps1`. After LIVE - VERIFIED,
refresh the TV with Ctrl+F5 and use Full screen. The cumulative publisher checks
previous required installations; this release adds no database installer.
