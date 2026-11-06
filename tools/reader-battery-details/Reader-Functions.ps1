function Convert-BatteryHealth {
  param([hashtable[]]$Maps, [string]$BatteryXml = '')
  $script:batteryHealthSource = 'unavailable'
  $direct = Find-FirstValue $Maps @('BatteryHealth', 'BatteryHealthPercentage', 'MaximumCapacityPercent', 'MaximumCapacityPercentage', 'HealthPercentage')
  $directNumber = 0.0
  if ($direct -and [double]::TryParse(($direct -replace '[^0-9.]', ''), [ref]$directNumber)) {
    if ($directNumber -ge 1 -and $directNumber -le 100) { $script:batteryHealthSource = 'device'; return [int][math]::Round($directNumber) }
  }

  # Explicit health percentages take precedence over capacity estimates.
  $reported = Get-PlistInteger $BatteryXml @('MaximumCapacityPercent','MaximumCapacityPercentage','BatteryHealthPercentage')
  if ($null -ne $reported -and $reported -ge 1 -and $reported -le 100) { $script:batteryHealthSource = 'device'; return [int]$reported }
  $currentXml = Get-PlistInteger $BatteryXml @('AppleRawMaxCapacity', 'NominalChargeCapacity')
  $designXml = Get-PlistInteger $BatteryXml @('DesignCapacity', 'BatteryDesignCapacity')
  if ($null -ne $currentXml -and $null -ne $designXml -and $designXml -gt 0) {
    $xmlPercentage = [math]::Round(($currentXml / $designXml) * 100)
    if ($xmlPercentage -ge 1 -and $xmlPercentage -le 100) { $script:batteryHealthSource = 'capacity-estimate'; return [int]$xmlPercentage }
  }

  $current = Find-FirstValue $Maps @('AppleRawMaxCapacity', 'NominalChargeCapacity')
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

function Read-AppleDevice {
  param([string]$Udid)
  if ($udid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$') {
    $message = 'The connected phone returned an invalid device identifier. Reconnect the iPhone and try again.'
    return @{ ok = $false; error = $message; message = $message }
  }

  $general = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid" 8)
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
      readerDetailsVersion = '20261106-battery-details-1'
      phoneName = Find-FirstValue @($general) @('DeviceName')
      osVersion = Find-FirstValue @($general) @('ProductVersion')
      bootFirmware = Find-FirstValue @($general) @('FirmwareVersion')
      baseband = Find-FirstValue @($general) @('BasebandVersion')
      batteryCycleCount = Get-PlistInteger $batteryXml @('CycleCount')
      rawCapacity = Get-PlistInteger $batteryXml @('AppleRawMaxCapacity')
      designCapacity = Get-PlistInteger $batteryXml @('DesignCapacity','BatteryDesignCapacity')
      chargingStatus = $(if ($batteryXml -match '(?s)<key>IsCharging</key>\s*<true\s*/>') {'Charging'} elseif ($batteryXml -match '(?s)<key>IsCharging</key>\s*<false\s*/>') {'Not charging'} else {''})
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
