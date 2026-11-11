# Box Entry continuous scanner focus

Version: 20261111-box-scan-focus-1

After each successful or rejected IMEI scan, the Box Entry field clears and regains focus after disabled-identifier copy mirrors finish their animation-frame display update. The scanner is ready for the next phone without another mouse click. This also applies after bulk completion, deleting a draft/error line and starting the next box.

Complete 15-digit scans support both Enter and Tab scanner suffixes. Partial text retains normal Tab navigation. Starting the explicit scan clears its delayed timer so the same scan is not scheduled again after Enter/Tab. Existing busy guards, one-scan writes, printable red issue rows and bulk API behavior remain unchanged.

Focus recovery is bounded to two animation frames, uses preventScroll, and does not grab focus from another editable field or open dialog. Hidden Box Entry workspace, closed/full boxes, missing scan permission, Office Only lock, signed-out state and page exit cannot regain scanner focus. The identifier-copy exception for saved/disabled values remains unchanged.

This is a frontend-only change. No new SQL, Edge Function, JWT, secret or permission tick is needed. The publisher verifies the bundled preceding installations, source pins and safe Git ancestry before upload, then verifies the published static files. Run outputs/Publish-GreenLoop-Box-Scan-Focus.ps1. After LIVE - VERIFIED, Ctrl+F5 > Box Entry, then scan consecutive phones without clicking again.

Local real-Chromium regression reproduces the original lost focus with actual content protection, shared scanner/bulk code and permission guard. The corrected version passes consecutive Enter/Tab scans under delayed responses, rejected scan recovery, bulk completion, hidden workspace and Office Only lock checks. No live business records were created by these isolated fixtures.
