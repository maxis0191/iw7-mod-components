# Generalized from Doom-Test's protected, restored base-client witness.
# The server owner reserves the complete scenario; this API never deploys or stops a server.
function Resolve-IW7BasePath([string]$Root, [string]$Relative) {
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (!$Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Relative base-client path required.' }
    $target=[IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    if (!$target.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes base installation.' }
    $cursor=$target
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Redirected base-client path refused.' }
        $cursor=Split-Path $cursor -Parent
    }
    $target
}

function New-IW7BaseClientPlan {
    param([Parameter(Mandatory)][string]$GameRoot,[Parameter(Mandatory)][string]$ClientImage,
        [ValidateRange(27100,27999)][int]$ServerPort,[ValidateRange(27100,27999)][int]$ClientPort,
        [ValidateSet('Full','Reduced')][string]$GraphicsProfile='Full',[switch]$Debugger)
    $root=(Resolve-Path -LiteralPath $GameRoot).Path.TrimEnd('\','/')
    $image=[IO.Path]::GetFullPath($ClientImage)
    if (!$image.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($image) -ne '.exe') { throw 'Client executable must already exist inside the base installation.' }
    $image=Resolve-IW7BasePath $root $image.Substring($root.Length+1)
    if (!(Test-Path -LiteralPath $image -PathType Leaf) -or $ClientPort -eq $ServerPort) { throw 'Existing client executable and distinct test ports required.' }
    . "$PSScriptRoot/Lab-RunPlan.ps1"
    $budget=Get-IW7LabRunPlan -PlannedClients 1 -GraphicsProfile $GraphicsProfile -Debugger:$Debugger
    [pscustomobject]@{Schema='iw7.base-client/1';GameRoot=$root;Image=$image;SHA256=(Get-FileHash -LiteralPath $image).Hash;
        ServerPort=$ServerPort;ClientPort=$ClientPort;GraphicsProfile=$GraphicsProfile;RunPlan=$budget;
        MutableFiles=@('iw7-mod/agent-base-client.cfg','iw7-mod/paris-server-client.request','iw7-mod/paris-server-client.response','iw7-mod/screenshots/server-modules-fixture.bmp',
            'iw7-mod/paris-agent.session','iw7-mod/paris-agent.request','iw7-mod/paris-agent.response','iw7-mod/paris-agent.safety','iw7-mod/paris-isolated-lab.marker');
        ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/players2','iw7-mod/lab-appdata')}
}

function Assert-IW7BaseIdentity($Record) {
    if (!$Record -or !$Record.PID -or !$Record.Image -or !$Record.CreatedUtc -or $Record.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Complete exact process identity required.' }
    $process=Get-Process -Id $Record.PID -ErrorAction Stop
    try {
        if (![string]::Equals($process.MainModule.FileName,$Record.Image,[StringComparison]::OrdinalIgnoreCase) -or
            [math]::Abs(($process.StartTime.ToUniversalTime()-([datetimeoffset]$Record.CreatedUtc).UtcDateTime).TotalMilliseconds) -gt 1 -or
            (Get-FileHash -LiteralPath $Record.Image).Hash -ne $Record.SHA256) { throw 'Process identity changed; preserve it.' }
    } finally { $process.Dispose() }
}

function Assert-IW7BaseVacant([string]$GameRoot,[int]$OwnedPid=0) {
    # Preserve an occupied owner client, including one launched from another install.
    foreach ($p in @(Get-CimInstance Win32_Process | Where-Object Name -Match '^iw7.*\.exe$')) {
        if ($p.ProcessId -eq $OwnedPid) { continue }
        if (!$p.CommandLine -or $p.CommandLine -notmatch '(?:^|\s)-dedicated(?:\s|$)') { throw 'An unowned game client exists; preserve it.' }
    }
}

function Get-IW7BaseFiles([string]$Root,[string]$RelativeDirectory) {
    $directory=Resolve-IW7BasePath $Root $RelativeDirectory
    if (!(Test-Path -LiteralPath $directory)) { return @() }
    # Enumerate only after rejecting redirects, including redirects below a profile.
    foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Recurse -Force)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected profile refused.' }
        if (!$entry.PSIsContainer) { $entry.FullName.Substring($Root.Length+1).Replace('\','/') }
    }
}

function Save-IW7BaseTransaction {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$BackupRoot)
    $backup=[IO.Path]::GetFullPath($BackupRoot)
    if (Test-Path -LiteralPath $backup) { throw 'A fresh backup directory is required.' }
    if ($backup.StartsWith($Plan.GameRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup must be outside the installation.' }
    $null=Resolve-IW7BasePath (Split-Path $backup) (Split-Path $backup -Leaf)
    $directories=@($Plan.ProfileDirectory)
    if ($Plan.PSObject.Properties.Name -contains 'ProfileDirectories') { $directories=@($Plan.ProfileDirectories) }
    $profiles=@();$directoryBefore=@()
    foreach ($relativeDirectory in $directories) {
        $profiles+=@(Get-IW7BaseFiles $Plan.GameRoot $relativeDirectory)
        $path=Resolve-IW7BasePath $Plan.GameRoot $relativeDirectory
        if (Test-Path -LiteralPath $path) {
            $directoryBefore+=$relativeDirectory
            $directoryBefore+=@(Get-ChildItem -LiteralPath $path -Directory -Recurse -Force | ForEach-Object {$_.FullName.Substring($Plan.GameRoot.Length+1).Replace('\','/')})
        }
    }
    $relativeFiles=@(@($Plan.MutableFiles)+$profiles | Select-Object -Unique)
    $entries=@()
    foreach ($relative in $relativeFiles) {
        $path=Resolve-IW7BasePath $Plan.GameRoot $relative
        if ($relative -notin $Plan.MutableFiles -and @($directories | Where-Object {$relative.StartsWith($_+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0) { throw 'Unplanned mutable file.' }
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $entries+=[pscustomobject]@{Path=$relative;Existed=$exists;SHA256=$(if ($exists) {(Get-FileHash -LiteralPath $path).Hash} else {$null})}
    }
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    foreach ($entry in $entries | Where-Object Existed) {
        $dest=Resolve-IW7BasePath $backup $entry.Path
        [IO.Directory]::CreateDirectory((Split-Path $dest)) | Out-Null
        Copy-Item -LiteralPath (Resolve-IW7BasePath $Plan.GameRoot $entry.Path) -Destination $dest
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $entry.SHA256) { throw 'Backup hash mismatch; no launch permitted.' }
    }
    $protected=@()
    $mainPaths=@(Get-ChildItem -LiteralPath $Plan.GameRoot -File -Filter '*.exe' -Force | ForEach-Object Name)
    $configRoot=Resolve-IW7BasePath $Plan.GameRoot 'iw7-mod'
    if (Test-Path -LiteralPath $configRoot) { $mainPaths+=@(Get-ChildItem -LiteralPath $configRoot -File -Filter 'server*.cfg' -Force | ForEach-Object { 'iw7-mod/'+$_.Name }) }
    foreach ($directory in @('iw7-mod/custom_scripts/cp','mods/paris_beta/bank')) { $mainPaths+=@(Get-IW7BaseFiles $Plan.GameRoot $directory) }
    foreach ($relative in $mainPaths | Select-Object -Unique) {
        $path=Resolve-IW7BasePath $Plan.GameRoot $relative
        $protected+=[pscustomobject]@{Path=$relative;SHA256=(Get-FileHash -LiteralPath $path).Hash}
    }
    $transaction=[pscustomobject]@{Schema='iw7.base-transaction/1';GameRoot=$Plan.GameRoot;BackupRoot=$backup;ProfileDirectory=$Plan.ProfileDirectory;ProfileDirectories=$directories;DirectoryBefore=$directoryBefore;ProfileBefore=$profiles;Files=$entries;ProtectedFiles=$protected;Restored=$false}
    $transaction | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backup 'recovery.local.json') -Encoding utf8
    $transaction
}

function Restore-IW7BaseTransaction($Transaction) {
    $Transaction.Restored=$false
    # Preflight EVERY backup and target before restoring even the first byte.
    foreach ($entry in $Transaction.Files) {
        $target=Resolve-IW7BasePath $Transaction.GameRoot $entry.Path
        if (Test-Path -LiteralPath $target -PathType Container) { throw 'Restoration target became a directory; preserve it.' }
        if ($entry.Existed) {
            $source=Resolve-IW7BasePath $Transaction.BackupRoot $entry.Path
            if (!(Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -LiteralPath $source).Hash -ne $entry.SHA256) { throw 'Restoration backup is missing/corrupt; preserve current files.' }
        }
    }
    $newProfiles=@();$newDirectories=@()
    foreach ($directory in $Transaction.ProfileDirectories) {
        $newProfiles+=@(Get-IW7BaseFiles $Transaction.GameRoot $directory | Where-Object { $_ -notin $Transaction.ProfileBefore })
        $path=Resolve-IW7BasePath $Transaction.GameRoot $directory
        if (Test-Path -LiteralPath $path) {
            $allDirectories=@($directory)+@(Get-ChildItem -LiteralPath $path -Directory -Recurse -Force | ForEach-Object {$_.FullName.Substring($Transaction.GameRoot.Length+1).Replace('\','/')})
            $newDirectories+=@($allDirectories | Where-Object {$_ -notin $Transaction.DirectoryBefore})
        }
    }
    foreach ($relative in $newProfiles) { $null=Resolve-IW7BasePath $Transaction.GameRoot $relative }
    foreach ($entry in $Transaction.Files) {
        $target=Resolve-IW7BasePath $Transaction.GameRoot $entry.Path
        if ($entry.Existed) {
            [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
            Copy-Item -LiteralPath (Resolve-IW7BasePath $Transaction.BackupRoot $entry.Path) -Destination $target -Force
            if ((Get-FileHash -LiteralPath $target).Hash -ne $entry.SHA256) { throw 'Restored hash mismatch.' }
        } elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    }
    foreach ($relative in $newProfiles | Select-Object -Unique) {
        # Explicit mutable paths may also belong to a tracked profile tree.
        # Their absent-before entry was already removed in the restoration loop.
        $path=Resolve-IW7BasePath $Transaction.GameRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($relative in $newDirectories | Sort-Object Length -Descending) {
        $path=Resolve-IW7BasePath $Transaction.GameRoot $relative
        if (@(Get-ChildItem -LiteralPath $path -Force).Count) { throw 'Unexpected profile directory content; preserve it.' }
        Remove-Item -LiteralPath $path
    }
    foreach ($entry in $Transaction.ProtectedFiles) {
        $target=Resolve-IW7BasePath $Transaction.GameRoot $entry.Path
        if (!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash -ne $entry.SHA256) { throw 'Main executable/config/script/bank changed; preserve evidence and investigate.' }
    }
    $Transaction.Restored=$true
    $Transaction | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Transaction.BackupRoot 'recovery.local.json') -Encoding utf8
}

function Read-IW7BaseLog([string]$Path) {
    $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite');$reader=[IO.StreamReader]::new($stream)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Assert-IW7BaseLease($Lease,$Plan,$ServerIdentity) {
    if (!$Lease -or $Lease.Kind -ne 'Runtime' -or $Lease.BaseClientImage -ne $Plan.Image -or
        $Lease.PhysicalBytes -lt $Plan.RunPlan.PhysicalBytes -or $Lease.CommitBytes -lt $Plan.RunPlan.CommitBytes) { throw 'Complete server + declared base-client reservation required.' }
    $scope=[IO.Path]::GetFullPath($Lease.Scope).TrimEnd('\','/')
    if (!$ServerIdentity.Image.StartsWith($scope+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $ServerIdentity.Image.StartsWith($Plan.GameRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Separate test dedicated inside reserved scope required; Main refused.' }
    $records=@($Lease.Processes | Where-Object PID -EQ $ServerIdentity.PID)
    if ($records.Count -ne 1 -or $records[0].Image -ne $ServerIdentity.Image -or
        [math]::Abs((([datetimeoffset]$records[0].CreatedUtc)-([datetimeoffset]$ServerIdentity.CreatedUtc)).TotalMilliseconds) -gt 1) { throw 'Registered server identity mismatch.' }
}

function Get-IW7BaseClientArguments($Plan,[string]$Password) {
    if ($Password -notmatch '^[a-zA-Z0-9_-]{1,64}$') { throw 'Use a generated private test password.' }
    if ($Plan.RunPlan.Picmip -notin @(0,2) -or
        $Plan.ServerPort -lt 27100 -or $Plan.ServerPort -gt 27999 -or
        $Plan.ClientPort -lt 27100 -or $Plan.ClientPort -gt 27999 -or $Plan.ClientPort -eq $Plan.ServerPort) { throw 'Invalid reserved client launch profile.' }
    # Match the verified Isolated-Lab startup path. A client +exec in iw7-mod
    # is not a reliable startup dvar source: retail profile loading can leave
    # password/graphics at owner defaults. Apply them as startup +set values.
    # Retail r_mode selects fullscreen resolution. Windowed dimensions come
    # from vid_width/vid_height; the retained owner profile can otherwise leave
    # a 1879x1057 backbuffer despite r_mode=1280x720. Disable monitor-sized window.
    # This string contains the private password; never write it to evidence.
    $picmip=$Plan.RunPlan.Picmip
    $arguments="-noupdate -nosteam -cpMode -stdout -paris-server-client-test -paris-isolated-lab +set net_ip 127.0.0.1 +set net_port $($Plan.ClientPort) +set paris_lab_server_port $($Plan.ServerPort) +set password `"$Password`" +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 +set r_vsync 1 +set com_maxfps 30 +set r_picmip $picmip +set r_picmip_bump $picmip +set r_picmip_spec $picmip"
    if ($Plan.RunPlan.Debugger) { $arguments+=' -paris-debugger' }
    $arguments
}

function Start-IW7BaseClient {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$ServerIdentity,[Parameter(Mandatory)][string]$LeaseToken,
        [Parameter(Mandatory)][string]$Password,[Parameter(Mandatory)][string]$OutputRoot)
    if ($Password -notmatch '^[a-zA-Z0-9_-]{1,64}$') { throw 'Use a generated private test password.' }
    . "$PSScriptRoot/Resource-Scheduler.Core.ps1"
    . "$PSScriptRoot/Lab-Lifecycle.ps1"
    Assert-IW7BaseIdentity $ServerIdentity
    Assert-IW7BaseVacant $Plan.GameRoot
    if ((Get-FileHash -LiteralPath $Plan.Image).Hash -ne $Plan.SHA256) { throw 'Client bytes changed since plan.' }
    $status=Get-IW7ResourceStatus
    $leases=@($status.Leases | Where-Object { $_.Token -eq $LeaseToken -and $_.Kind -eq 'Runtime' })
    if ($leases.Count -ne 1) { throw 'Unique complete reservation required.' }
    Assert-IW7BaseLease $leases[0] $Plan $ServerIdentity
    $serverProcess=Get-CimInstance Win32_Process -Filter "ProcessId=$($ServerIdentity.PID)"
    if (!$serverProcess.CommandLine -or $serverProcess.CommandLine -notmatch '(?:^|\s)-dedicated(?:\s|$)' -or
        $serverProcess.CommandLine -notmatch '(?:^|\s)-paris-server-test(?:\s|$)' -or
        $serverProcess.CommandLine -notmatch '(?:^|\s)-paris-isolated-lab(?:\s|$)' -or
        $serverProcess.CommandLine -notmatch ('\+set\s+net_port\s+'+$Plan.ServerPort+'(?:\s|$)')) { throw 'Explicit protected test dedicated on the expected test port required.' }
    $info=& "$PSScriptRoot/Get-ServerInfo.ps1" -Port $Plan.ServerPort
    if ($info.clients -ne '0' -or $info.isPrivate -ne '1' -or $info.sv_running -ne '1') { throw 'Expected empty private test dedicated.' }
    if (Get-NetUDPEndpoint -LocalPort $Plan.ClientPort -ErrorAction SilentlyContinue) { throw 'Client port occupied.' }
    $output=[IO.Path]::GetFullPath($OutputRoot)
    if (Test-Path -LiteralPath $output) { throw 'Fresh output directory required.' }
    if ($output.StartsWith($Plan.GameRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence/backup must stay outside the game installation.' }
    $null=Resolve-IW7BasePath (Split-Path $output) (Split-Path $output -Leaf)
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $context=[pscustomobject]@{Plan=$Plan;Server=$ServerIdentity;LeaseToken=$LeaseToken;OutputRoot=$output;Transaction=$null;Handle=$null;Client=$null;Identity=$null;
        LogLength=(Read-IW7BaseLog $ServerIdentity.Stdout).Length;PendingLog='';LastHeartbeatUtc=$null;LastHeartbeatTick=0L;StartedTick=[Environment]::TickCount64;StartedUtc=[datetime]::UtcNow;Protected=$false;Failed=$false;Lock=$null;
        DesktopName=('IW7ParisLab_'+[guid]::NewGuid().ToString('N'))}
    $lockRoot=Join-Path $env:LOCALAPPDATA 'IW7Paris/BaseClient'
    [IO.Directory]::CreateDirectory($lockRoot) | Out-Null
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Plan.GameRoot.ToLowerInvariant())))
    $context.Lock=[IO.File]::Open((Join-Path $lockRoot ($key+'.lock')),'OpenOrCreate','ReadWrite','None')
    try {
        Assert-IW7BaseVacant $Plan.GameRoot
        $context.Transaction=Save-IW7BaseTransaction $Plan (Join-Path $output 'backup')
        [IO.File]::WriteAllText((Resolve-IW7BasePath $Plan.GameRoot 'iw7-mod/paris-isolated-lab.marker'),'iw7-paris-isolated-lab-v1',[Text.UTF8Encoding]::new($false))
        # Legacy requests validate PID but have no startup nonce. A reused OS PID
        # must never consume a restored previous-session stop/vote during boot.
        foreach ($mailbox in @('paris-server-client.request','paris-server-client.response')) {
            $path=Resolve-IW7BasePath $Plan.GameRoot ('iw7-mod/'+$mailbox)
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        $picmip=$Plan.RunPlan.Picmip
        $cfg="set password `"$Password`"`nset r_fullscreen 0`nset r_fullscreenWindow 0`nset vid_width 1280`nset vid_height 720`nset r_mode 1280x720`nset com_maxfps 30`nset r_vsync 1`nset r_picmip $picmip`nset r_picmip_bump $picmip`nset r_picmip_spec $picmip`n"
        [IO.File]::WriteAllText((Resolve-IW7BasePath $Plan.GameRoot 'iw7-mod/agent-base-client.cfg'),$cfg,[Text.UTF8Encoding]::new($false))
        if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$PSScriptRoot/native/LabProcess.cs" }
        $args=Get-IW7BaseClientArguments $Plan $Password
        [ordered]@{Image=$Plan.Image;SHA256=$Plan.SHA256;DesktopName=$context.DesktopName;PlannedUtc=[datetime]::UtcNow.ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'client.launch.local.json')
        $context.Handle=[IW7LabProcess]::StartOwned($Plan.Image,$args,$Plan.GameRoot,(Join-Path $output 'client.stdout.log'),(Join-Path $output 'client.stderr.log'),$context.DesktopName)
        $context.Client=$context.Handle
        $process=Get-Process -Id $context.Handle.Id
        try { $context.Identity=[pscustomobject]@{PID=$context.Handle.Id;Image=$Plan.Image;CreatedUtc=$process.StartTime.ToUniversalTime().ToString('o');SHA256=$Plan.SHA256;Stdout=(Join-Path $output 'client.stdout.log');Stderr=(Join-Path $output 'client.stderr.log');DesktopName=$context.DesktopName} } finally { $process.Dispose() }
        $context.Identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'client.identity.local.json')
        Add-IW7ResourceProcess -Token $LeaseToken -ProcessId $context.Handle.Id
        $null=Send-IW7BaseRequest $context 'connect' -AllowUnprotected
        $context
    } catch {
        $failure=$_
        # Never lose the retained handle on launch/registration failure.
        try { Stop-IW7BaseClient $context } catch { Write-Warning "Base client cleanup pending at $output : $_" }
        $failure.Exception.Data['BaseClientContext']=$context
        throw $failure
    }
}

function Update-IW7BaseProtection($Context,[string]$FreshLog,[long]$NowTick=[Environment]::TickCount64,[int]$ProtectionTimeoutSeconds=180) {
    $text=$Context.PendingLog+$FreshLog
    $lastNewline=$text.LastIndexOf("`n")
    if ($lastNewline -ge 0) { $complete=$text.Substring(0,$lastNewline+1);$Context.PendingLog=$text.Substring($lastNewline+1) }
    else { $complete='';$Context.PendingLog=$text }
    if ($Context.PendingLog.Length -gt 65536) { throw 'Unterminated server log exceeds evidence bound.' }
    if ($complete -match '\[Paris test protection failure\]|protected=0;|FAIL protection_lost') { throw 'Engine protection failed.' }
    foreach ($match in [regex]::Matches($complete,'tick_ms=(\d+); protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=0')) {
        $tick=[long]$match.Groups[1].Value
        if ($tick -ge $Context.StartedTick -and $tick -le $NowTick -and $NowTick-$tick -le 10000) {
            $Context.LastHeartbeatTick=[math]::Max($Context.LastHeartbeatTick,$tick);$Context.LastHeartbeatUtc=[datetime]::UtcNow;$Context.Protected=$true
        }
    }
    if (($Context.Protected -and $NowTick-$Context.LastHeartbeatTick -gt 10000) -or
        (!$Context.Protected -and $NowTick-$Context.StartedTick -gt $ProtectionTimeoutSeconds*1000L)) { throw 'Fresh continuous engine protection unavailable.' }
}

function Update-IW7BaseClient($Context,[ValidateRange(1,180)][int]$ProtectionTimeoutSeconds=180) {
    if ($Context.Failed) { throw 'Session previously failed; no more gameplay actions.' }
    try {
        if ($Context.Handle.HasExited) { throw 'Owned client exited.' }
        Assert-IW7BaseIdentity $Context.Identity; Assert-IW7BaseIdentity $Context.Server
        $log=Read-IW7BaseLog $Context.Server.Stdout
        if ($log.Length -lt $Context.LogLength) { throw 'Server log reset; protection evidence is ambiguous.' }
        $fresh=$log.Substring($Context.LogLength);$Context.LogLength=$log.Length
        Update-IW7BaseProtection $Context $fresh -ProtectionTimeoutSeconds $ProtectionTimeoutSeconds
        $info=& "$PSScriptRoot/Get-ServerInfo.ps1" -Port $Context.Plan.ServerPort
        if ($info.clients -notin @('0','1') -or ($Context.Protected -and $info.clients -ne '1') -or $info.isPrivate -ne '1' -or $info.sv_running -ne '1') { throw 'Private single-owned-client session changed; preserve other participants.' }
        . "$PSScriptRoot/Resource-Scheduler.Core.ps1"
        $budget=Test-IW7ResourceBudget (Get-IW7ResourceSnapshot) 0 0
        if ($budget.HighWater) { throw 'Runtime exceeds shared resource thresholds.' }
        [pscustomobject]@{Protected=$Context.Protected;LastHeartbeatUtc=$Context.LastHeartbeatUtc;PhysicalUsedPercent=$budget.PhysicalUsedPercent;CommitUsedPercent=$budget.CommitUsedPercent}
    } catch { $Context.Failed=$true;throw }
}

function Send-IW7BaseRequest($Context,[string]$Action,[switch]$AllowUnprotected) {
    # Transport is extensible; native code remains the final action allowlist.
    if ($Action -notmatch '^[a-z][a-z0-9_]{0,63}$') { throw 'Typed mailbox action required; arbitrary commands refused.' }
    if ($AllowUnprotected -and $Action -notin @('connect','stop')) { throw 'Only lifecycle actions may bypass the protection precondition.' }
    if (!$AllowUnprotected) { $sample=Update-IW7BaseClient $Context; if (!$sample.Protected) { throw 'Wait for fresh protection before gameplay action.' } }
    if (!$Context.Handle -or $Context.Handle.HasExited) { throw 'Client is not active.' }
    Assert-IW7BaseIdentity $Context.Identity
    $request="$($Context.Identity.PID) $([guid]::NewGuid().ToString('N')) $Action"
    [IO.File]::WriteAllText((Resolve-IW7BasePath $Context.Plan.GameRoot 'iw7-mod/paris-server-client.request'),$request,[Text.Encoding]::ASCII)
    # Acknowledgement proves dispatch only; the scenario checks its own outcome.
    $request
}

function Stop-IW7BaseClient($Context) {
    . "$PSScriptRoot/Lab-Lifecycle.ps1"
    if ($Context.Handle -and !$Context.Handle.HasExited) {
        Assert-IW7BaseIdentity $Context.Identity
        Assert-IW7BaseVacant $Context.Plan.GameRoot $Context.Identity.PID
        # Native abort is safe even after protection loss. Use its session identity,
        # advancing the acknowledged sequence so held player keys are released.
        $sessionPath=Resolve-IW7BasePath $Context.Plan.GameRoot 'iw7-mod/paris-agent.session'
        if (Test-Path -LiteralPath $sessionPath) {
            $session=[IO.File]::ReadAllText($sessionPath).Trim()
            if ($session -match ('^'+$Context.Identity.PID+' ([a-f0-9]{32})$')) {
                $nonce=$Matches[1];$seq=0L;$step=0L
                foreach ($mailbox in @('paris-agent.request','paris-agent.response')) {
                    $path=Resolve-IW7BasePath $Context.Plan.GameRoot ('iw7-mod/'+$mailbox)
                    if (Test-Path -LiteralPath $path) {
                        $text=[IO.File]::ReadAllText($path)
                        if ($text -match ('^'+$Context.Identity.PID+' '+$nonce+' (\d+) (\d+) ')) { $seq=[math]::Max($seq,[long]$Matches[1]);$step=[math]::Max($step,[long]$Matches[2]) }
                    }
                }
                if ($seq -lt [long]::MaxValue -and $step -lt [long]::MaxValue) {
                    [IO.File]::WriteAllText((Resolve-IW7BasePath $Context.Plan.GameRoot 'iw7-mod/paris-agent.request'),"$($Context.Identity.PID) $nonce $($seq+1) $($step+1) abort none 0",[Text.Encoding]::ASCII)
                }
            }
        }
        $null=Invoke-IW7OwnedStop -Handle $Context.Handle -TimeoutMs 10000 -StopAction { $null=Send-IW7BaseRequest $Context 'stop' -AllowUnprotected }
    }
    if ($Context.Handle -and !$Context.Handle.HasExited) { throw 'Client closure unconfirmed; retain transaction and reservation.' }
    Assert-IW7BaseVacant $Context.Plan.GameRoot
    if ($Context.Transaction) { Restore-IW7BaseTransaction $Context.Transaction }
    if ($Context.Handle) { $Context.Handle.Dispose();$Context.Handle=$null;$Context.Client=$null }
    if ($Context.Lock) { $Context.Lock.Dispose();$Context.Lock=$null }
    # Server owner releases the complete reservation only after its own teardown.
}
