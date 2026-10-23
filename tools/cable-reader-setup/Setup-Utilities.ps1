function Get-Hash([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
  return ''
}
function Assert-PowerShell([string]$Path) {
  $tokens = $null; $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Invalid reader script: $Path" }
}
function Assert-ContainedPath([string]$Path, [string]$Parent) {
  $absolute = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  if (-not $absolute.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected path outside the reader installation.' }
  return $absolute
}
function Test-PlatformTools {
  $folder = Join-Path $readerRoot 'platform-tools'
  if (-not (Test-Path -LiteralPath $folder)) { return $false }
  $recordPath = Join-Path $readerRoot 'android-tools.json'
  if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'An existing Android tools folder is not owned by this update; it was preserved.' }
  $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
  if ($record.source -cnotmatch '^https://dl\.google\.com/android/repository/platform-tools_r[0-9.]+-win\.zip$' -or -not @($record.files).Count) { throw 'Unexpected Android tools verification record.' }
  foreach ($file in $record.files) {
    $path = Assert-ContainedPath (Join-Path $folder $file.path) $folder
    if ($file.sha256 -cnotmatch '^[A-F0-9]{64}$' -or (Get-Hash $path) -cne $file.sha256) { throw "Installed Android tool changed: $($file.path). Send this result to Codex." }
  }
  return (Test-Path -LiteralPath (Join-Path $folder 'adb.exe') -PathType Leaf)
}
function Get-OfficialPlatformTools([string]$Stage) {
  # Download only official Google SDK metadata and the matching checked archive.
  # Network activity occurs once during installation, never while reading phones.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [void][IO.Directory]::CreateDirectory($Stage)
  $metadataPath = Join-Path $Stage 'repository.xml'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/repository2-1.xml' -OutFile $metadataPath -MaximumRedirection 0 -TimeoutSec 90
  $settings = New-Object Xml.XmlReaderSettings
  $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
  $settings.XmlResolver = $null
  $xmlReader = [Xml.XmlReader]::Create($metadataPath, $settings)
  $document = New-Object Xml.XmlDocument
  $document.XmlResolver = $null
  try { $document.Load($xmlReader) } finally { $xmlReader.Dispose() }
  $archives = @($document.SelectNodes("//*[local-name()='remotePackage' and @path='platform-tools']/*[local-name()='archives']/*[local-name()='archive'][*[local-name()='host-os']='windows']/*[local-name()='complete']"))
  if ($archives.Count -ne 1) { throw 'Google SDK metadata did not identify one Windows Platform Tools archive.' }
  $archive = $archives[0]
  $name = [string]$archive.SelectSingleNode("*[local-name()='url']").InnerText
  $checksumNode = $archive.SelectSingleNode("*[local-name()='checksum']")
  $expectedSha1 = [string]$checksumNode.InnerText
  $expectedSize = [long]$archive.SelectSingleNode("*[local-name()='size']").InnerText
  if ($name -cnotmatch '^platform-tools_r[0-9.]+-win\.zip$' -or $expectedSha1 -notmatch '^[a-fA-F0-9]{40}$' -or
      ($checksumNode.HasAttribute('type') -and $checksumNode.GetAttribute('type') -cne 'sha1') -or $expectedSize -le 0 -or $expectedSize -gt 200MB) {
    throw 'Google SDK download metadata was not recognized. Nothing was installed.'
  }
  $url = 'https://dl.google.com/android/repository/' + $name
  $zipPath = Join-Path $Stage $name
  Write-Host 'Downloading official Android Platform Tools once...'
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath -MaximumRedirection 0 -TimeoutSec 180
  if ((Get-Item -LiteralPath $zipPath).Length -ne $expectedSize -or (Get-FileHash -LiteralPath $zipPath -Algorithm SHA1).Hash -ine $expectedSha1) {
    throw 'Android archive integrity check failed. Nothing was installed.'
  }
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    if ($zip.Entries.Count -gt 500) { throw 'Unexpected Android archive size.' }
    $totalExpanded = 0L
    foreach ($entry in $zip.Entries) {
      $entryName = $entry.FullName.Replace('\','/')
      if ($entryName -notmatch '^platform-tools/(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*(?:[A-Za-z0-9_-][A-Za-z0-9._-]*)?/?$') { throw 'Unsafe Android archive entry.' }
      if (($entry.ExternalAttributes -band 0xF0000000L) -eq 0xA0000000L) { throw 'Android archive contains an unsupported link.' }
      $destination = Assert-ContainedPath (Join-Path $Stage $entryName) $Stage
      $totalExpanded += $entry.Length
      if ($totalExpanded -gt 400MB) { throw 'Android archive expands beyond the allowed size.' }
      if ($entryName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($destination); continue }
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
    }
  } finally { $zip.Dispose() }
  $toolsFolder = Join-Path $Stage 'platform-tools'
  foreach ($required in @('adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll','source.properties')) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolsFolder $required) -PathType Leaf)) { throw "Official Android tool is missing: $required" }
  }
  $files = @(Get-ChildItem -LiteralPath $toolsFolder -File -Recurse | ForEach-Object {
    @{path=$_.FullName.Substring($toolsFolder.Length + 1);sha256=(Get-Hash $_.FullName)}
  })
  @{source=$url;archiveSha256=(Get-Hash $zipPath);files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Stage 'android-tools.json') -Encoding UTF8
  return $toolsFolder
}
function Assert-Shortcut([string]$Path, [switch]$Startup) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "A folder uses the shortcut name: $Path" }
  $shortcut = $shortcutShell.CreateShortcut($Path)
  if ($shortcut.TargetPath -ieq $powershell -and ($shortcut.Arguments -like ('*"' + $launcherScript + '"*') -or ($Startup -and $shortcut.Arguments -like ('*"' + $watchScript + '"*')))) { return }
  $legacy = Join-Path $env:LOCALAPPDATA 'Greenloop\CableReader\Run-Greenloop-Cable-Reader-Hidden.vbs'
  if ($Startup -and [IO.Path]::GetFileName($shortcut.TargetPath) -ieq 'wscript.exe' -and $shortcut.Arguments.Trim('"') -ieq $legacy) { return }
  throw "An unrelated shortcut was preserved: $Path"
}
function Save-Shortcut([string]$Path, [switch]$OpenWebsite) {
  $shortcut = $shortcutShell.CreateShortcut($Path)
  $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherScript + '"'
  if ($OpenWebsite) { $arguments += ' -OpenWebsite' }
  $shortcut.TargetPath = $powershell; $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $readerRoot; $shortcut.WindowStyle = 7
  $shortcut.Description = 'Greenloop iPhone and Android cable reader with background recovery.'
  $shortcut.Save()
  $saved = $shortcutShell.CreateShortcut($Path)
  if ($saved.TargetPath -ine $powershell -or $saved.Arguments -cne $arguments) { throw 'Reader shortcut verification failed.' }
}
function Stop-VerifiedScript([string]$ScriptPath) {
  $pattern = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape($ScriptPath.Replace('/','\')) + '"?(?:\s|$)'
  $candidates = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.ExecutablePath -ieq $powershell -and ([string]$_.CommandLine).Replace('/','\') -match $pattern
  })
  foreach ($candidate in $candidates) {
    $fresh = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $candidate.ProcessId) -ErrorAction SilentlyContinue
    if ($fresh -and $fresh.CreationDate -eq $candidate.CreationDate -and $fresh.ExecutablePath -ieq $powershell -and ([string]$fresh.CommandLine).Replace('/','\') -match $pattern) {
      Stop-Process -Id $fresh.ProcessId -ErrorAction Stop
      Wait-Process -Id $fresh.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
  }
}