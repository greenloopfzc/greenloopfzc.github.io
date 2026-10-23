#requires -Version 5.1
[CmdletBinding()]
param()

# This supervisor starts only the unchanged, read-only reader next to this file.
# It has no command, script-path, port, or test-injection parameters.
$ErrorActionPreference = 'Stop'
$supervisorVersion = '20261001-android-reader-2'
$expectedReaderHash = '81CB25A4ADC0C48C8F72611E0463338462B4B4F875807B871825B591F0E4C0FA'
$readerScript = Join-Path $PSScriptRoot 'Greenloop-Device-Reader.ps1'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$logPath = Join-Path $PSScriptRoot 'reader-supervisor.log'
$readerPort = 51892
$supervisorLock = $null
$ownsSupervisorLock = $false
$ownedReader = $null

function Write-SupervisorLog {
    param([string]$Event)
    # Callers use fixed event text only: no phone data or exception messages.
    try {
        $entry = '{0} {1}' -f [datetime]::UtcNow.ToString('o'), $Event
        $entryBytes = [System.Text.Encoding]::UTF8.GetByteCount($entry + [Environment]::NewLine)
        if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and
            ((Get-Item -LiteralPath $logPath).Length + $entryBytes) -gt 65536) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
        }
        $entry | Add-Content -LiteralPath $logPath -Encoding UTF8
    } catch { }
}

function Test-ReaderFile {
    return (Test-Path -LiteralPath $readerScript -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $readerScript -Algorithm SHA256).Hash -eq $expectedReaderHash)
}

function Test-ReaderPortAvailable {
    # A short bind check avoids opening an empty HTTP connection, which would
    # occupy the single-threaded reader while it waits for request headers.
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $readerPort)
    try {
        $probe.Server.ExclusiveAddressUse = $true
        $probe.Start()
        return $true
    } catch [System.Net.Sockets.SocketException] {
        return $false
    } finally {
        $probe.Stop()
    }
}

function Test-ReaderStartAvailable {
    $readerLock = New-Object System.Threading.Mutex($false, ('Local\Greenloop.ReadOnlyDeviceReader.' + $readerPort))
    $ownsReaderLock = $false
    try {
        try { $ownsReaderLock = $readerLock.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $ownsReaderLock = $true }
        if (-not $ownsReaderLock) { return $false }
        # Hold the reader's mutex during the brief bind probe so a simultaneous
        # direct reader cannot lose its bind to our availability check.
        return (Test-ReaderPortAvailable)
    } finally {
        if ($ownsReaderLock) { $readerLock.ReleaseMutex() }
        $readerLock.Dispose()
    }
}

function Start-OwnedReader {
    return Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $PSScriptRoot `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $readerScript + '"')) -PassThru
}

function Invoke-ReaderSupervisor {
    $retrySeconds = 1
    $waitingForExistingReader = $false
    while ($true) {
        # The existing reader may be in the middle of its 18-second USB read.
        # A busy port or held reader mutex is never treated as process death.
        if (-not (Test-ReaderStartAvailable)) {
            if (-not $waitingForExistingReader) {
                Write-SupervisorLog 'existing_reader_or_busy_port_waiting'
                $waitingForExistingReader = $true
            }
            Start-Sleep -Seconds 2
            continue
        }

        if (-not (Test-ReaderFile)) {
            Write-SupervisorLog 'reader_file_missing_or_hash_mismatch'
            throw 'The installed reader file needs repair.'
        }
        $waitingForExistingReader = $false
        $startedAt = [datetime]::UtcNow
        try {
            # The reader acquires its own mutex before binding. If a direct
            # launch wins between our checks and this start, this child exits
            # harmlessly and the next pass observes the existing reader.
            $script:ownedReader = Start-OwnedReader
            Write-SupervisorLog 'reader_started'
            while (-not $script:ownedReader.WaitForExit(2000)) { }
            Write-SupervisorLog 'owned_reader_exited'
        } catch {
            Write-SupervisorLog 'reader_start_or_monitor_failed'
        } finally {
            if ($null -ne $script:ownedReader) {
                # Disposing the handle never terminates the child. No process
                # is found by name or killed, including at supervisor shutdown.
                $script:ownedReader.Dispose()
                $script:ownedReader = $null
            }
        }

        if (([datetime]::UtcNow - $startedAt).TotalSeconds -ge 60) { $retrySeconds = 1 }
        Write-SupervisorLog ('retry_in_{0}_seconds' -f $retrySeconds)
        Start-Sleep -Seconds $retrySeconds
        $retrySeconds = [math]::Min(30, $retrySeconds * 2)
    }
}

try {
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $supervisorLock = New-Object System.Threading.Mutex($false, ('Local\Greenloop.PhoneReader.Supervisor.' + $userSid))
    try { $ownsSupervisorLock = $supervisorLock.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsSupervisorLock = $true }
    if (-not $ownsSupervisorLock) { exit 0 }
    Write-SupervisorLog ('supervisor_started_' + $supervisorVersion)
    if (-not (Test-ReaderFile)) {
        Write-SupervisorLog 'reader_file_missing_or_hash_mismatch'
        throw 'The installed reader file needs repair.'
    }
    Invoke-ReaderSupervisor
} catch {
    Write-SupervisorLog 'supervisor_stopped_with_error'
    exit 1
} finally {
    if ($null -ne $ownedReader) { $ownedReader.Dispose() }
    if ($ownsSupervisorLock) { $supervisorLock.ReleaseMutex() }
    if ($null -ne $supervisorLock) { $supervisorLock.Dispose() }
}
