[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installFolder = Join-Path $env:LOCALAPPDATA 'Greenloop\CableReader'
$installedScript = Join-Path $installFolder 'Greenloop-iPhone-Scanner.ps1'
$installedThreeUBridge = Join-Path $installFolder 'Greenloop-3uTools-Bridge.ps1'
$installedColors = Join-Path $installFolder 'devices_table.txt'
$sourceSetupAssistantTool = Join-Path $PSScriptRoot 'Greenloop-Complete-Setup.exe'
$installedSetupAssistantTool = Join-Path $installFolder 'Greenloop-Complete-Setup.exe'
$sourceModernActivationTool = Join-Path $PSScriptRoot 'Greenloop-Mobile-Activation.exe'
$installedModernActivationTool = Join-Path $installFolder 'Greenloop-Mobile-Activation.exe'
$activationPackage = Join-Path $PSScriptRoot 'Greenloop-Activation-Tools.zip'
$activationFolder = Join-Path $installFolder 'libimobiledevice'
$activationExecutable = Join-Path $activationFolder 'ideviceactivation.exe'
$hiddenRunner = Join-Path $installFolder 'Run-Greenloop-Cable-Reader-Hidden.vbs'
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'Greenloop Cable Reader.lnk'

Write-Host 'Installing Greenloop Cable Reader...' -ForegroundColor Cyan

# Stop the currently listening Greenloop reader even when Windows blocks
# Win32_Process command-line inspection for a standard user account.
try {
  $readerLine = netstat -ano -p tcp | Where-Object { $_ -match '^\s*TCP\s+127\.0\.0\.1:51892\s+.*\s+LISTENING\s+\d+\s*$' } | Select-Object -First 1
  if ($readerLine -and $readerLine -match 'LISTENING\s+(\d+)\s*$') {
    Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
} catch {}

try {
  $bridgeLine = netstat -ano -p tcp | Where-Object { $_ -match '^\s*TCP\s+127\.0\.0\.1:51894\s+.*\s+LISTENING\s+\d+\s*$' } | Select-Object -First 1
  if ($bridgeLine -and $bridgeLine -match 'LISTENING\s+(\d+)\s*$') {
    Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
} catch {}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like '*Greenloop-iPhone-Scanner.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $installFolder -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Greenloop-iPhone-Scanner.ps1') -Destination $installedScript -Force
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Greenloop-3uTools-Bridge.ps1'))) {
  throw 'Greenloop-3uTools-Bridge.ps1 is missing beside the installer.'
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Greenloop-3uTools-Bridge.ps1') -Destination $installedThreeUBridge -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'devices_table.txt') -Destination $installedColors -Force
if (-not (Test-Path -LiteralPath $sourceSetupAssistantTool)) {
  throw 'Greenloop-Complete-Setup.exe is missing beside the installer.'
}
Copy-Item -LiteralPath $sourceSetupAssistantTool -Destination $installedSetupAssistantTool -Force
if (-not (Test-Path -LiteralPath $sourceModernActivationTool)) {
  throw 'Greenloop-Mobile-Activation.exe is missing beside the installer.'
}
Copy-Item -LiteralPath $sourceModernActivationTool -Destination $installedModernActivationTool -Force
if (-not (Test-Path -LiteralPath $activationPackage)) {
  throw 'Greenloop-Activation-Tools.zip is missing beside the installer.'
}
$expectedActivationHash = 'D7CB57A71270848C35C3F01006701535AADF6DFB52325863EA368C94A34A2CAB'
$actualActivationHash = (Get-FileHash -LiteralPath $activationPackage -Algorithm SHA256).Hash
if ($actualActivationHash -ne $expectedActivationHash) {
  throw 'The Greenloop activation engine package failed its security check.'
}
New-Item -ItemType Directory -Path $activationFolder -Force | Out-Null
Expand-Archive -LiteralPath $activationPackage -DestinationPath $activationFolder -Force
if (-not (Test-Path -LiteralPath $activationExecutable)) {
  throw 'The Greenloop activation engine could not be installed.'
}
$escapedScript = $installedScript.Replace('"', '""')
$escapedThreeUBridge = $installedThreeUBridge.Replace('"', '""')
$runnerText = @"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$escapedScript"""
shell.Run command, 0, False
command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$escapedThreeUBridge"""
shell.Run command, 0, False
"@
Set-Content -LiteralPath $hiddenRunner -Value $runnerText -Encoding ASCII

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$shortcut.Arguments = '"' + $hiddenRunner + '"'
$shortcut.WorkingDirectory = $installFolder
$shortcut.Description = 'Starts Greenloop iPhone Cable Reader silently at Windows sign-in.'
$shortcut.Save()

Start-Process -FilePath 'powershell.exe' -ArgumentList @(
  '-NoProfile',
  '-WindowStyle', 'Hidden',
  '-ExecutionPolicy', 'Bypass',
  '-File', ('"' + $installedScript + '"')
) -WindowStyle Hidden
Start-Process -FilePath 'powershell.exe' -ArgumentList @(
  '-NoProfile',
  '-WindowStyle', 'Hidden',
  '-ExecutionPolicy', 'Bypass',
  '-File', ('"' + $installedThreeUBridge + '"')
) -WindowStyle Hidden

$ready = $false
$bridgeReady = $false
for ($attempt = 1; $attempt -le 8; $attempt += 1) {
  Start-Sleep -Milliseconds 500
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:51892/health' -TimeoutSec 2
    if ($health.ok -and [version]$health.version -ge [version]'4.4' -and $health.modernActivationEngine -and $health.skipSetupEngine) { $ready = $true; break }
  } catch {}
}

for ($attempt = 1; $attempt -le 10; $attempt += 1) {
  Start-Sleep -Milliseconds 400
  try {
    $bridgeHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:51894/health' -TimeoutSec 2
    if ($bridgeHealth.ok -and [version]$bridgeHealth.version -ge [version]'2.0') { $bridgeReady = $true; break }
  } catch {}
}

if (-not $ready) {
  Write-Host 'Installation finished, but the reader did not start.' -ForegroundColor Yellow
  Write-Host 'Install Apple Devices for Windows, then run this installer again.' -ForegroundColor Yellow
  exit 1
}

if (-not $bridgeReady) {
  Write-Host 'The Cable Reader started, but the 3uTools integration did not start.' -ForegroundColor Yellow
  exit 1
}

Write-Host 'Greenloop Cable Reader is installed and running in the background.' -ForegroundColor Green
Write-Host 'It will start automatically whenever this Windows user signs in.' -ForegroundColor Green
Write-Host 'Greenloop 3uTools integration is installed and running.' -ForegroundColor Green
