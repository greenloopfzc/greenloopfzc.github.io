function ConvertTo-GreenloopDualIMEIReader {
  param([Parameter(Mandatory=$true)][string]$Source)
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'The installed reader has syntax errors. It was preserved.'}
  $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-AppleDevice'},$true))
  if($functions.Count -ne 1){throw 'The installed iPhone reader function was not recognized. It was preserved.'}
  $fn=$functions[0];$old=$fn.Extent.Text
  if($old.Contains('# greenloop-dual-imei-20261023')) {
    if(-not $old.Contains('imei2 = $imei2') -or -not $Source.Contains("dualImeiVersion = '20261023-dual-imei-1'")){throw 'The installed dual IMEI patch is incomplete.'}
    return $Source
  }
  if(-not $old.Contains("'InternationalMobileEquipmentIdentity', 'InternationalMobileEquipmentIdentity2', 'IMEI'") -or -not $old.Contains('$serialNumber = Find-FirstValue') -or -not $old.Contains('imei = $imei')){throw 'The installed reader differs from the reviewed iPhone reader. It was preserved.'}
  $new=$old.Replace("'InternationalMobileEquipmentIdentity', 'InternationalMobileEquipmentIdentity2', 'IMEI'","'InternationalMobileEquipmentIdentity', 'IMEI'")
  $insert=@'
  # greenloop-dual-imei-20261023: secondary is never a fallback main identity.
  $imei2 = (Find-FirstValue $identityMaps @('InternationalMobileEquipmentIdentity2')).Trim()
  if (-not $imei2) { $imei2 = (Get-DeviceInfoValue 'InternationalMobileEquipmentIdentity2' $udid).Trim() }
  if ($imei2 -notmatch '^[0-9]{15}$' -or $imei2 -eq $imei) { $imei2 = '' }
  $serialNumber = Find-FirstValue
'@
  $new=$new.Replace('$serialNumber = Find-FirstValue',$insert.TrimStart())
  $new=$new.Replace('imei = $imei',"imei = `$imei`r`n      imei2 = `$imei2`r`n      identitySchemaVersion = 2")
  $result=$Source.Substring(0,$fn.Extent.StartOffset)+$new+$Source.Substring($fn.Extent.EndOffset)
  $health="service = 'Greenloop Read-Only Device Reader';"
  if(([regex]::Matches($result,[regex]::Escape($health))).Count -ne 1){throw 'The reader health endpoint was not recognized. It was preserved.'}
  $result=$result.Replace($health,$health+" dualImeiVersion = '20261023-dual-imei-1';")
  [void][Management.Automation.Language.Parser]::ParseInput($result,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'Updated reader syntax verification failed. Nothing was installed.'}
  return $result
}

function ConvertTo-GreenloopReaderHash {
  param([string]$Source,[string]$PreviousHash,[string]$NewHash)
  $pattern="(?m)^\`$expectedReaderHash\s*=\s*'([A-Fa-f0-9]{64})'"
  $found=[regex]::Matches($Source,$pattern)
  if($found.Count -ne 1 -or ($found[0].Groups[1].Value -ine $PreviousHash -and $found[0].Groups[1].Value -ine $NewHash)){throw 'Launcher/supervisor reader hash differs from the installed source. Files were preserved.'}
  return [regex]::Replace($Source,$pattern,('$expectedReaderHash = '''+$NewHash+''''))
}
