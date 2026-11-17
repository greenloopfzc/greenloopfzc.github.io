# Shared per-user automatic startup; no credentials, elevation or ZIP path in task.
function Get-GreenloopAutostartTask {
 param([string]$ReaderRoot,[string]$PowerShell)
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$folder=$service.GetFolder('\')
 $name='Greenloop Cable Reader - '+$sid;$existing=$null
 try{$existing=$folder.GetTask($name)}catch{$cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException};if(($cause.HResult -band 0xffff) -ne 2){throw}}
 if($existing){
  $definition=$existing.Definition;$actions=$definition.Actions
  if($actions.Count -ne 1){throw 'An unrelated task uses the Greenloop name. It was preserved.'}
  $action=$actions.Item(1);$owner=$definition.Principal.UserId
  if($owner -notmatch '^S-1-'){try{$owner=([Security.Principal.NTAccount]$owner).Translate([Security.Principal.SecurityIdentifier]).Value}catch{throw 'Task owner could not be verified.'}}
  $owned=$false
  $filePattern='(?i)(?:^|\s)-File\s+"([^"]+)"(?=\s|$)'
  $matches=[regex]::Matches($action.Arguments,$filePattern)
  $remaining=[regex]::Replace($action.Arguments,$filePattern,' ')
  $remaining=[regex]::Replace($remaining,'(?i)(?:^|\s)-(?:NoProfile|NonInteractive|ExecutionPolicy\s+Bypass|WindowStyle\s+(?:Hidden|Normal|Minimized))(?=\s|$)',' ')
  if($matches.Count -eq 1 -and -not $remaining.Trim()){foreach($file in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){if([IO.Path]::GetFullPath($matches[0].Groups[1].Value) -ieq [IO.Path]::GetFullPath((Join-Path $ReaderRoot $file))){$owned=$true}}}
  if($owner -cne $sid -or $action.Type -ne 0 -or [IO.Path]::GetFullPath($action.Path) -ine [IO.Path]::GetFullPath($PowerShell) -or -not $owned){throw 'An unrelated task uses the Greenloop name. It was preserved.'}
 }
 return @{sid=$sid;name=$name;folder=$folder;existing=$existing}
}
function Get-GreenloopAutostartXml {
 param([string]$ReaderRoot,[string]$PowerShell,[string]$Sid)
 $escape={param($v)[Security.SecurityElement]::Escape($v)}
 $arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $ReaderRoot 'Watch-Greenloop-Reader.ps1')+'"'
 return @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>Greenloop read-only Cable Reader automatic startup 20261117</Description></RegistrationInfo><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$(& $escape $Sid)</UserId><Delay>PT15S</Delay></LogonTrigger></Triggers><Principals><Principal id="Reader"><UserId>$(& $escape $Sid)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings><Actions Context="Reader"><Exec><Command>$(& $escape $PowerShell)</Command><Arguments>$(& $escape $arguments)</Arguments><WorkingDirectory>$(& $escape $ReaderRoot)</WorkingDirectory></Exec></Actions></Task>
"@
}
function Assert-GreenloopAutostartXml {
 param([string]$Xml,[string]$ReaderRoot,[string]$PowerShell,[string]$Sid)
 [xml]$actual=$Xml;[xml]$expected=Get-GreenloopAutostartXml $ReaderRoot $PowerShell $Sid
 $ns=[Xml.XmlNamespaceManager]::new($actual.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
 $en=[Xml.XmlNamespaceManager]::new($expected.NameTable);$en.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
 foreach($parent in @('Triggers','Actions','Principals')){if($actual.SelectNodes('/t:Task/t:'+ $parent +'/*',$ns).Count -ne 1){throw 'Automatic startup contains unexpected actions/triggers.'}}
 $paths=@('Triggers/LogonTrigger/Enabled','Triggers/LogonTrigger/UserId','Triggers/LogonTrigger/Delay','Principals/Principal/UserId','Principals/Principal/LogonType','Principals/Principal/RunLevel','Actions/Exec/Command','Actions/Exec/Arguments','Actions/Exec/WorkingDirectory','Settings/MultipleInstancesPolicy','Settings/AllowHardTerminate','Settings/DisallowStartIfOnBatteries','Settings/StopIfGoingOnBatteries','Settings/StartWhenAvailable','Settings/RunOnlyIfNetworkAvailable','Settings/AllowStartOnDemand','Settings/Enabled','Settings/Hidden','Settings/RunOnlyIfIdle','Settings/ExecutionTimeLimit','Settings/RestartOnFailure/Interval','Settings/RestartOnFailure/Count')
 # Task Scheduler omits default-valued XML nodes and canonicalizes identities
 # and durations. Compare their effective values, not the submitted text.
 # Defaults: https://learn.microsoft.com/windows/win32/taskschd/task-scheduler-schema
 $defaults=@{
  'Triggers/LogonTrigger/Enabled'='true';'Triggers/LogonTrigger/Delay'='PT0M'
  'Principals/Principal/RunLevel'='LeastPrivilege'
  'Settings/MultipleInstancesPolicy'='IgnoreNew';'Settings/AllowHardTerminate'='true'
  'Settings/DisallowStartIfOnBatteries'='true';'Settings/StopIfGoingOnBatteries'='true'
  'Settings/StartWhenAvailable'='false';'Settings/RunOnlyIfNetworkAvailable'='false'
  'Settings/AllowStartOnDemand'='true';'Settings/Enabled'='true';'Settings/Hidden'='false'
  'Settings/RunOnlyIfIdle'='false';'Settings/ExecutionTimeLimit'='PT72H'
 }
 $booleans=@('Triggers/LogonTrigger/Enabled','Settings/AllowHardTerminate','Settings/DisallowStartIfOnBatteries','Settings/StopIfGoingOnBatteries','Settings/StartWhenAvailable','Settings/RunOnlyIfNetworkAvailable','Settings/AllowStartOnDemand','Settings/Enabled','Settings/Hidden','Settings/RunOnlyIfIdle')
 $durations=@('Triggers/LogonTrigger/Delay','Settings/ExecutionTimeLimit','Settings/RestartOnFailure/Interval')
 foreach($path in $paths){
  $xpath='/t:Task/t:'+($path -replace '/', '/t:');$nodes=$actual.SelectNodes($xpath,$ns);$b=$expected.SelectSingleNode($xpath,$en)
  if($nodes.Count -gt 1){throw ('Reader automatic startup has duplicate values: '+$path)}
  if($nodes.Count -eq 1){$value=$nodes.Item(0).InnerText}else{$value=$defaults[$path]}
  $same=$false
  if($null -ne $value){
   try{
    if($path -in $booleans){$same=[Xml.XmlConvert]::ToBoolean($value.Trim()) -eq [Xml.XmlConvert]::ToBoolean($b.InnerText)}
    elseif($path -in $durations){$same=[Xml.XmlConvert]::ToTimeSpan($value.Trim()) -eq [Xml.XmlConvert]::ToTimeSpan($b.InnerText)}
    elseif($path -eq 'Settings/RestartOnFailure/Count'){$same=[Xml.XmlConvert]::ToInt32($value.Trim()) -eq [Xml.XmlConvert]::ToInt32($b.InnerText)}
    elseif($path.EndsWith('/UserId')){
     $user=$value.Trim();if($user -notmatch '^S-1-'){$user=([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value}
     $same=$user -ceq $Sid
    }
    elseif($path -in @('Actions/Exec/Command','Actions/Exec/WorkingDirectory')){$same=[IO.Path]::GetFullPath($value).TrimEnd('\') -ieq [IO.Path]::GetFullPath($b.InnerText).TrimEnd('\')}
    elseif($path -eq 'Actions/Exec/Arguments'){
     $match=[regex]::Match($value,'(?i)^-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-WindowStyle\s+Hidden\s+-File\s+"([^"]+)"$')
     $same=$match.Success -and [IO.Path]::GetFullPath($match.Groups[1].Value) -ieq [IO.Path]::GetFullPath((Join-Path $ReaderRoot 'Watch-Greenloop-Reader.ps1'))
    }
    else{$same=$value -ceq $b.InnerText}
   }catch{$same=$false}
  }
  if(-not $same){throw ('Reader automatic startup verification differs: '+$path)}
 }
 $principal=$actual.SelectSingleNode('/t:Task/t:Principals/t:Principal',$ns)
 $context=$actual.SelectSingleNode('/t:Task/t:Actions',$ns).GetAttribute('Context')
 if($context -and $context -cne $principal.GetAttribute('id')){throw 'Reader task action principal differs.'}
 if($principal.SelectNodes('t:GroupId|t:RequiredPrivileges/t:Privilege',$ns).Count){throw 'Reader task has unexpected group or privilege settings.'}

}
function Install-GreenloopAutostart {
 param([string]$ReaderRoot,[string]$PowerShell,[string]$BackupRoot)
 $plan=Get-GreenloopAutostartTask $ReaderRoot $PowerShell
 $xml=Get-GreenloopAutostartXml $ReaderRoot $PowerShell $plan.sid
 $before=if($plan.existing){$plan.existing.Xml}else{$null}
 if($before){[IO.File]::WriteAllText((Join-Path $BackupRoot 'autostart-task-before.xml'),$before,[Text.UTF8Encoding]::new($false))}
 $registered=$false
 try{
  # TASK_CREATE=2 / TASK_UPDATE=4 prevent replacing a task that appeared after inspection.
  # TASK_LOGON_INTERACTIVE_TOKEN=3 uses this Windows login without a password.
  $task=$plan.folder.RegisterTask($plan.name,$xml,$(if($before){4}else{2}),$plan.sid,$null,3,$null)
  $registered=$true
  Assert-GreenloopAutostartXml $task.Xml $ReaderRoot $PowerShell $plan.sid
  return $task
 }catch{
  if($registered){[void](Get-GreenloopAutostartTask $ReaderRoot $PowerShell);if($before){[void]$plan.folder.RegisterTask($plan.name,$before,4,$plan.sid,$null,3,$null)}else{$plan.folder.DeleteTask($plan.name,0)}}
  throw
 }
}
