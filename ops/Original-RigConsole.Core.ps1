# Scoped transport for eight fixed commands. Engine output is a separate witness.
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
function Read-IW7OriginalRigConsoleWire([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if($stream.Length -le 0 -or $stream.Length -gt 512){throw 'Current bounded native rig wire required.'}
        $bytes=[byte[]]::new(513);$count=0
        do{$next=$stream.Read($bytes,$count,$bytes.Length-$count);$count+=$next}while($next -gt 0 -and $count -lt $bytes.Length)
        if($count -gt 512){throw 'Native rig wire grew beyond its bound.'}
        [Text.Encoding]::ASCII.GetString($bytes,0,$count)
    }finally{$stream.Dispose()}
}

function Send-IW7OriginalRigConsoleCommand {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$TargetHandle,
        [Parameter(Mandatory)]$TargetIdentity,[Parameter(Mandatory)][string]$Command)
    $ErrorActionPreference='Stop'
    if(!('IW7LabProcess' -as [type]) -or ![IW7LabProcess]::IsOriginalRigCommand($Command)){
        throw 'Only the eight fixed original-rig commands are accepted.'
    }
    if(!(Get-IW7BaseOriginalRigConsole $Session.Plan) -or !$TargetHandle.OriginalRigConsoleEnabled -or
        !$Session.Transaction -or $Session.Failed -or $Session.Plan.ServerPort -lt 27100 -or $Session.Plan.ServerPort -gt 27999){
        throw 'Explicit owned original-rig console session required.'
    }
    if($TargetIdentity.PID -notin @($Session.Identity.PID,$Session.Server.PID) -or $TargetHandle.Id -ne $TargetIdentity.PID){
        throw 'Console target must be this session client or dedicated original handle.'
    }
    if($Command.StartsWith('set ',[StringComparison]::Ordinal) -and $TargetIdentity.PID -ne $Session.Server.PID){
        throw 'Original-rig play/stop controls require the dedicated original handle.'
    }
    if($Session.LeaseToken -cnotmatch '\A[a-f0-9]{32}\z'){throw 'Current runtime reservation token required.'}
    $status=Get-IW7ResourceStatus
    $leases=@($status.Leases|Where-Object {$_.Token -ceq $Session.LeaseToken})
    if($leases.Count -ne 1 -or $leases[0].Kind -cne 'Runtime' -or $leases[0].Phase -cne 'Running'){
        throw 'Unique current running runtime reservation required.'
    }
    Assert-IW7BaseLease $leases[0] $Session.Plan $Session.Server
    $sample=Update-IW7BaseClient $Session
    if(!$sample.Protected -or !$Session.Protected -or $Session.Failed){throw 'Current protected original-rig client required.'}
    Assert-IW7BaseIdentity $TargetIdentity $TargetHandle
    $nativeIdentity=Read-IW7OriginalRigConsoleWire (Resolve-IW7BasePath $Session.Plan.GameRoot 'iw7-mod/paris-agent.session')
    if($nativeIdentity -cnotmatch '\A([0-9]+) ([a-f0-9]{32})\r?\n\z' -or [long]$Matches[1] -ne $Session.Identity.PID){
        throw 'Current native client identity publication differs.'
    }
    $nonce=$Matches[2]
    if($Session.PSObject.Properties.Name -contains 'OriginalRigConsoleNonce' -and $Session.OriginalRigConsoleNonce -cne $nonce){
        throw 'Native client nonce changed during the rig console session.'
    }
    $safety=Read-IW7OriginalRigConsoleWire (Resolve-IW7BasePath $Session.Plan.GameRoot 'iw7-mod/paris-agent.safety')
    if($safety -cnotmatch ('\A'+$Session.Identity.PID+' '+$nonce+' 1 ([0-9]+) cp_zmb\r?\n\z')){
        throw 'Current bound native client safety publication absent.'
    }
    $safetyTick=[long]$Matches[1]
    $log=Read-IW7BaseLog $Session.Server.Stdout
    $beats=[regex]::Matches($log,'tick_ms=(\d+); protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=0')
    if(!$beats.Count -or $log -match '\[Paris test protection failure\]|FAIL protection_lost'){
        throw 'Actual engine godmode/inactivity/cheats protection evidence absent.'
    }
    $heartbeatTick=[long]$beats[$beats.Count-1].Groups[1].Value
    $now=[Environment]::TickCount64
    foreach($tick in @($safetyTick,$heartbeatTick)){
        if($tick -lt $Session.StartedTick -or $tick -gt $now -or $now-$tick -gt 250){throw 'Protected native rig console evidence expired.'}
    }
    $identity=$TargetHandle.ReadIdentity()
    if($identity.PID -ne $TargetIdentity.PID -or $identity.Image -ine $TargetIdentity.Image -or
        [math]::Abs($identity.CreationFileTime-([datetimeoffset]$TargetIdentity.CreatedUtc).UtcDateTime.ToFileTimeUtc()) -gt 10){
        throw 'Original kernel console identity differs from the retained record.'
    }
    $Session|Add-Member -NotePropertyName OriginalRigConsoleNonce -NotePropertyValue $nonce -Force
    $bytes=$TargetHandle.WriteOriginalRigCommand($Command,$identity.Image,$identity.CreationFileTime,$nonce,$safetyTick)
    [pscustomobject]@{Schema='iw7.original-rig-console-write/1';PID=$identity.PID;Nonce=$nonce;Command=$Command;
        SafetyPublicationTick=$safetyTick;HeartbeatTick=$heartbeatTick;BytesWritten=$bytes;Transport='owned-stdin-pipe-wincon';NativeAckWindowMs=500;
        EngineConsumptionVerified=$false;AssetLookupVerified=$false;GameplayVerified=$false}
}
