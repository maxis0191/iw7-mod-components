# The distributed client is tested without private components or diagnostic flags.
function Get-IW7CapacityStandardArguments($Plan,[string]$Password) {
    if($Password -cnotmatch '^[a-f0-9]{32}$' -or $Plan.GraphicsProfile -cnotin @('Full','Reduced')){throw 'Explicit standard client graphics profile and private password required.'}
    $picmip=if($Plan.GraphicsProfile -ceq 'Full'){0}else{2}
    if($Plan.RunPlan.Picmip -ne $picmip){throw 'Standard client quality differs from its reserved plan.'}
    "-noupdate -nosteam -cpMode -stdout -wincon -paris-capacity-64 -paris-capacity-production -paris-capacity-client-probe +set net_ip 127.0.0.1 +set net_port $($Plan.ClientPort) +set paris_capacity_peer_port $($Plan.ServerPort) +set password $Password +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 +set r_vsync 1 +set com_maxfps 30 +set r_picmip $picmip +set r_picmip_bump $picmip +set r_picmip_spec $picmip"
}
function Start-IW7CapacityStandardClient($Plan,$ServerIdentity,[string]$LeaseToken,[string]$Password,[string]$OutputRoot) {
    Assert-IW7BaseVacant $Plan.GameRoot
    Assert-IW7BaseIdentity $ServerIdentity
    if($Password -cnotmatch '^[a-f0-9]{32}$' -or (Get-FileHash $Plan.Image).Hash -cne $Plan.SHA256){throw 'Pinned standard client and generated private password required.'}
    $lease=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $LeaseToken)
    if($lease.Count -ne 1){throw 'Unique complete runtime reservation required.'}
    Assert-IW7BaseLease $lease[0] $Plan $ServerIdentity
    $info=& "$ops/Get-ServerInfo.ps1" -Port $Plan.ServerPort
    if($info.clients -cne '0' -or $info.paris_capacity -cne '64-v2' -or $info.isPrivate -cne '1'){throw 'Vacant private expanded server required.'}
    if(Test-Path $OutputRoot){throw 'Fresh client evidence required.'}
    [IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
    $context=New-IW7BaseClientContext $Plan $ServerIdentity $LeaseToken $OutputRoot (Read-IW7BaseLog $ServerIdentity.Stdout).Length
    try {
        $context.Transaction=Save-IW7BaseTransaction $Plan (Join-Path $OutputRoot 'backup')
        $arguments=Get-IW7CapacityStandardArguments $Plan $Password
        $context.Handle=[IW7LabProcess]::StartOwned($Plan.Image,$arguments,$Plan.GameRoot,"$OutputRoot/client.stdout.log","$OutputRoot/client.stderr.log",$context.DesktopName,$true,$false,$false,$Plan.ServerPort)
        $context.Client=$context.Handle;$id=$context.Handle.ReadIdentity()
        $context.Identity=[pscustomobject]@{PID=$id.PID;Image=$id.Image;CreatedUtc=[datetime]::FromFileTimeUtc($id.CreationFileTime).ToString('o');SHA256=$Plan.SHA256;Stdout="$OutputRoot/client.stdout.log";Stderr="$OutputRoot/client.stderr.log";DesktopName=$context.DesktopName}
        $context.Identity|ConvertTo-Json|Set-Content "$OutputRoot/client.identity.local.json"
        Add-IW7ResourceProcess -Token $LeaseToken -ProcessId $id.PID
        $deadline=[datetime]::UtcNow.AddSeconds(60)
        while(!(Read-IW7BaseLog "$OutputRoot/client.stdout.log").Contains('[Paris capacity candidate] installed agents=64 ordinary=48 special_headroom=16 characters=82 map_start=98')){
            Assert-IW7BaseIdentity $context.Identity $context.Handle
            if($context.Handle.HasExited -or [datetime]::UtcNow -ge $deadline){throw 'Standard client startup readiness absent.'}
            Start-Sleep -Milliseconds 250
        }
        # The same distributed executable waits for CP and online-data readiness
        # before its explicitly armed, private-loopback-only probe join.
        $context
    }catch{ $_.Exception.Data['BaseClientContext']=$context;throw }
}
