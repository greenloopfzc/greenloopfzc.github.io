#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../cable-reader-setup/Reader-Startup.ps1')
. (Join-Path $PSScriptRoot 'Update-Reader.ps1')
$root=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\Greenloop\ReadOnlyDeviceReader'
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$names=@('Greenloop-Device-Reader.ps1','Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1');$sources=@{};$original=@{}
foreach($name in $names){$p=Join-Path $root $name;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Reader file missing: '+$name+'. Run Setup Cable Reader on this PC first.')};$original[$name]=[IO.File]::ReadAllBytes($p);$sources[$name]=[IO.File]::ReadAllText($p)}
[void](ConvertTo-GreenloopStartupPlan $sources 51892)
$prepared=@{};foreach($name in $names){$prepared[$name]=$sources[$name]}
$oldHash=Get-GreenloopTextHash $sources['Greenloop-Device-Reader.ps1']
$prepared['Greenloop-Device-Reader.ps1']=ConvertTo-GreenloopFastBhReader $sources['Greenloop-Device-Reader.ps1']
$newHash=Get-GreenloopTextHash $prepared['Greenloop-Device-Reader.ps1']
foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
 $pattern="(?m)^\`$expectedReaderHash\s*=\s*'([A-Fa-f0-9]{64})'"
 $found=[regex]::Matches($prepared[$name],$pattern)
 if($found.Count -ne 1 -or $found[0].Groups[1].Value -ine $oldHash){throw 'Installed reader pin differs. Original files preserved.'}
 $prepared[$name]=[regex]::Replace($prepared[$name],$pattern,('$expectedReaderHash = '+[char]39+$newHash+[char]39))
}
[void](ConvertTo-GreenloopStartupPlan $prepared 51892)
if($CheckOnly){Write-Host 'FAST READER / BATTERY CHECK PASSED: compatible installed source, exact pins and preserved Android/extensions. No process or file changed.';return}
# Fail before writes/stops when process ownership cannot be inspected.
[void](Get-GreenloopOwnedProcesses $root $exe)
$lock=[Threading.Mutex]::new($false,('Local\Greenloop.CableSetup.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value));$owns=$false
try{
 try{$owns=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
 if(-not $owns){throw 'Cable Reader setup is already running. Close that setup before running this repair.'}
 $backup=Join-Path $root ('before-fast-bh-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
 [void][IO.Directory]::CreateDirectory($backup)
 foreach($name in $names){[IO.File]::WriteAllBytes((Join-Path $backup $name),$original[$name])}
 # A live setup may have changed source since validation; never overwrite it.
 foreach($name in $names){if((Get-GreenloopTextHash ([IO.File]::ReadAllText((Join-Path $root $name)))) -cne (Get-GreenloopTextHash $sources[$name])){throw 'Reader files changed during inspection. Rerun repair.'}}
 Stop-GreenloopOwnedProcesses $root $exe
 $port=Select-GreenloopReaderPort
 $updates=ConvertTo-GreenloopStartupPlan $prepared $port
 try{
  foreach($name in $names){$p=Join-Path $root $name;$temp=$p+'.'+[guid]::NewGuid().ToString('N')+'.tmp';[IO.File]::WriteAllText($temp,$updates[$name],[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $p -Force}
 }catch{foreach($name in $names){[IO.File]::WriteAllBytes((Join-Path $root $name),$original[$name])};Start-Process -FilePath $exe -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'Watch-Greenloop-Reader.ps1')+'"'));throw}
 Write-Host ('Reader, launcher and supervisor aligned on local port '+$port+'. Backup: '+$backup)
 Start-Process -FilePath $exe -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'Watch-Greenloop-Reader.ps1')+'"'))
 $deadline=[datetime]::UtcNow.AddSeconds(45);$health=$null
 while([datetime]::UtcNow -lt $deadline){$health=Get-GreenloopLocalHealth $port 2500;if($health -and $health.readerSpeedBhVersion -ceq '20261111-fast-bh-1'){break};$health=$null;Start-Sleep -Milliseconds 500}
 if(-not $health){throw 'Startup is still not verified. Original files are backed up. Share reader-launch.log and reader-supervisor.log; no unrelated process was stopped.'}
 # Persist setup status only after live health verification; phone communication is separate.
 $status=Join-Path $root 'cable-setup.json'
 if(Test-Path -LiteralPath $status -PathType Leaf){[IO.File]::Copy($status,(Join-Path $backup 'cable-setup.json'),$false)}
 @{version='20261111-fast-bh-1';readerVerified=$true;phoneVerified=$false;readerPort=$port;installedAt=[datetime]::UtcNow.ToString('o');backup=$backup}|ConvertTo-Json|Set-Content -LiteralPath $status -Encoding UTF8
 Write-Host 'GREENLOOP FAST READER / BATTERY HEALTH - VERIFIED.' -ForegroundColor Green
 Write-Host 'Reload IMEI Entry. Maximum Capacity from the phone takes priority; values over 100 are capped at 100. Read phone again forces fresh USB details.'
}finally{if($owns){$lock.ReleaseMutex()};$lock.Dispose()}
