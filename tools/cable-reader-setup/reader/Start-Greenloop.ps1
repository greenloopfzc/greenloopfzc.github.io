#requires -Version 5.1
[CmdletBinding()]
param([switch]$OpenWebsite)

$ErrorActionPreference = 'Stop'
$supervisorVersion = '20261001-android-reader-2'
$expectedVersion = '20261001-android-reader-2'
$expectedReaderHash = '81CB25A4ADC0C48C8F72611E0463338462B4B4F875807B871825B591F0E4C0FA'
$readerScript = Join-Path $PSScriptRoot 'Greenloop-Device-Reader.ps1'
$watchScript = Join-Path $PSScriptRoot 'Watch-Greenloop-Reader.ps1'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$logPath = Join-Path $PSScriptRoot 'reader-launch.log'
$launchLock = $null
$ownsLaunchLock = $false
$watchProcess = $null

function Write-LauncherLog {
    param([string]$Event)
    # Fixed event text only; never record a health body or device identifiers.
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

function Test-SupervisorRunning {
    $probeLock = $null
    $ownsProbeLock = $false
    try {
        try { $probeLock = [System.Threading.Mutex]::OpenExisting($supervisorMutexName) }
        catch [System.Threading.WaitHandleCannotBeOpenedException] { return $false }
        try { $ownsProbeLock = $probeLock.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $ownsProbeLock = $true }
        return (-not $ownsProbeLock)
    } finally {
        if ($ownsProbeLock) { $probeLock.ReleaseMutex() }
        if ($null -ne $probeLock) { $probeLock.Dispose() }
    }
}

function Start-RegisteredSupervisor {
    # Prefer the registered task so Task Scheduler owns the long-lived process
    # and can apply its configured failure recovery. Only the exact per-user
    # Greenloop action is allowed; an unrelated task is never started.
    try {
        $taskName = 'Greenloop Cable Reader - ' + $userSid
        $expectedArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchScript + '"'
        $tasks = @(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop)
        if ($tasks.Count -ne 1) { return $false }
        $task = $tasks[0]
        $actions = @($task.Actions)
        if ($task.TaskName -cne $taskName -or $task.TaskPath -cne '\' -or
            $task.Settings.Enabled -ne $true -or $task.Principal.UserId -cne $userSid -or
            $actions.Count -ne 1 -or $actions[0].Execute -cne $powershell -or
            $actions[0].Arguments -cne $expectedArguments) {
            Write-LauncherLog 'scheduled_task_not_verified'
            return $false
        }
        Start-ScheduledTask -InputObject $task -ErrorAction Stop
        Write-LauncherLog 'scheduled_task_start_requested'
        $taskDeadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $taskDeadline) {
            if (Test-SupervisorRunning) { return $true }
            Start-Sleep -Milliseconds 200
        }
        Write-LauncherLog 'scheduled_task_start_not_confirmed'
    } catch {
        Write-LauncherLog 'scheduled_task_unavailable_or_start_failed'
    }
    return $false
}

function Get-ReaderHealth {
    param([int]$TimeoutSeconds)
    try {
        return Invoke-RestMethod -Uri 'http://127.0.0.1:51892/health' -TimeoutSec $TimeoutSeconds
    } catch { return $null }
}

function Test-ReaderReady {
    param($Health)
    return $null -ne $Health -and $Health.ok -eq $true -and
        $Health.service -ceq 'Greenloop Read-Only Device Reader' -and
        $Health.mode -ceq 'read-only' -and $Health.version -ceq $expectedVersion
}

try {
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $supervisorMutexName = 'Local\Greenloop.PhoneReader.Supervisor.' + $userSid
    $launchLock = New-Object System.Threading.Mutex($false, ('Local\Greenloop.PhoneReader.Launch.' + $userSid))
    try { $ownsLaunchLock = $launchLock.WaitOne(45000) }
    catch [System.Threading.AbandonedMutexException] { $ownsLaunchLock = $true }
    if (-not $ownsLaunchLock) {
        Write-LauncherLog 'another_launch_still_in_progress'
        throw 'Another Greenloop start is still in progress. Try the shortcut again shortly.'
    }
    if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf) -or
        -not (Test-Path -LiteralPath $readerScript -PathType Leaf) -or
        (Get-FileHash -LiteralPath $readerScript -Algorithm SHA256).Hash -ne $expectedReaderHash) {
        Write-LauncherLog 'installed_files_missing_or_reader_hash_mismatch'
        throw 'Greenloop reader files need repair. Run the reader auto-start repair again.'
    }

    # Even a healthy reader needs its supervisor for recovery after a later exit.
    if (-not (Test-SupervisorRunning)) {
        $startedByTask = Start-RegisteredSupervisor
        if (-not $startedByTask -and -not (Test-SupervisorRunning)) {
            $watchProcess = Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $PSScriptRoot `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $watchScript + '"')) -PassThru
            Write-LauncherLog ('supervisor_requested_' + $supervisorVersion)
            $watchDeadline = [datetime]::UtcNow.AddSeconds(10)
            while (-not (Test-SupervisorRunning)) {
                if ($watchProcess.HasExited -or [datetime]::UtcNow -ge $watchDeadline) {
                    Write-LauncherLog 'supervisor_start_not_confirmed'
                    throw 'Greenloop background recovery did not start. Run the reader auto-start repair again.'
                }
                Start-Sleep -Milliseconds 200
            }
        }
    }

    # Allow the reader's entire 18-second USB operation before expecting health.
    # Timeouts only affect this launch result; they never kill/restart a reader.
    $ready = $false
    $healthDeadline = [datetime]::UtcNow.AddSeconds(45)
    while ([datetime]::UtcNow -lt $healthDeadline) {
        $remainingSeconds = [int][math]::Ceiling(($healthDeadline - [datetime]::UtcNow).TotalSeconds)
        if ($remainingSeconds -le 0) { break }
        $health = Get-ReaderHealth ([math]::Min(22, $remainingSeconds))
        if (Test-ReaderReady $health) { $ready = $true; break }
        if (-not (Test-SupervisorRunning)) {
            Write-LauncherLog 'supervisor_exited_before_ready'
            throw 'Greenloop background recovery stopped. Run the reader auto-start repair again.'
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Write-LauncherLog 'reader_readiness_timeout_or_different_service'
        throw 'Greenloop reader is not ready yet. Background recovery is still watching; try the shortcut again shortly.'
    }
    Write-LauncherLog 'reader_ready'
    if ($OpenWebsite) { Start-Process 'https://greenloopfzc.github.io/' }
} catch {
    Write-LauncherLog 'launch_failed'
    # Bounded failure: no modal dialog, infinite popup, or arbitrary process kill.
    Write-Error 'Greenloop did not finish starting. See reader-launch.log beside the installed reader, then run the reader auto-start repair if needed.' -ErrorAction Continue
    exit 1
} finally {
    if ($null -ne $watchProcess) { $watchProcess.Dispose() }
    if ($ownsLaunchLock) { $launchLock.ReleaseMutex() }
    if ($null -ne $launchLock) { $launchLock.Dispose() }
}
