# Stable Windows Cable Reader Setup — 12 November 2026

The Google repository currently contains stable 37.0.1 and canary 37.0.3 Windows Platform Tools entries. The old selector found both and rejected the metadata. The new selector filters channel-0/non-preview/non-obsolete packages, sorts numeric revisions, and requires exactly one Windows archive in the newest stable release. Ambiguous or unsupported metadata still fails closed. Official Google URL, filename, size/checksum, safe extraction and recorded file-hash checks remain enforced.

Google reference: https://developer.android.com/tools/releases/platform-tools
Metadata tested: https://dl.google.com/android/repository/repository2-1.xml

The website now downloads a portable ZIP. Extract All and run Install-Greenloop.cmd on each Windows 10/11 x64 PC that connects phones. The website and phone reader must run on that same PC. No old Setup EXE is rebuilt or restored. Apple reader binaries retain the previously verified package hashes and bundled licenses. Android tools are fetched from Google during installation. The new battery-health source correction is included.

Existing compatible reader functions, custom extensions, identity guards and Windows startup pins are preserved. A per-user backup is created before changes. Partial installations or unrelated shortcuts are rejected rather than overwritten. No Supabase change or business-record modification is involved.

Verification:
- Real Google metadata reproduced the two-archive failure, then selected stable 37.0.1.
- Real official Windows ZIP download passed size/SHA1 checks, safe extraction and 14 resulting file hashes.
- Synthetic stable sorting, preview-only, preview revision, duplicate stable and missing-Windows cases passed.
- Eight isolated installer rehearsals passed: fresh, existing custom extension, repeat, partial, unrelated shortcut, download failure, write rollback and CheckOnly.
- Actual installed-reader CheckOnly passed without modifying files/processes.
- Chromium setup-dialog checks passed for ready, outdated, offline and mobile, including ZIP links and extraction instructions.
- This does not claim installation or USB verification on the user's other PC. Run the new package there.
