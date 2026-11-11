# Shared by setup and startup repair. Only two fixed loopback reader ports.
function Get-GreenloopTextHash([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-GreenloopLocalHealth([int]$Port,[int]$TimeoutMs=1500){
 if($Port -notin @(51892,51893)){throw 'Unsupported Cable Reader port.'}
 $response=$null;$stream=$null
 try{
  $request=[Net.HttpWebRequest]::Create(('http://127.0.0.1:'+ $Port +'/health'))
  $request.Proxy=$null;$request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutMs;$request.ReadWriteTimeout=$TimeoutMs
  $response=$request.GetResponse();$stream=[IO.StreamReader]::new($response.GetResponseStream());$text=$stream.ReadToEnd()
  if($text.Length -gt 8192){return $null}
  $h=$text|ConvertFrom-Json
  if($h.ok -ceq $true -and $h.service -ceq 'Greenloop Read-Only Device Reader' -and $h.mode -ceq 'read-only' -and $h.version -cin @('20261001-android-reader-1','20261001-android-reader-2') -and $h.dualImeiVersion -ceq '20261023-dual-imei-1'){return $h}
 }catch{return $null}finally{if($stream){$stream.Dispose()};if($response){$response.Dispose()}}
 return $null
}
function Test-GreenloopPortFree([int]$Port){
 $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
 try{$probe.Server.ExclusiveAddressUse=$true;$probe.Start();return $true}catch [Net.Sockets.SocketException]{return $false}finally{$probe.Stop()}
}
function Select-GreenloopReaderPort {
 foreach($candidate in @(51892,51893)){if(Get-GreenloopLocalHealth $candidate){return $candidate}}
 foreach($candidate in @(51892,51893)){if(Test-GreenloopPortFree $candidate){return $candidate}}
 throw 'Both supported reader ports are busy or unavailable. No unrelated process or Windows network setting was changed.'
}
function ConvertTo-GreenloopStartupPlan([hashtable]$Sources,[int]$Port){
 if($Port -notin @(51892,51893)){throw 'Unsupported Cable Reader port.'}
 $result=@{};$reader=$Sources['Greenloop-Device-Reader.ps1'];$oldHash=Get-GreenloopTextHash $reader
 foreach($name in @('Greenloop-Device-Reader.ps1','Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
  $errors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseInput($Sources[$name],[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ('Reader source syntax differs: '+$name+'. Original files preserved.')}
 }
 $pattern='(?m)^([ \t]*\[int\]\$Port[ \t]*=[ \t]*)(51892|51893)([ \t]*,?[ \t]*\r?)$'
 if(([regex]::Matches($reader,$pattern)).Count -ne 1 -or -not $reader.Contains("service = 'Greenloop Read-Only Device Reader'") -or -not $reader.Contains("dualImeiVersion = '20261023-dual-imei-1'")){throw 'Installed reader identity/default port was not recognized. Original files preserved.'}
 $result['Greenloop-Device-Reader.ps1']=[regex]::Replace($reader,$pattern,{param($m)$m.Groups[1].Value+[string]$Port+$m.Groups[3].Value})
 $newHash=Get-GreenloopTextHash $result['Greenloop-Device-Reader.ps1']
 foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1')){
  $text=$Sources[$name];$hashPattern="(?m)^\`$expectedReaderHash\s*=\s*'([A-Fa-f0-9]{64})'"
  $found=[regex]::Matches($text,$hashPattern)
  if($found.Count -ne 1 -or $found[0].Groups[1].Value -ine $oldHash){throw ('Reader pin does not match installed source: '+$name+'. Original files preserved.')}
  $text=[regex]::Replace($text,$hashPattern,('$expectedReaderHash = '''+$newHash+''''))
  if($name -eq 'Watch-Greenloop-Reader.ps1'){
   $portPattern='(?m)^\$readerPort[ \t]*=[ \t]*(51892|51893)[ \t]*(?=\r?$)'
   if(([regex]::Matches($text,$portPattern)).Count -ne 1){throw 'Supervisor port declaration was not recognized.'}
   $text=[regex]::Replace($text,$portPattern,('$readerPort = '+$Port))
  }else{
   $portPattern='http://127\.0\.0\.1:5189[23]/health'
   if(([regex]::Matches($text,$portPattern)).Count -ne 1){throw 'Launcher health endpoint was not recognized.'}
   $text=[regex]::Replace($text,$portPattern,('http://127.0.0.1:'+$Port+'/health'))
  }
  $result[$name]=$text
 }
 foreach($text in $result.Values){$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Aligned reader source failed syntax checks.'}}
 return $result
}
function Test-GreenloopExactReaderCommand([string]$Command,[string]$Script){
 $p=[regex]::Escape($Script.Replace('/','\'))
 return $Command.Replace('/','\') -match ('(?i)(?:^|\s)-File\s+(?:"'+$p+'"|'+$p+')(?:\s|$)')
}
function Get-GreenloopOwnedProcesses([string]$Root,[string]$PowerShell){
 $scripts=@('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1','Greenloop-Device-Reader.ps1')
 foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)){
  if($p.ProcessId -eq $PID -or $p.ExecutablePath -ine $PowerShell){continue}
  foreach($name in $scripts){if(Test-GreenloopExactReaderCommand ([string]$p.CommandLine) (Join-Path $Root $name)){$p;break}}
 }
}
function Stop-GreenloopOwnedProcesses([string]$Root,[string]$PowerShell){
 # Stop launcher/supervisor before enumerating their reader children again.
 foreach($name in @('Start-Greenloop.ps1','Watch-Greenloop-Reader.ps1','Greenloop-Device-Reader.ps1')){
  $script=Join-Path $Root $name
  foreach($p in @(Get-GreenloopOwnedProcesses $Root $PowerShell)){
   if(-not(Test-GreenloopExactReaderCommand ([string]$p.CommandLine) $script)){continue}
   $fresh=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId) -ErrorAction Stop
   if($fresh -and $fresh.CreationDate -eq $p.CreationDate -and $fresh.ExecutablePath -ieq $PowerShell -and (Test-GreenloopExactReaderCommand ([string]$fresh.CommandLine) $script)){
    Stop-Process -Id $p.ProcessId -ErrorAction Stop
    Wait-Process -Id $p.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
   }
  }
 }
}
