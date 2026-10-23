#requires -Version 5.1
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Update-Reader-Source.ps1')
$root=Join-Path $env:LOCALAPPDATA 'Greenloop\ReadOnlyDeviceReader'
$target=Join-Path $root 'Greenloop-Device-Reader.ps1'
if(-not(Test-Path -LiteralPath $target -PathType Leaf)){
  if($CheckOnly){Write-Host 'Reader patch syntax checked. No installed cable reader on this PC; run this installer on the cable-entry PC.';return}
  throw 'Cable reader was not found on this PC. Run this installer on the PC used for cable IMEI Entry.'
}
$source=[IO.File]::ReadAllText($target)
$patched=ConvertTo-GreenloopDualIMEIReader $source
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
$backup=Join-Path $root ('before-dual-imei-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[void][IO.Directory]::CreateDirectory($backup)
foreach($name in $updates.Keys){[IO.File]::WriteAllBytes((Join-Path $backup $name),[IO.File]::ReadAllBytes((Join-Path $root $name)))}
try{
 foreach($name in $updates.Keys){
  $temp=Join-Path $root ('dual-imei-'+[guid]::NewGuid().ToString('N')+'.tmp')
  [IO.File]::WriteAllText($temp,$updates[$name],$utf8)
  Move-Item -LiteralPath $temp -Destination (Join-Path $root $name) -Force
 }
}catch{
 foreach($name in $updates.Keys){[IO.File]::WriteAllBytes((Join-Path $root $name),[IO.File]::ReadAllBytes((Join-Path $backup $name)))}
 throw
}
Write-Host ('Reader and auto-start checks updated. Original backup: '+$backup)
# Only restart the exact installed reader process; no ADB/phone reset commands.
$watch=Join-Path $root 'Watch-Greenloop-Reader.ps1'
foreach($script in @($watch,$target)){
 $quoted=[regex]::Escape($script)
 $owned=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match ('(?i)(?:^|\s)-File\s+"'+$quoted+'"(?:\s|$)') })
 foreach($process in $owned){Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue}
}
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$watch+'"')) -WindowStyle Hidden
# Existing supervisor may start the replacement; if it is absent, start it here.
$verified=$false
for($i=0;$i -lt 15;$i++){
  try{$h=Invoke-RestMethod -Uri 'http://127.0.0.1:51892/health' -TimeoutSec 3;if($h.ok -and $h.service -ceq 'Greenloop Read-Only Device Reader' -and $h.dualImeiVersion -ceq '20261023-dual-imei-1'){$verified=$true;break}}catch{}
  Start-Sleep -Seconds 1
}
if(-not $verified){throw 'Source was updated, but running reader verification is pending. Restart the Greenloop Cable Reader and rerun this command.'}
Write-Host 'DUAL IMEI CABLE READER - RUNNING AND VERIFIED.' -ForegroundColor Green
Write-Host 'Connect an unlocked iPhone and accept Trust. Main IMEI, available secondary IMEI and Serial Number belong to one record; secondary IMEI has no new visible field.'
