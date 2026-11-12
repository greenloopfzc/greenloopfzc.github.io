function Get-ReportedBatteryHealth {
 param([string]$BatteryXml)
 if([string]::IsNullOrWhiteSpace($BatteryXml) -or $BatteryXml.Length -gt 524288){return $null}
 $reader=$null
 try{
  $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Ignore;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=524288
  $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($BatteryXml),$settings)
  $doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.Load($reader)
  $dict=$doc.SelectSingleNode('/plist/dict/key[.="IORegistry"]/following-sibling::*[1][self::dict]')
  if(-not $dict){$dict=$doc.SelectSingleNode('/plist/dict/key[.="Diagnostics"]/following-sibling::*[1][self::dict]/key[.="IORegistry"]/following-sibling::*[1][self::dict]')}
  if(-not $dict){$dict=$doc.SelectSingleNode('/plist/dict')}
  # These direct AppleSmartBattery percentages are not LPEMData capacity in mAh,
  # charging CurrentCapacity, or the unrelated BatteryHealthMetric.
  $batteryData=$dict.SelectSingleNode('key[.="BatteryData"]/following-sibling::*[1][self::dict]')
  foreach($scope in @($dict,$batteryData)){
   if(-not $scope){continue}
   foreach($key in @('MaximumCapacityPercent','MaximumCapacityPercentage','BatteryHealthPercentage')){
    $node=$scope.SelectSingleNode('key[.="'+$key+'"]/following-sibling::*[1]')
    if($node -and $node.Name -in @('integer','real') -and $node.InnerText -match '^[0-9]+(?:\.[0-9]+)?$'){
     $value=[double]::Parse($node.InnerText,[Globalization.CultureInfo]::InvariantCulture)
     if($value -ge 1 -and $value -le 100){return [int][math]::Round($value)}
    }
   }
  }
 }catch{}finally{if($reader){$reader.Dispose()}}
 return $null
}

function Convert-BatteryHealth {
  param([hashtable[]]$Maps, [string]$BatteryXml = '')
  $script:batteryHealthSource = 'unavailable'
  $direct = Find-FirstValue $Maps @('BatteryHealth', 'BatteryHealthPercentage', 'MaximumCapacityPercent', 'MaximumCapacityPercentage', 'HealthPercentage')
  $directNumber = 0.0
  if ($direct -and [double]::TryParse(($direct -replace '[^0-9.]', ''), [ref]$directNumber)) {
    if ($directNumber -ge 1 -and $directNumber -le 100) { $script:batteryHealthSource = 'device'; return [int][math]::Round($directNumber) }
  }

  $reportedDevice = Get-ReportedBatteryHealth $BatteryXml
  if($null -ne $reportedDevice){$script:batteryHealthSource='device';return $reportedDevice}

  # MaxCapacity=100 is a normalized charge scale, NOT Settings battery health.
  # Prefer calibrated nominal capacity over fluctuating raw capacity for estimates.
  # Estimates remain explicitly labeled and must not be described as Settings health.
  # Explicit health percentages take precedence over capacity estimates.
  $reported = Get-PlistInteger $BatteryXml @('MaximumCapacityPercent','MaximumCapacityPercentage','BatteryHealthPercentage')
  if ($null -ne $reported -and $reported -ge 1 -and $reported -le 100) { $script:batteryHealthSource = 'device'; return [int]$reported }
  $currentXml = Get-PlistInteger $BatteryXml @('NominalChargeCapacity', 'AppleRawMaxCapacity')
  $designXml = Get-PlistInteger $BatteryXml @('DesignCapacity', 'BatteryDesignCapacity')
  if ($null -ne $currentXml -and $null -ne $designXml -and $designXml -gt 0) {
    $xmlPercentage = [math]::Round(($currentXml / $designXml) * 100)
    if ($xmlPercentage -ge 1) { $script:batteryHealthSource = 'capacity-estimate'; return [int][math]::Min(100,$xmlPercentage) }
  }

  $current = Find-FirstValue $Maps @('NominalChargeCapacity', 'AppleRawMaxCapacity')
  $design = Find-FirstValue $Maps @('DesignCapacity', 'BatteryDesignCapacity')
  $currentNumber = 0.0
  $designNumber = 0.0
  if ($current -and $design -and
      [double]::TryParse(($current -replace '[^0-9.]', ''), [ref]$currentNumber) -and
      [double]::TryParse(($design -replace '[^0-9.]', ''), [ref]$designNumber) -and
      $designNumber -gt 0) {
    $percentage = [math]::Round(($currentNumber / $designNumber) * 100)
    if ($percentage -ge 1) { $script:batteryHealthSource = 'capacity-estimate'; return [int][math]::Min(100,$percentage) }
  }
  return $null
}

function Read-AppleDevice {
  param([string]$Udid)
  if ($udid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$') {
    $message = 'The connected phone returned an invalid device identifier. Reconnect the iPhone and try again.'
    return @{ ok = $false; error = $message; message = $message }
  }

  # Cache only after fresh Apple/Android discovery has verified this UDID.
  if($script:appleFastCache -and $script:appleFastCache.udid -ne $udid){$script:appleFastCache=$null}
  if(-not $script:readerForceRefresh -and $script:appleFastCache -and ([datetime]::UtcNow-$script:appleFastCache.at).TotalMilliseconds -ge 0 -and ([datetime]::UtcNow-$script:appleFastCache.at).TotalMilliseconds -lt $script:appleFastCache.ttl){return $script:appleFastCache.payload}
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
  $batteryXml = ''
  try { $batteryXml = Invoke-ReadOnlyTool 'idevicediagnostics.exe' "-u $udid ioregentry AppleSmartBattery" 5 } catch {}
  $reportedName = Find-FirstValue $identityMaps @('MarketingName')
  if (-not $reportedName -and (Convert-ModelName $productType '') -eq $productType) { $reportedName = Get-DeviceInfoValue 'MarketingName' $udid }
  if (-not $reportedName) { $reportedName = Find-FirstValue $identityMaps @('ProductName') }
  # DeviceColor is the front/bezel code. On iPhone 15 it is 1 for every
  # body color, so it must never substitute for a missing enclosure value.
  $colorRaw = Find-FirstValue $identityMaps @('DeviceEnclosureColor')
  if (-not $colorRaw) { $colorRaw = Get-DeviceInfoValue 'DeviceEnclosureColor' $udid }
  $disk = @{}
  $battery = @{}
  try { $disk = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid -q com.apple.disk_usage" 6) } catch {}
  if($null -eq (Convert-BatteryHealth @($general) $batteryXml)){try { $battery = Convert-KeyValueText (Invoke-ReadOnlyTool 'ideviceinfo.exe' "-u $udid -q com.apple.mobile.battery" 3) } catch {}}
  $maps = @($general, $disk, $battery)

  $storageRaw = Find-FirstValue $maps @('TotalDiskCapacity', 'TotalDataCapacity', 'DiskCapacity', 'StorageCapacity')
  if (-not $colorRaw) { $colorRaw = Find-FirstValue $maps @('DeviceEnclosureColor') }
  $batteryHealth = Convert-BatteryHealth $maps $batteryXml

  $result = @{
    ok = $true
    device = @{
      readerDetailsVersion = '20261106-battery-details-1'
      readerSpeedBhVersion = '20261111-fast-bh-1'
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
  $ttl=if($null -ne $batteryHealth -and $imei -and $result.device.storageGb -and $result.device.color){5000}else{1000}
  $script:appleFastCache=@{udid=$udid;at=[datetime]::UtcNow;ttl=$ttl;payload=$result}
  return $result
}

function Get-ConnectedDevice {
 param([switch]$ForceRefresh)
 $previousDeadline=$script:readerReadDeadline;$previousForce=$script:readerForceRefresh
 $script:readerReadDeadline=[datetime]::UtcNow.AddSeconds(18);$script:readerForceRefresh=[bool]$ForceRefresh
 try{
  $result=Read-ConnectedDevice
  if(-not $result -or $result.ok -ne $true){$script:appleFastCache=$null}
  return $result
 }catch{$script:appleFastCache=$null;throw}
 finally{$script:readerReadDeadline=$previousDeadline;$script:readerForceRefresh=$previousForce}
}
