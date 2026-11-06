#requires -Version 5.1
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../dual-imei-reader/Update-Reader-Source.ps1')
. (Join-Path $PSScriptRoot 'Update-Reader.ps1')
$root=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\Greenloop\ReadOnlyDeviceReader'
$target=Join-Path $root 'Greenloop-Device-Reader.ps1'
if(-not(Test-Path -LiteralPath $target -PathType Leaf)){
  if($CheckOnly){Write-Host 'Reader patch syntax checked. No installed cable reader on this PC; run this installer on the cable-entry PC.';return}
  throw 'Cable reader was not found on this PC. Run this installer on the PC used for cable IMEI Entry.'
}
$source=[IO.File]::ReadAllText($target)
$patched=ConvertTo-GreenloopBatteryDetailsReader $source
$utf8=New-Object Text.UTF8Encoding($false)
$sha=[Security.Cryptography.SHA256]::Create()
try{$newHash=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($patched)))).Replace('-','')}finally{$sha.Dispose()}
$oldHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$updates=@{'Greenloop-Device-Reader.ps1'=$patched}
foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
  $path=Join-Path $root $name
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Auto-start file missing; existing reader was preserved: '+$name)}
  $updates[$name]=ConvertTo-GreenloopReaderHash ([IO.File]::ReadAllText($path)) $oldHash $newHash
}
foreach($value in $updates.Values){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($value,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Updated reader/auto-start syntax verification failed.'}}
if($CheckOnly){Write-Host 'Installed reader is compatible; iPhone/Android and other extensions are preserved. CheckOnly made no changes.';return}
$watch=Join-Path $root 'Watch-Greenloop-Reader.ps1'
function Test-ExactReaderCommand([string]$Command,[string]$ScriptPath){
 $escaped=[regex]::Escape($ScriptPath.Replace('/','\'))
 return $Command.Replace('/','\') -match ('(?i)(?:^|\s)-File\s+(?:"'+$escaped+'"|'+$escaped+')(?:\s|$)')
}
function Get-OwnedReaderProcesses([string]$ScriptPath){
 @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object {
  $_.ProcessId -ne $PID -and (Test-ExactReaderCommand ([string]$_.CommandLine) $ScriptPath)
 })
}
# Query ownership before any writes. An unavailable process inventory must not
# leave a partially updated reader. Support quoted and unquoted -File paths.
[void](Get-OwnedReaderProcesses $watch)
[void](Get-OwnedReaderProcesses $target)
$backup=Join-Path $root ('before-battery-details-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[void][IO.Directory]::CreateDirectory($backup)
foreach($name in $updates.Keys){[IO.File]::WriteAllBytes((Join-Path $backup $name),[IO.File]::ReadAllBytes((Join-Path $root $name)))}
# Stop the supervisor first; it must not respawn a reader during replacement.
$stopped=0
foreach($process in (Get-OwnedReaderProcesses $watch)){
 Stop-Process -Id $process.ProcessId -ErrorAction Stop
 Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
 $stopped++
}
# Re-enumerate children after the supervisor has stopped to close the race.
foreach($process in (Get-OwnedReaderProcesses $target)){
 Stop-Process -Id $process.ProcessId -ErrorAction Stop
 Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
 $stopped++
}
Write-Host "Stopped $stopped exact Greenloop reader / supervisor processes; starting the updated reader."

# A reserved/bound port may have no LISTENING record. Probe the actual bind;
# never terminate an unrecognized owner or change Windows reservations.
$selectedPort=$null
foreach($candidate in @(51892,51893)){
 $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$candidate)
 try{$probe.Server.ExclusiveAddressUse=$true;$probe.Start();$selectedPort=$candidate;break}
 catch [Net.Sockets.SocketException]{Write-Host ("Local reader port $candidate is unavailable; trying the alternate port.")}
 finally{$probe.Stop()}
}
if($null -eq $selectedPort){throw 'Both supported reader ports are unavailable. Original files are backed up; no unknown process was stopped.'}
Write-Host ("Using local reader port $selectedPort.")
$header='(?m)^  \[int\]\$Port = (?:51892|51893)\r?$'
if(([regex]::Matches($updates['Greenloop-Device-Reader.ps1'],$header)).Count -ne 1){throw 'Reader default port declaration is not recognized.'}
$updates['Greenloop-Device-Reader.ps1']=[regex]::Replace($updates['Greenloop-Device-Reader.ps1'],$header,('  [int]$Port = '+$selectedPort))
$sha=[Security.Cryptography.SHA256]::Create()
try{$portHash=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($updates['Greenloop-Device-Reader.ps1'])))).Replace('-','')}finally{$sha.Dispose()}
foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
 $updated=ConvertTo-GreenloopReaderHash $updates[$name] $newHash $portHash
 if($name -eq 'Watch-Greenloop-Reader.ps1'){
  $pattern='(?m)^\$readerPort = (?:51892|51893)\r?$'
  if(([regex]::Matches($updated,$pattern)).Count -ne 1){throw 'Supervisor port declaration not recognized.'}
  $updated=[regex]::Replace($updated,$pattern,('$readerPort = '+$selectedPort))
 }else{
  if($updated -notmatch 'http://127\.0\.0\.1:5189[23]/health'){throw 'Launcher health endpoint not recognized.'}
  $updated=[regex]::Replace($updated,'http://127\.0\.0\.1:5189[23]/health',('http://127.0.0.1:'+$selectedPort+'/health'))
 }
 $updates[$name]=$updated
}
foreach($value in $updates.Values){$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($value,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Reader port configuration failed syntax checks.'}}
try{
 foreach($name in $updates.Keys){
  $temp=Join-Path $root ('battery-details-'+[guid]::NewGuid().ToString('N')+'.tmp')
  [IO.File]::WriteAllText($temp,$updates[$name],$utf8)
  Move-Item -LiteralPath $temp -Destination (Join-Path $root $name) -Force
 }
}catch{
 foreach($name in $updates.Keys){[IO.File]::WriteAllBytes((Join-Path $root $name),[IO.File]::ReadAllBytes((Join-Path $backup $name)))}
 throw
}
Write-Host ('Reader and auto-start checks updated. Original backup: '+$backup)
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$watch+'"')) -WindowStyle Hidden
# Existing supervisor may start the replacement; if it is absent, start it here.
$verified=$false
for($i=0;$i -lt 15;$i++){
  try{$h=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$selectedPort+'/health') -TimeoutSec 3;if($h.ok -and $h.service -ceq 'Greenloop Read-Only Device Reader' -and $h.dualImeiVersion -ceq '20261023-dual-imei-1' -and $h.readerDetailsVersion -ceq '20261106-battery-details-1'){$verified=$true;break}}catch{}
  Start-Sleep -Seconds 1
}
if(-not $verified){throw 'Source was updated, but running reader verification is pending. Restart the Greenloop Cable Reader and rerun this command.'}
Write-Host 'BATTERY AND DEVICE DETAILS READER - RUNNING AND VERIFIED.' -ForegroundColor Green
Write-Host 'Connect an unlocked iPhone and accept Trust. Main IMEI, available secondary IMEI and Serial Number belong to one record; secondary IMEI has no new visible field.'

Write-Host 'Raw / design capacity estimates remain labelled estimated. USB-unavailable lock and parts-history checks are not assumed.'
