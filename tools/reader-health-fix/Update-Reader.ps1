function ConvertTo-GreenloopHealthReader {
 param([string]$Source)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
 if($errors.Count -or -not $Source.Contains('greenloop-dual-imei-20261023')){throw 'Existing reader source is not recognized. Nothing changed.'}
 $replacement=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Reader-Functions.ps1'))
 $new=[Management.Automation.Language.Parser]::ParseInput($replacement,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'New reader functions failed syntax validation.'}
 $edits=@();$addition=''
 foreach($name in @('Get-ReportedBatteryHealth','Convert-BatteryHealth')){
  $old=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  $fresh=@($new.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  if($fresh.Count -ne 1 -or $old.Count -gt 1 -or ($old.Count -eq 0 -and $name -ne 'Get-ReportedBatteryHealth')){throw 'Reader function boundary not recognized. Original reader preserved.'}
  if($old.Count){$edits+=@{start=$old[0].Extent.StartOffset;end=$old[0].Extent.EndOffset;text=$fresh[0].Extent.Text}}
  else{$addition=$fresh[0].Extent.Text+"`n"}
 }
 foreach($edit in ($edits|Sort-Object start -Descending)){$Source=$Source.Substring(0,$edit.start)+$edit.text+$Source.Substring($edit.end)}
 if($addition){$at=$Source.IndexOf('function Convert-BatteryHealth');$Source=$Source.Insert($at,$addition)}
 $health="service = 'Greenloop Read-Only Device Reader';"
 if(([regex]::Matches($Source,[regex]::Escape($health))).Count -ne 1){throw 'Reader health boundary not recognized. Nothing changed.'}
 $marker="readerBatteryHealthVersion = '20261112-bh-capacity-1';"
 if(-not $Source.Contains($marker)){$Source=$Source.Replace($health,$health+' '+$marker)}
 [void][Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Patched reader failed syntax validation. Nothing changed.'}
 return $Source
}
