#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$version='20261023-cable-setup-1'
$readerRoot=Join-Path $env:LOCALAPPDATA 'Greenloop\ReadOnlyDeviceReader'
$readerScript=Join-Path $readerRoot 'Greenloop-Device-Reader.ps1'
$launcherScript=Join-Path $readerRoot 'Start-Greenloop.ps1'
$watchScript=Join-Path $readerRoot 'Watch-Greenloop-Reader.ps1'
$powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $PSScriptRoot 'Setup-Utilities.ps1')
. (Join-Path $PSScriptRoot 'Update-Reader-Source.ps1')
$utf8=New-Object Text.UTF8Encoding($false)
function Get-TextHash([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-AppleDriverHint {
 $service=Get-Service -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -eq 'Apple Mobile Device Service'} | Select-Object -First 1
 if($service -and $service.Status -eq 'Running'){return 'Apple mobile device service is running. Connect an unlocked iPhone and accept Trust to test USB communication.'}
 return 'Apple driver is not confirmed. Install/open Apple Devices from Microsoft Store, finish its setup, then reconnect an unlocked iPhone and accept Trust. Existing Apple software was preserved.'
}
try{
 if(-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'){throw 'This setup supports Windows 10/11 x64 only.'}
 if([Environment]::OSVersion.Version -lt [version]'10.0'){throw 'Windows 10 or 11 is required.'}
 $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'payload.json') -Raw | ConvertFrom-Json
 if($manifest.version -cne $version -or @($manifest.files).Count -lt 15){throw 'Setup payload manifest is incomplete.'}
 foreach($file in $manifest.files){
  $path=Assert-ContainedPath (Join-Path $PSScriptRoot $file.path) $PSScriptRoot
  if($file.sha256 -cnotmatch '^[A-F0-9]{64}$' -or (Get-Hash $path) -cne $file.sha256){throw ('Setup payload changed: '+$file.path)}
  if($path.EndsWith('.ps1')){Assert-PowerShell $path}
 }
 # Existing custom extensions are preserved through the reviewed surgical patch.
 $names=@('Greenloop-Device-Reader.ps1','Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')
 $present=@($names | Where-Object {Test-Path -LiteralPath (Join-Path $readerRoot $_) -PathType Leaf})
 if($present.Count -ne 0 -and $present.Count -ne 3){throw 'A partial reader installation was found. Existing files were preserved; send the setup log to support.'}
 $updates=@{}
 if($present.Count -eq 3){
  $previousHash=Get-Hash $readerScript
  $updates[$names[0]]=ConvertTo-GreenloopDualIMEIReader ([IO.File]::ReadAllText($readerScript))
  $newHash=Get-TextHash $updates[$names[0]]
  foreach($name in $names[1..2]){$updates[$name]=ConvertTo-GreenloopReaderHash ([IO.File]::ReadAllText((Join-Path $readerRoot $name))) $previousHash $newHash}
 }else{
  foreach($name in $names){$updates[$name]=[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('reader/'+$name)))}
 }
 foreach($text in $updates.Values){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Reader script verification failed.'}}
 $newHash=Get-TextHash $updates[$names[0]]
 foreach($name in $names[1..2]){if(-not $updates[$name].Contains($newHash)){throw 'Auto-start does not match the prepared reader.'}}
 $androidReady=Test-PlatformTools
 $startupFolder=[Environment]::GetFolderPath('Startup')
 $desktopFolder=[Environment]::GetFolderPath('DesktopDirectory')
 if(-not $startupFolder -or -not $desktopFolder){throw 'Windows user shortcut folders are not available.'}
 $startupShortcut=Join-Path $startupFolder 'Greenloop Cable Reader.lnk'
 $desktopShortcut=Join-Path $desktopFolder 'Greenloop - Auto Reader.lnk'
 $shortcutShell=New-Object -ComObject WScript.Shell
 Assert-Shortcut $startupShortcut -Startup
 Assert-Shortcut $desktopShortcut
 if($CheckOnly){Write-Output 'SETUP CHECK PASSED. Payload, existing reader compatibility and shortcut ownership verified. No installation, network downloads or phone commands.';return}
 $lock=New-Object Threading.Mutex($false,('Local\Greenloop.CableSetup.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
 $owns=$false
 try{$owns=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
 if(-not $owns){throw 'Another Cable Reader setup is running. Finish that setup first.'}
 [void][IO.Directory]::CreateDirectory($readerRoot)
 $backupRoot=Join-Path $readerRoot ('setup-backup-'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($backupRoot)
 $stage=Join-Path $backupRoot 'download'
 Write-Output 'Checking Android tools...'
 if(-not $androidReady){$stagedTools=Get-OfficialPlatformTools $stage}
 $writes=@{}
 foreach($name in $names){$writes[(Join-Path $readerRoot $name)]=$utf8.GetBytes($updates[$name])}
 foreach($file in $manifest.files | Where-Object {$_.path.StartsWith('apple/')}){
  $relative=$file.path.Substring(6)
  $destination=Assert-ContainedPath (Join-Path $readerRoot $relative) $readerRoot
  $writes[$destination]=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $file.path))
 }
 if(-not $androidReady){
  foreach($file in Get-ChildItem -LiteralPath $stagedTools -File -Recurse){
   $relative=$file.FullName.Substring($stagedTools.Length+1)
   $destination=Assert-ContainedPath (Join-Path $readerRoot ('platform-tools/'+$relative)) $readerRoot
   $writes[$destination]=[IO.File]::ReadAllBytes($file.FullName)
  }
  $writes[(Join-Path $readerRoot 'android-tools.json')]=[IO.File]::ReadAllBytes((Join-Path $stage 'android-tools.json'))
 }
 $backups=@{};$index=0
 foreach($path in @($writes.Keys)+@($startupShortcut,$desktopShortcut)){
  if(Test-Path -LiteralPath $path -PathType Container){throw 'A folder occupies a required setup file name.'}
  if(Test-Path -LiteralPath $path -PathType Leaf){$copy=Join-Path $backupRoot ('original-'+$index);[IO.File]::WriteAllBytes($copy,[IO.File]::ReadAllBytes($path));$backups[$path]=$copy}else{$backups[$path]=$null}
  $index++
 }
 # No unrelated PowerShell or ADB processes are stopped.
 foreach($script in @($watchScript,$readerScript)){
  $pattern='(?i)(?:^|\s)-File\s+"'+[regex]::Escape($script)+'"(?:\s|$)'
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.ProcessId -ne $PID -and $_.ExecutablePath -ieq $powershell -and $_.CommandLine -match $pattern})){
   $fresh=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId) -ErrorAction SilentlyContinue
   if($fresh -and $fresh.CreationDate -eq $p.CreationDate -and $fresh.CommandLine -match $pattern){Stop-Process -Id $p.ProcessId -ErrorAction Stop}
  }
 }
 Write-Output 'Installing verified reader files and Windows sign-in shortcuts...'
 try{
  foreach($path in $writes.Keys){
   [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
   $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
   [IO.File]::WriteAllBytes($temp,$writes[$path]);Move-Item -LiteralPath $temp -Destination $path -Force
  }
  Save-Shortcut $startupShortcut
  Save-Shortcut $desktopShortcut -OpenWebsite
 }catch{
  foreach($path in $backups.Keys){if($backups[$path]){[IO.File]::WriteAllBytes($path,[IO.File]::ReadAllBytes($backups[$path]))}elseif(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path}}
  if($present.Count -eq 3){Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$launcherScript+'"')) -WindowStyle Hidden}
  throw
 }
 if(-not (Test-PlatformTools)){throw 'Android tools verification did not pass. Setup is incomplete.'}
 & $powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $launcherScript
 if($LASTEXITCODE -ne 0){throw 'Files installed; reader startup is pending. Rerun setup and send the log if this repeats.'}
 $health=Invoke-RestMethod -Uri 'http://127.0.0.1:51892/health' -TimeoutSec 10
 if(-not $health.ok -or $health.service -cne 'Greenloop Read-Only Device Reader' -or $health.mode -cne 'read-only' -or $health.dualImeiVersion -cne '20261023-dual-imei-1' -or -not $health.androidToolsReady){throw 'Reader running version could not be verified. Setup is incomplete.'}
 $hint=Get-AppleDriverHint
 @{version=$version;readerVerified=$true;phoneVerified=$false;installedAt=[datetime]::UtcNow.ToString('o');backup=$backupRoot;appleDriverHint=$hint} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $readerRoot 'cable-setup.json') -Encoding UTF8
 Write-Output 'READER RUNNING - VERIFIED. Phone USB communication still needs a connected phone test.'
 Write-Output $hint
 Write-Output 'Android: enable USB debugging, reconnect and Allow. If not detected, use the official driver link for the phone brand.'
}catch{Write-Output ('SETUP INCOMPLETE: '+$_.Exception.Message);exit 1}
finally{if($owns -and $lock){$lock.ReleaseMutex()};if($lock){$lock.Dispose()}}
