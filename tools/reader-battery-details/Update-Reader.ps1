function ConvertTo-GreenloopBatteryDetailsReader {
 param([string]$Source)
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'Installed reader syntax is invalid. Nothing was replaced.'}
 if(-not $Source.Contains('greenloop-dual-imei-20261023')){throw 'Install the existing Dual IMEI reader update first. Existing reader preserved.'}
 $replacement=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Reader-Functions.ps1'))
 $newAst=[Management.Automation.Language.Parser]::ParseInput($replacement,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'New reader functions failed syntax validation.'}
 $edits=@()
 foreach($name in @('Convert-BatteryHealth','Read-AppleDevice')){
  $old=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  $new=@($newAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  if($old.Count -ne 1 -or $new.Count -ne 1){throw 'Reader functions not recognized. Existing reader preserved.'}
  if($name -eq 'Read-AppleDevice' -and (-not $old[0].Extent.Text.Contains('imei2 = $imei2') -or -not $old[0].Extent.Text.Contains('batteryHealthSource = $script:batteryHealthSource'))){throw 'Installed iPhone reader is incompatible. Nothing changed.'}
  $edits+=@{start=$old[0].Extent.StartOffset;end=$old[0].Extent.EndOffset;text=$new[0].Extent.Text}
 }
 foreach($edit in ($edits|Sort-Object start -Descending)){$Source=$Source.Substring(0,$edit.start)+$edit.text+$Source.Substring($edit.end)}
 $marker="readerDetailsVersion = '20261106-battery-details-1';"
 if(-not $Source.Contains($marker)){
  $health="service = 'Greenloop Read-Only Device Reader';"
  if(([regex]::Matches($Source,[regex]::Escape($health))).Count -ne 1){throw 'Reader health endpoint not recognized. Nothing changed.'}
  $Source=$Source.Replace($health,$health+' '+$marker)
 }
 [void][Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'Patched reader syntax failed. Nothing changed.'}
 return $Source
}
