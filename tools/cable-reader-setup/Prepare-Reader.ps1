param([Parameter(Mandatory=$true)][string]$BaseReader,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../dual-imei-reader/Update-Reader-Source.ps1')
$utf8=New-Object Text.UTF8Encoding($false)
$source=ConvertTo-GreenloopDualIMEIReader ([IO.File]::ReadAllText((Join-Path $BaseReader 'Greenloop-Device-Reader.ps1')))
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($source)))).Replace('-','')}finally{$sha.Dispose()}
[void][IO.Directory]::CreateDirectory($Destination)
[IO.File]::WriteAllText((Join-Path $Destination 'Greenloop-Device-Reader.ps1'),$source,$utf8)
$old=(Get-FileHash -LiteralPath (Join-Path $BaseReader 'Greenloop-Device-Reader.ps1') -Algorithm SHA256).Hash
foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
 $updated=ConvertTo-GreenloopReaderHash ([IO.File]::ReadAllText((Join-Path $BaseReader $name))) $old $hash
 [IO.File]::WriteAllText((Join-Path $Destination $name),$updated,$utf8)
}
Write-Output ('Fresh reader pinned to '+$hash)
