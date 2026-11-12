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

