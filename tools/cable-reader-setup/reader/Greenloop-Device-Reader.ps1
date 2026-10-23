[CmdletBinding()]
param(
  [int]$Port = 51892
)

$ErrorActionPreference = 'Stop'
$readerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$allowedTools = @('idevice_id.exe', 'ideviceinfo.exe', 'idevicediagnostics.exe', 'adb.exe', 'pnputil.exe')

function Get-AdbPath {
  # Use only the private, verified Platform Tools installed beside this reader.
  $path = Join-Path $readerRoot 'platform-tools\adb.exe'
  if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
  return ''
}

function Invoke-ReadOnlyTool {
  param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [string]$Arguments = '',
    [int]$TimeoutSeconds = 8
  )

  if ($allowedTools -notcontains $Tool) {
    throw "Blocked non-read-only tool: $Tool"
  }
  if ($Tool -eq 'adb.exe' -and $Arguments -cne 'devices -l' -and
      $Arguments -cnotmatch '^-s "[A-Za-z0-9._-]{1,128}" shell getprop$') {
    throw 'Blocked Android command. Only device discovery and property reading are allowed.'
  }
  if ($Tool -eq 'pnputil.exe' -and $Arguments -cne '/enum-devices /connected /bus USB /deviceids') {
    throw 'Blocked Windows USB command. Only connected USB device enumeration is allowed.'
  }

  $timeoutMilliseconds = $TimeoutSeconds * 1000
  if ($script:readerReadDeadline -is [datetime]) {
    $remainingMilliseconds = [int][math]::Floor(($script:readerReadDeadline - [datetime]::UtcNow).TotalMilliseconds)
    if ($remainingMilliseconds -le 0) { throw 'Phone read time limit reached. Read phone again to retry missing details.' }
    $timeoutMilliseconds = [math]::Min($timeoutMilliseconds, $remainingMilliseconds)
  }

  $toolPath = Join-Path $readerRoot $Tool
  if ($Tool -eq 'adb.exe') { $toolPath = Get-AdbPath }
  if ($Tool -eq 'pnputil.exe') { $toolPath = Join-Path ([Environment]::GetFolderPath('System')) 'pnputil.exe' }
  if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "Required read-only tool is missing: $Tool"
  }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $toolPath
  $startInfo.Arguments = $Arguments
  $startInfo.WorkingDirectory = $readerRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
      try { $process.Kill() } catch {}
      throw "$Tool timed out."
    }
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    if ($process.ExitCode -ne 0 -and ($Tool -eq 'adb.exe' -or -not $stdout)) {
      throw $(if ($stderr) { $stderr } else { "$Tool returned exit code $($process.ExitCode)." })
    }
    return $stdout
  } finally { $process.Dispose() }
}

function Convert-KeyValueText {
  param([string]$Text)
  $result = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*([^:]+):\s*(.*?)\s*$') {
      $key = $matches[1].Trim()
      $value = $matches[2].Trim()
      if ($key -and -not $result.ContainsKey($key)) { $result[$key] = $value }
    }
  }
  return $result
}

function Get-DeviceInfoValue {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Udid
  )
  try {
    return ([string](Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $Udid -k `"$Key`"" 6)).Trim()
  } catch {
    return ''
  }
}

function Get-PlistInteger {
  param([string]$Xml, [string[]]$Keys)
  if ([string]::IsNullOrWhiteSpace($Xml)) { return $null }
  foreach ($key in $Keys) {
    $escaped = [regex]::Escape($key)
    $match = [regex]::Match($Xml, "(?is)<key>\s*$escaped\s*</key>\s*<integer>\s*([0-9]+)\s*</integer>")
    if ($match.Success) { return [double]$match.Groups[1].Value }
  }
  return $null
}

function Find-FirstValue {
  param([hashtable[]]$Maps, [string[]]$Keys)
  foreach ($key in $Keys) {
    foreach ($map in $Maps) {
      if ($map -and $map.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$map[$key])) {
        return [string]$map[$key]
      }
    }
  }
  return ''
}

function Convert-StorageGb {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $number = 0.0
  if (-not [double]::TryParse(($Value -replace '[^0-9.]', ''), [ref]$number)) { return $null }
  if ($number -gt 1000000000) { $number = $number / 1GB }
  $sizes = @(8, 16, 32, 64, 128, 256, 512, 1024, 2048)
  return ($sizes | Sort-Object { [math]::Abs($_ - $number) } | Select-Object -First 1)
}

function Convert-BatteryHealth {
  param([hashtable[]]$Maps, [string]$BatteryXml = '')
  $script:batteryHealthSource = 'unavailable'
  $direct = Find-FirstValue $Maps @('BatteryHealth', 'BatteryHealthPercentage', 'MaximumCapacityPercent', 'MaximumCapacityPercentage', 'HealthPercentage')
  $directNumber = 0.0
  if ($direct -and [double]::TryParse(($direct -replace '[^0-9.]', ''), [ref]$directNumber)) {
    if ($directNumber -ge 1 -and $directNumber -le 100) { $script:batteryHealthSource = 'device'; return [int][math]::Round($directNumber) }
  }

  $currentXml = Get-PlistInteger $BatteryXml @('NominalChargeCapacity', 'AppleRawMaxCapacity', 'MaxCapacity')
  $designXml = Get-PlistInteger $BatteryXml @('DesignCapacity', 'BatteryDesignCapacity')
  if ($null -ne $currentXml -and $null -ne $designXml -and $designXml -gt 0) {
    $xmlPercentage = [math]::Round(($currentXml / $designXml) * 100)
    if ($xmlPercentage -ge 1 -and $xmlPercentage -le 100) { $script:batteryHealthSource = 'capacity-estimate'; return [int]$xmlPercentage }
  }

  $current = Find-FirstValue $Maps @('NominalChargeCapacity', 'AppleRawMaxCapacity', 'MaxCapacity')
  $design = Find-FirstValue $Maps @('DesignCapacity', 'BatteryDesignCapacity')
  $currentNumber = 0.0
  $designNumber = 0.0
  if ($current -and $design -and
      [double]::TryParse(($current -replace '[^0-9.]', ''), [ref]$currentNumber) -and
      [double]::TryParse(($design -replace '[^0-9.]', ''), [ref]$designNumber) -and
      $designNumber -gt 0) {
    $percentage = [math]::Round(($currentNumber / $designNumber) * 100)
    if ($percentage -ge 1 -and $percentage -le 100) { $script:batteryHealthSource = 'capacity-estimate'; return [int]$percentage }
  }
  return $null
}

function Convert-ModelName {
  param([string]$ProductType, [string]$ReportedName)
  if ($ReportedName -and $ReportedName -notmatch '^iPhone(?:\s+OS)?$') {
    if ($ReportedName -match '^iPhone\s+(.+)$') { return $matches[1].Trim() }
    return $ReportedName.Trim()
  }

  $models = @{
    'iPhone10,1'='8'; 'iPhone10,4'='8'; 'iPhone10,2'='8 Plus'; 'iPhone10,5'='8 Plus'; 'iPhone10,3'='X'; 'iPhone10,6'='X'
    'iPhone11,2'='XS'; 'iPhone11,4'='XS Max'; 'iPhone11,6'='XS Max'; 'iPhone11,8'='XR'
    'iPhone12,1'='11'; 'iPhone12,3'='11 Pro'; 'iPhone12,5'='11 Pro Max'; 'iPhone12,8'='SE 2'
    'iPhone13,1'='12 Mini'; 'iPhone13,2'='12'; 'iPhone13,3'='12 Pro'; 'iPhone13,4'='12 Pro Max'
    'iPhone14,4'='13 Mini'; 'iPhone14,5'='13'; 'iPhone14,2'='13 Pro'; 'iPhone14,3'='13 Pro Max'; 'iPhone14,6'='SE 3'
    'iPhone14,7'='14'; 'iPhone14,8'='14 Plus'; 'iPhone15,2'='14 Pro'; 'iPhone15,3'='14 Pro Max'
    'iPhone15,4'='15'; 'iPhone15,5'='15 Plus'; 'iPhone16,1'='15 Pro'; 'iPhone16,2'='15 Pro Max'
    'iPhone17,3'='16'; 'iPhone17,4'='16 Plus'; 'iPhone17,1'='16 Pro'; 'iPhone17,2'='16 Pro Max'; 'iPhone17,5'='16e'
  }
  if ($models.ContainsKey($ProductType)) { return $models[$ProductType] }
  return $ProductType
}

function Convert-ColorName {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = $Value.Trim()
  $normalNames = @('Black','White','Red','Blue','Green','Yellow','Purple','Pink','Gold','Silver','Gray','Grey','Graphite','Midnight','Starlight','Natural Titanium','Blue Titanium','White Titanium','Black Titanium','Desert Titanium','Teal','Ultramarine')
  foreach ($name in $normalNames) {
    if ($clean -ieq $name) { return $name }
  }
  $hex = $clean.TrimStart('#').ToLowerInvariant()
  $known = @{
    '000000'='Black'; '1b1b1b'='Black'; 'f5f5f0'='White'; 'ffffff'='White'; 'e1e4e3'='Silver';
    '3a3a3c'='Graphite'; 'c7c8ca'='Silver'; 'f9e5c9'='Gold'; '2e4755'='Blue'; '4f5d2f'='Green';
    'a50011'='Red'; 'e4d4c7'='Starlight'; '1d242d'='Midnight'; '675e7a'='Purple'
  }
  if ($known.ContainsKey($hex)) { return $known[$hex] }
  if ($clean -match '^[A-Za-z][A-Za-z ]+$') { return (Get-Culture).TextInfo.ToTitleCase($clean.ToLowerInvariant()) }
  return ''
}

function Convert-DeviceColorName {
  param([string]$ProductType, [string]$Value)
  $direct = Convert-ColorName $Value
  if ($direct) { return $direct }
  if ([string]::IsNullOrWhiteSpace($ProductType) -or [string]::IsNullOrWhiteSpace($Value)) { return '' }

  $tablePath = Join-Path $readerRoot 'devices_table.txt'
  if (-not (Test-Path -LiteralPath $tablePath -PathType Leaf)) { return '' }
  try {
    $table = Get-Content -Raw -LiteralPath $tablePath | ConvertFrom-Json
    foreach ($group in @($table.Images)) {
      $supportsProduct = @($group.SupportTypes | Where-Object { [string]$_.ProductType -eq $ProductType }).Count -gt 0
      if (-not $supportsProduct) { continue }
      $match = @($group.imgs | Where-Object { [string]$_.BackColor -eq [string]$Value } | Select-Object -First 1)
      if ($match.Count -and $match[0].BackColorText) {
        return (Get-Culture).TextInfo.ToTitleCase(([string]$match[0].BackColorText).ToLowerInvariant())
      }
    }
  } catch {}
  return ''
}

function Read-AppleDevice {
  param([string]$Udid)
  if ($udid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$') {
    $message = 'The connected phone returned an invalid device identifier. Reconnect the iPhone and try again.'
    return @{ ok = $false; error = $message; message = $message }
  }

  $general = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid -s" 8)
  $identityMaps = @($general)
  $imei = (Find-FirstValue $identityMaps @('InternationalMobileEquipmentIdentity', 'IMEI')).Trim()
  if (-not $imei) { $imei = (Get-DeviceInfoValue 'InternationalMobileEquipmentIdentity' $udid).Trim() }
  if ($imei -notmatch '^[0-9]{15}$') { $imei = '' }
  # Read identity before slower optional battery diagnostics consume the budget.
  # greenloop-dual-imei-20261023: secondary is never a fallback main identity.
  $imei2 = (Find-FirstValue $identityMaps @('InternationalMobileEquipmentIdentity2')).Trim()
  if (-not $imei2) { $imei2 = (Get-DeviceInfoValue 'InternationalMobileEquipmentIdentity2' $udid).Trim() }
  if ($imei2 -notmatch '^[0-9]{15}$' -or $imei2 -eq $imei) { $imei2 = '' }
  $serialNumber = Find-FirstValue $identityMaps @('SerialNumber')
  if (-not $serialNumber) { $serialNumber = Get-DeviceInfoValue 'SerialNumber' $udid }
  $phoneRegion = Find-FirstValue $identityMaps @('RegionInfo')
  if (-not $phoneRegion) { $phoneRegion = Get-DeviceInfoValue 'RegionInfo' $udid }
  if (-not $phoneRegion) { $phoneRegion = Find-FirstValue $identityMaps @('RegionCode') }
  $productType = Find-FirstValue $identityMaps @('ProductType')
  if (-not $productType) { $productType = Get-DeviceInfoValue 'ProductType' $udid }
  $reportedName = Find-FirstValue $identityMaps @('MarketingName')
  if (-not $reportedName) { $reportedName = Get-DeviceInfoValue 'MarketingName' $udid }
  if (-not $reportedName) { $reportedName = Find-FirstValue $identityMaps @('ProductName') }
  # DeviceColor is the front/bezel code. On iPhone 15 it is 1 for every
  # body color, so it must never substitute for a missing enclosure value.
  $colorRaw = Find-FirstValue $identityMaps @('DeviceEnclosureColor')
  if (-not $colorRaw) { $colorRaw = Get-DeviceInfoValue 'DeviceEnclosureColor' $udid }
  $disk = @{}
  $battery = @{}
  $batteryXml = ''
  try { $disk = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid -q com.apple.disk_usage" 6) } catch {}
  try { $battery = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid -q com.apple.mobile.battery" 6) } catch {}
  try { $batteryXml = Invoke-ReadOnlyTool 'idevicediagnostics.exe' "-u $udid ioregentry AppleSmartBattery" 8 } catch {}
  $maps = @($general, $disk, $battery)

  $storageRaw = Find-FirstValue $maps @('TotalDiskCapacity', 'TotalDataCapacity', 'DiskCapacity', 'StorageCapacity')
  if (-not $colorRaw) { $colorRaw = Find-FirstValue $maps @('DeviceEnclosureColor') }
  $batteryHealth = Convert-BatteryHealth $maps $batteryXml

  return @{
    ok = $true
    device = @{
      udid = $udid
      connectionId = 'ios:' + $udid
      platform = 'ios'
      brand = 'Apple'
      imei = $imei
      imei2 = $imei2
      identitySchemaVersion = 2
      model = Convert-ModelName $productType $reportedName
      productType = $productType
      storageGb = Convert-StorageGb $storageRaw
      color = Convert-DeviceColorName $productType $colorRaw
      batteryHealth = $batteryHealth
      batteryHealthSource = $script:batteryHealthSource
      batteryHealthUnavailable = ($null -eq $batteryHealth)
      serialNumber = ([string]$serialNumber).Trim()
      phoneRegion = ([string]$phoneRegion).Trim()
    }
  }
}

function New-ReaderError {
  param([string]$Code, [string]$Message, [string]$DetectedPlatform = '', [string]$DetectedBrand = '')
  $result = @{ ok = $false; code = $Code; error = $Message; message = $Message }
  # These are connection hints, never a readable device or a savable entry.
  if ($DetectedPlatform) { $result.detectedPlatform = $DetectedPlatform }
  if ($DetectedBrand) { $result.detectedBrand = $DetectedBrand }
  return $result
}

function Convert-UsbPhoneHint {
  param([string]$Text)
  # Consume only the current /connected enumeration. Match invariant hardware
  # identifiers rather than localized labels, friendly names or registry history.
  # These Samsung mobile PIDs cover MTP, tethering and MIDI. Vendor ID alone
  # would incorrectly identify monitors, storage and other Samsung accessories.
  $parents = @{}
  $mobilePids = @{}
  $tetherPids = @{}
  foreach ($block in ($Text -split '(?:\r?\n)[\t ]*(?:\r?\n)')) {
    $idMatch = [regex]::Match($block, '(?im)^[^\r\n]*?\b(USB\\VID_04E8&PID_(6860|6863|686C)(?:&[A-Z0-9_]+)*\\[^\s\r\n]+)')
    if (-not $idMatch.Success) { continue }
    $instance = $idMatch.Groups[1].Value.ToUpperInvariant()
    $usbPid = $idMatch.Groups[2].Value.ToUpperInvariant()
    if ($instance -match '^USB\\VID_04E8&PID_(6860|6863|686C)\\') { $parents[$instance] = $usbPid }
    if ($block -match '(?i)USB\\SAMSUNG_MOBILE(?:&|\s|$)|&SAMSUNG_Android(?:\\|\s|$)') { $mobilePids[$usbPid] = $true }
    if ($block -match '(?i)USB\\(?:SAMSUNG_MOBILE|VID_04E8&PID_6863)&RNdis(?:\\|\s|$)') { $tetherPids[$usbPid] = $true }
  }
  $phones = @($parents.Keys | Where-Object { $mobilePids.ContainsKey([string]$parents[$_]) })
  if (-not $phones.Count) { return $null }
  if ($phones.Count -gt 1) {
    return @{ count = $phones.Count; code = 'multiple-devices'; message = 'More than one Samsung phone is connected. Keep only the phone being entered connected, then read again.' }
  }
  if ($tetherPids.ContainsKey([string]$parents[$phones[0]])) {
    return @{ count = 1; code = 'android-usb-tethering'; detectedPlatform = 'android'; detectedBrand = 'Samsung'; message = 'Samsung phone detected in USB tethering mode. Turn off USB tethering, choose File transfer / Android Auto, enable USB debugging and tap Allow on the phone.' }
  }
  return @{ count = 1; code = 'android-usb-debugging-needed'; detectedPlatform = 'android'; detectedBrand = 'Samsung'; message = 'Samsung phone is connected by USB, but its reading connection is not available. Enable USB debugging and tap Allow on the phone. If debugging is already enabled, reconnect the cable and check the Samsung USB driver.' }
}

function Get-UsbPhoneHint {
  try {
    return Convert-UsbPhoneHint (Invoke-ReadOnlyTool 'pnputil.exe' '/enum-devices /connected /bus USB /deviceids' 2)
  } catch {
    # Unsupported Windows versions or unavailable enumeration must not replace
    # the normal phone-discovery result, and never fabricate connection details.
    return $null
  }
}

function Convert-AndroidProperties {
  param([string]$Text)
  $properties = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -cmatch '^\[([a-zA-Z0-9_.-]+)\]: \[(.*)\]$') {
      $properties[$matches[1]] = $matches[2].Trim()
    }
  }
  return $properties
}

function Convert-AndroidDevices {
  param([string]$Text)
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload|bootloader|no permissions)(?:\s|$)') {
      $serial = $matches[1]; $state = $matches[2]
      # Do not read emulators or wireless/network endpoints as stock phones.
      if ($serial -cmatch '^[A-Za-z0-9._-]{1,128}$' -and $serial -notmatch '^emulator-' -and
          $serial -notmatch '(?i)(?:^adb-.*\._adb-tls-(?:connect|pairing)\._tcp\.?$|\._adb(?:-tls-(?:connect|pairing))?\._tcp\.?$)') {
        @{ serial = $serial; state = $state }
      }
    }
  }
}

function Read-AndroidDevice {
  param([string]$Serial)
  if ($Serial -cnotmatch '^[A-Za-z0-9._-]{1,128}$') { throw 'Invalid Android transport identifier.' }
  $properties = Convert-AndroidProperties (Invoke-ReadOnlyTool 'adb.exe' ('-s "' + $Serial + '" shell getprop') 8)
  $manufacturer = Find-FirstValue @($properties) @('ro.product.manufacturer', 'ro.product.brand')
  $model = Find-FirstValue @($properties) @('ro.product.model', 'ro.product.vendor.model', 'ro.product.system.model')
  if (-not $manufacturer -and -not $model) {
    return New-ReaderError 'android-read-failed' 'Android details could not be read. Unlock the phone, allow USB debugging for this computer and try again.'
  }
  $brandNames = @{samsung='Samsung';google='Google';xiaomi='Xiaomi';redmi='Redmi';poco='Poco';oneplus='OnePlus';oppo='OPPO';vivo='vivo';realme='realme';motorola='Motorola';nokia='Nokia';sony='Sony';huawei='Huawei';honor='HONOR';asus='ASUS';lenovo='Lenovo';zte='ZTE';nothing='Nothing';tecno='TECNO';infinix='Infinix'}
  $brand = $manufacturer.Trim()
  if ($brandNames.ContainsKey($brand.ToLowerInvariant())) { $brand = $brandNames[$brand.ToLowerInvariant()] }
  # Some vendors publish IMEI properties. Accept only an exact IMEI string;
  # never derive it from the USB serial, Android ID, model or a combined pair.
  $imei = ''
  foreach ($key in @('ril.gsm.imei', 'ril.imei', 'persist.radio.imei')) {
    $value = [string]$properties[$key]
    if ($value -cmatch '^[0-9]{15}$' -and $value -notmatch '^0{15}$') { $imei = $value; break }
  }
  $serialNumber = Find-FirstValue @($properties) @('ro.serialno', 'ro.boot.serialno')
  if ($serialNumber -match '^(unknown|null|none)$') { $serialNumber = '' }
  # Android locale is a user setting, not sales region. Filesystem capacity is
  # not advertised storage. Battery level/health enum is not battery health %.
  # These fields remain manual until a manufacturer provides a reliable value.
  return @{
    ok = $true
    message = 'Android connected. Available details read; complete any missing fields manually.'
    device = @{
      connectionId = 'android:' + $Serial
      platform = 'android'
      brand = $brand
      imei = $imei
      model = $model
      productType = $model
      storageGb = $null
      color = ''
      batteryHealth = $null
      batteryHealthSource = 'unavailable'
      batteryHealthUnavailable = $true
      serialNumber = $serialNumber
      phoneRegion = ''
      osVersion = Find-FirstValue @($properties) @('ro.build.version.release')
    }
  }
}

function Read-ConnectedDevice {
  $appleIds = @()
  $appleError = ''
  try {
    $ids = Invoke-ReadOnlyTool 'idevice_id.exe' '-l' 3
    $appleIds = @($ids -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  } catch { $appleError = $_.Exception.Message }
  $androidDevices = @()
  $androidError = ''
  $adbPath = Get-AdbPath
  if ($adbPath) {
    try {
      $androidDiscovery = Invoke-ReadOnlyTool 'adb.exe' 'devices -l' 3
      if ($androidDiscovery -notmatch '(?m)^List of devices attached\s*\r?$') { throw 'Android discovery returned an unrecognized result.' }
      $androidDevices = @(Convert-AndroidDevices $androidDiscovery)
    }
    catch { $androidError = $_.Exception.Message }
  }
  if (($appleIds.Count + $androidDevices.Count) -gt 1) {
    return New-ReaderError 'multiple-devices' 'More than one phone is connected. Keep only the phone being entered connected, then read again.'
  }
  # A failed discovery could hide another phone. Never silently choose the
  # other platform when we cannot verify that it is the only attached device.
  if ($appleError -or $androidError) {
    return New-ReaderError 'discovery-unavailable' 'Phone discovery is temporarily unavailable. Check the cable and Apple/Android USB drivers, then read again.'
  }
  $usbHint = $null
  if ($androidDevices.Count -eq 0 -and $adbPath) { $usbHint = Get-UsbPhoneHint }
  if ($usbHint -and ($appleIds.Count + $usbHint.count) -gt 1) {
    return New-ReaderError 'multiple-devices' 'More than one phone is connected. Keep only the phone being entered connected, then read again.'
  }
  if ($appleIds.Count -eq 1) { return Read-AppleDevice $appleIds[0] }
  if ($androidDevices.Count -eq 1) {
    $phone = $androidDevices[0]
    if ($phone.state -eq 'unauthorized') {
      return New-ReaderError 'android-unauthorized' 'Android connected: unlock the phone and tap Allow on the USB debugging request for this computer.' 'android'
    }
    if ($phone.state -ne 'device') {
      return New-ReaderError 'android-offline' 'Android is offline or in recovery mode. Start Android normally, unlock the phone and reconnect its USB cable.' 'android'
    }
    return Read-AndroidDevice $phone.serial
  }
  if (-not $adbPath) {
    return New-ReaderError 'android-tools-missing' 'No iPhone detected. Android tools are not installed yet; run the Greenloop Android Reader update once.'
  }
  if ($usbHint) { return New-ReaderError $usbHint.code $usbHint.message $usbHint.detectedPlatform $usbHint.detectedBrand }
  return New-ReaderError 'no-device' 'Connect one unlocked phone. iPhone: accept Trust. Android: enable USB debugging and allow this computer; use a data cable and install its USB driver if needed.'
}

function Get-ConnectedDevice {
  # Keep a whole read below the website's 20-second request timeout. Optional
  # fields can remain empty when unavailable; the next poll can enrich them.
  $previousDeadline = $script:readerReadDeadline
  $script:readerReadDeadline = [datetime]::UtcNow.AddSeconds(18)
  try { return Read-ConnectedDevice }
  finally { $script:readerReadDeadline = $previousDeadline }
}

function Test-AllowedOrigin([string]$Origin) {
  return -not $Origin -or $Origin -ceq 'https://greenloopfzc.github.io' -or $Origin -cmatch '^http://(?:127\.0\.0\.1|localhost)(?::[0-9]{1,5})?$'
}

function Write-HttpResponse {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [int]$StatusCode,
    [string]$StatusText,
    [string]$Body,
    [string]$Origin = ''
  )
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $headers = @(
    "HTTP/1.1 $StatusCode $StatusText",
    'Content-Type: application/json; charset=utf-8',
    "Content-Length: $($bodyBytes.Length)",
    $(if ($Origin -and (Test-AllowedOrigin $Origin)) { "Access-Control-Allow-Origin: $Origin" }),
    'Vary: Origin',
    'Access-Control-Allow-Methods: GET, OPTIONS',
    'Access-Control-Allow-Headers: Content-Type',
    'Access-Control-Allow-Private-Network: true',
    'Cache-Control: no-store',
    'Connection: close',
    '', ''
  ) | Where-Object { $null -ne $_ }
  $headers = $headers -join "`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bodyBytes.Length) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
  $Stream.Flush()
}

$readerMutex = [System.Threading.Mutex]::new($false, ('Local\Greenloop.ReadOnlyDeviceReader.' + $Port))
$ownsMutex = $false
$listener = $null
try {
  try { $ownsMutex = $readerMutex.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { return }
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 5000
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
      $requestLine = $reader.ReadLine()
      $requestOrigin = ''
      while ($headerLine = $reader.ReadLine()) {
        if ($headerLine -match '^Origin:\s*(.*)$') {
          if ($requestOrigin) { $requestOrigin = 'invalid-duplicate-origin' } else { $requestOrigin = $matches[1].Trim() }
        }
      }
      if (-not (Test-AllowedOrigin $requestOrigin)) {
        Write-HttpResponse $stream 403 'Forbidden' '{"ok":false,"message":"This reader is available only to Greenloop."}'
        continue
      }
      if ($requestLine -match '^OPTIONS\s+') {
        Write-HttpResponse $stream 204 'No Content' '' $requestOrigin
        continue
      }
      $path = if ($requestLine -match '^GET\s+([^\s]+)') { $matches[1].Split('?')[0] } else { '' }
      if ($path -eq '/health') {
        Write-HttpResponse $stream 200 'OK' (@{ ok = $true; service = 'Greenloop Read-Only Device Reader'; dualImeiVersion = '20261023-dual-imei-1'; mode = 'read-only'; version = '20261001-android-reader-2'; platforms = @('ios','android'); androidToolsReady = [bool](Get-AdbPath) } | ConvertTo-Json -Compress) $requestOrigin
      } elseif ($path -eq '/v1/device') {
        try {
          $payload = Get-ConnectedDevice
          Write-HttpResponse $stream 200 'OK' ($payload | ConvertTo-Json -Depth 5 -Compress) $requestOrigin
        } catch {
          Write-HttpResponse $stream 200 'OK' (@{ ok = $false; error = $_.Exception.Message; message = $_.Exception.Message } | ConvertTo-Json -Compress) $requestOrigin
        }
      } else {
        Write-HttpResponse $stream 404 'Not Found' (@{ ok = $false; error = 'Not found.' } | ConvertTo-Json -Compress) $requestOrigin
      }
    } catch {
      try { Write-HttpResponse $stream 500 'Internal Server Error' (@{ ok = $false; error = $_.Exception.Message; message = $_.Exception.Message } | ConvertTo-Json -Compress) } catch {}
    } finally {
      $client.Close()
    }
  }
} finally {
  if ($listener) { $listener.Stop() }
  if ($ownsMutex) { $readerMutex.ReleaseMutex() }
  $readerMutex.Dispose()
}
