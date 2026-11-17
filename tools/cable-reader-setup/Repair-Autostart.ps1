#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Reader-Startup.ps1')
. (Join-Path $PSScriptRoot 'Reader-Autostart.ps1')
$root=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\Greenloop\ReadOnlyDeviceReader'
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sources=@{};foreach($name in @('Greenloop-Device-Reader.ps1','Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){ $path=Join-Path $root $name;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Install the Cable Reader once on this PC first.'};$sources[$name]=[IO.File]::ReadAllText($path) }
# Recognition and pins are checked; existing USB/custom reader code is not replaced.
[void](ConvertTo-GreenloopStartupPlan $sources 51892)
$plan=Get-GreenloopAutostartTask $root $exe
if($CheckOnly){if($plan.existing){try{Assert-GreenloopAutostartXml $plan.existing.Xml $root $exe $plan.sid;Write-Host 'AUTO-START CONFIGURATION VERIFIED. No changes.'}catch{Write-Host 'Reader files verified; auto-start repair is needed. No changes.'}}else{Write-Host 'Reader files verified; automatic startup task is missing. No changes.'};return}
$lock=[Threading.Mutex]::new($false,('Local\Greenloop.CableSetup.'+$plan.sid));$owns=$false
try{
 try{$owns=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
 if(-not $owns){throw 'Reader setup is running. Finish it before this repair.'}
 $backup=Join-Path $root ('before-autostart-repair-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'));[void][IO.Directory]::CreateDirectory($backup)
 $task=Install-GreenloopAutostart $root $exe $backup
 [void]$task.Run($null)
 $deadline=[datetime]::UtcNow.AddSeconds(45);$health=$null
 while([datetime]::UtcNow -lt $deadline){foreach($port in @(51892,51893)){$health=Get-GreenloopLocalHealth $port 2000;if($health){break}};if($health){break};Start-Sleep -Milliseconds 500}
 if(-not $health){throw 'Automatic startup is configured, but reader health is not yet confirmed. Check reader-supervisor.log; do not reinstall.'}
 @{version='20261117-reader-autostart-1';task=$plan.name;readerVerified=$true;phoneVerified=$false;checkedAt=[datetime]::UtcNow.ToString('o');backup=$backup}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'reader-autostart.json') -Encoding UTF8
 Write-Host 'GREENLOOP AUTO-START CONFIGURED AND READER RUNNING.' -ForegroundColor Green
 Write-Host 'Windows sign-in starts the reader in background. ZIP installation does not need to be repeated. A reboot test is still required.'
}finally{if($owns){$lock.ReleaseMutex()};$lock.Dispose()}
