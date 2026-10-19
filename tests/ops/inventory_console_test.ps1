# Real stdin consumption; no game or gameplay result is inferred.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -Path "$repo/ops/native/LabProcess.cs"
$root="$repo/runtime/inventory-console-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($root)|Out-Null
[IO.File]::WriteAllText("$root/read.ps1",'for($i=0;$i -lt 2;$i++){[Console]::WriteLine("READ:"+[Console]::ReadLine())}')
$shell=(Get-Process -Id $PID).Path
$nonce='0123456789abcdef0123456789abcdef';$count=0
function Refuses([scriptblock]$Action){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};if(!$refused){throw 'Unsafe inventory write accepted.'};$script:count++}
foreach($dedicated in @($false,$true)){
 $role=if($dedicated){'-dedicated -paris-server-test'}else{'-paris-server-client-test'}
 $args='-NoProfile -NonInteractive -File "'+$root+'/read.ps1" -wincon -paris-isolated-lab '+$role
 $owned=$null
 try{
  $owned=[IW7LabProcess]::StartOwned($shell,$args,$root,"$root/$dedicated.out","$root/$dedicated.err",('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false,$true)
  $id=$owned.ReadIdentity()
  $command=if($dedicated){'map cp_zmb'}else{'tphere #2'}
  foreach($bad in @('quit','tp #3','tp #2;quit',"tp #2`nquit",'map cp_final1')){Refuses {$owned.WriteInventoryAuditCommand($bad,$id.Image,$id.CreationFileTime,$nonce,[Environment]::TickCount64)}}
  $wrongRole=if($dedicated){'tp #2'}else{'map cp_zmb'}
  Refuses {$owned.WriteInventoryAuditCommand($wrongRole,$id.Image,$id.CreationFileTime,$nonce,[Environment]::TickCount64)}
  Refuses {$owned.WriteInventoryAuditCommand($command,$id.Image,($id.CreationFileTime+1),$nonce,[Environment]::TickCount64)}
  Refuses {$owned.WriteInventoryAuditCommand($command,$id.Image,$id.CreationFileTime,$nonce,([Environment]::TickCount64-251))}
  $null=$owned.WriteInventoryAuditCommand($command,$id.Image,$id.CreationFileTime,$nonce,[Environment]::TickCount64)
  Refuses {$owned.WriteInventoryAuditCommand($command,$id.Image,$id.CreationFileTime,('f'*32),[Environment]::TickCount64)}
  $second=if($dedicated){'map cp_final'}else{'tp #2'}
  $null=$owned.WriteInventoryAuditCommand($second,$id.Image,$id.CreationFileTime,$nonce,[Environment]::TickCount64)
  if(!$owned.WaitForExit(10000) -or $owned.ExitCode -ne 0){throw 'Owned pipe reader failed.'}
  $lines=Get-Content "$root/$dedicated.out"
  if($lines.Count -ne 2 -or $lines[0] -cne "READ:$command" -or $lines[1] -cne "READ:$second"){throw 'Exact stdin consumption differs.'}
  $count+=2
 }finally{if($owned){if(!$owned.HasExited){$owned.Terminate(66);$null=$owned.WaitForExit(5000)};$owned.Dispose()}}
}
"PASS $count bounded inventory stdin checks; no gameplay claimed."

