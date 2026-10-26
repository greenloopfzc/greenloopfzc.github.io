# Shared employees and unassigned Lab / Glass phones

Version: 20261026-employees-1

Initial QC can still send a phone without an employee. Lab & Glass now shows those phones in an Unassigned card, with the IMEI and phone details. Staff with Lab Entry permission can assign an employee there. Assignment does not move the phone or change its Parts / Services work, repair cycle or stock journey.

The existing technician roster and Damage employee choices share one directory. Active names from either list are combined without replacing existing IDs or history. Add or remove names through the existing permitted controls in Initial QC, Lab or Damage Entry. QC, Lab, Ready Stock rework and Damage Entry refresh their choices automatically, including other open PCs (normally within five seconds while visible, or on the existing live refresh signal). Unsaved form fields and selected employees are preserved. A name with pending assigned work cannot be removed until that work is completed or reassigned.

Damage reports, PDF choices and TV continue to read the employee choices. Existing TV employee selections still apply; a TV configured for selected employees does not automatically expose new employees. Login accounts are separate from employee names.

Installation: run outputs/Publish-GreenLoop-Employees.ps1 from the chat workspace. The pinned publisher verifies source hashes, GitHub ancestry and prior database receipts, chooses only the required SQL updates, verifies the installed version, safely pushes the tested commit and compares published files. No Edge Function or JWT setting change is required.

Required SQL result: installed_employee_directory_version = 20261026-employees-1.

Validation: disposable full migration chain and replay; shared IDs, add/archive/restore from all existing controls; unassigned and unknown-name phones; assignment with no workflow movement; View Only / Office Only / private data guards; browser checks for assignment, IMEI scan, list refresh preserving drafts on four pages, mobile dark mode and Frame regression. Live installation and publishing are separate from these local checks.
