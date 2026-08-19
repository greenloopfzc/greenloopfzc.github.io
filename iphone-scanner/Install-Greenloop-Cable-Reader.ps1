[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installFolder = Join-Path $env:LOCALAPPDATA 'Greenloop\CableReader'
$installedScript = Join-Path $installFolder 'Greenloop-iPhone-Scanner.ps1'
$installedColors = Join-Path $installFolder 'devices_table.txt'
$hiddenRunner = Join-Path $installFolder 'Run-Greenloop-Cable-Reader-Hidden.vbs'
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'Greenloop Cable Reader.lnk'

Write-Host 'Installing Greenloop Cable Reader...' -ForegroundColor Cyan

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like '*Greenloop-iPhone-Scanner.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $installFolder -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Greenloop-iPhone-Scanner.ps1') -Destination $installedScript -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'devices_table.txt') -Destination $installedColors -Force

$escapedScript = $installedScript.Replace('"', '""')
$runnerText = @"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$escapedScript"""
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

Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $hiddenRunner + '"') -WindowStyle Hidden

$ready = $false
for ($attempt = 1; $attempt -le 8; $attempt += 1) {
  Start-Sleep -Milliseconds 500
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:51892/health' -TimeoutSec 2
    if ($health.ok) { $ready = $true; break }
  } catch {}
}

if (-not $ready) {
  Write-Host 'Installation finished, but the reader did not start.' -ForegroundColor Yellow
  Write-Host 'Install Apple Devices for Windows, then run this installer again.' -ForegroundColor Yellow
  exit 1
}

Write-Host 'Greenloop Cable Reader is installed and running in the background.' -ForegroundColor Green
Write-Host 'It will start automatically whenever this Windows user signs in.' -ForegroundColor Green
