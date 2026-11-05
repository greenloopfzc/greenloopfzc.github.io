# Content-sized tables and left serial numbers

The shared table enhancer puts generated S.No first, with a compact intrinsic
width. Existing flat serial columns move left without changing their numbers.
Regular tables use automatic content layout instead of percentage/fixed widths.
The heading, values and controls determine the space required. Table containers
scroll horizontally when necessary; cells do not crop the final action buttons.
Initial QC keeps a complete Direct Ready Stock checkbox and Save button.

Grouped multi-row workbench layouts and label/PDF summary components retain
their specialized structure. Normal report paging remains 50. No business data,
sorting keys, save routes, permissions, exports or SQL routines are changed.
The existing embossed theme is retained. Page cache references are revised.

Run Publish-GreenLoop-Table-Content-Layout.ps1. This layout needs no new SQL,
Edge deployment, JWT change, secret or permission checkbox. The publisher still
verifies and, if missing, installs the previous reviewed updates. Publication is
manual with pinned files and a normal descendant push; no force push is used.
