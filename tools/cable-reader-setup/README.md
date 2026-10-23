# Guided Cable Reader setup

Build version: `20261023-cable-setup-1`. Supports Windows 10/11 x64, iPhone and Android. This is a per-Windows-user installer. It does not grant application permissions, change records or save entries.

The cable panels in IMEI Entry and Stock Journey provide a setup dialog and download. A localhost health check distinguishes a running current reader from an unavailable/outdated reader. Missing, stopped and browser-blocked readers cannot be distinguished reliably by a website; the UI offers the relevant recovery steps. A healthy helper is not proof of a working phone USB driver.

Run the downloaded `Greenloop-Cable-Reader-Setup.exe`, click **Install / Check reader**, finish the driver steps and click **Test connected phone**. Subsequent Windows sign-ins start the background reader automatically. If stopped, use the **Greenloop – Auto Reader** desktop shortcut. The EXE is built locally and is not Authenticode-signed; do not describe it as a signed/trusted publisher. Windows policy may require an administrator's approval. Do not disable Windows security protections to run it.

## Components

- Includes the reviewed read-only reader, dual-IMEI patch, hash-pinned launcher/supervisor and MSYS2 iPhone tools. Dynamically linked DLLs remain replaceable. Exact matching source packages, MSYS2 build recipes/patches, license texts and provenance are in `downloads/reader-sources.zip`.
- Downloads Android Platform Tools from Google's official HTTPS repository. Checks archive size and SHA-1 from official metadata, validates extraction paths, records individual SHA-256 file hashes, and reuses verified installed tools. No Android Studio install is required.
- Apple Devices / USB support: setup opens the official Microsoft Store page when the user clicks its button. The user installs it and approves Windows prompts. Existing Apple software is not removed. See [Apple's connection guide](https://support.apple.com/en-gb/108643).
- Android USB support: setup links the [official OEM driver list](https://developer.android.com/studio/run/oem-usb). The user installs the correct manufacturer's driver if Windows needs one. There is no universal Android USB driver; setup does not claim all brands are automatically installed.
- Trust and USB debugging approvals must be completed on the phone. Details unavailable from a particular phone remain manual. The test logs no device identities.

## Updates and recovery

All payload hashes and PowerShell syntax are checked before installation. Compatible existing reader source is patched surgically, preserving Android/custom functions. Unknown/partial sources and unrelated shortcuts are preserved and setup stops. Original touched files/shortcuts are backed up inside the reader folder. A failed file-write phase restores originals. A download/integrity failure occurs before replacing installed files. Startup/health failures remain explicitly incomplete and can be retried. No broad process kill, driver removal, firmware reset, local security exception or SQL action occurs.

The website does not execute an installer automatically. Download/run/driver installation are user actions. No browser POST installation endpoint is exposed. Existing page permissions still govern entry/edit. The setup download does not permit saving data.

## Rebuild

`Build-Setup.py` requires Windows, Python, .NET Framework's C# compiler and the declared MSYS2 tools/source packages. Set `--msys` and `--sources` to explicit local paths. It verifies the tool SHA-256 against the installed package `mtree`, collects the PE dependency closure, copies license texts and packages the corresponding sources. `Prepare-Reader.ps1` makes the fresh dual-IMEI reader and updates its two pinned hashes. Source/readme hashes are recorded in `downloads/cable-setup-manifest.json`. The EXE embeds a SHA-256-checked payload; rebuilding pins its current hash for the website publisher.

No backend migration is introduced by setup. Publishing requires the existing `20261023-dual-imei-1` database version; the supplied publisher checks that prerequisite and offers the existing guarded installer only if needed.
