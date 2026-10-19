# The distributed client is tested without private components or diagnostic flags.
function Start-IW7CapacityStandardClient($Plan,$ServerIdentity,[string]$LeaseToken,[string]$Password,[string]$OutputRoot) {
    Assert-IW7BaseVacant $Plan.GameRoot
    Assert-IW7BaseIdentity $ServerIdentity
    if($Password -cnotmatch '^[a-f0-9]{32}$' -or (Get-FileHash $Plan.Image).Hash -cne $Plan.SHA256){throw 'Pinned standard client and generated private password required.'}
    $lease=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $LeaseToken)
    if($lease.Count -ne 1){throw 'Unique complete runtime reservation required.'}
    Assert-IW7BaseLease $lease[0] $Plan $ServerIdentity
    $info=& "$ops/Get-ServerInfo.ps1" -Port $Plan.ServerPort
    if($info.clients -cne '0' -or $info.paris_capacity -cne '64-v1' -or $info.isPrivate -cne '1'){throw 'Vacant private expanded server required.'}
    if(Test-Path $OutputRoot){throw 'Fresh client evidence required.'}
    [IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
    $context=New-IW7BaseClientContext $Plan $ServerIdentity $LeaseToken $OutputRoot (Read-IW7BaseLog $ServerIdentity.Stdout).Length
    try {
        $context.Transaction=Save-IW7BaseTransaction $Plan (Join-Path $OutputRoot 'backup')
        $arguments="-noupdate -nosteam -cpMode -stdout -paris-capacity-64 -paris-capacity-production -paris-capacity-client-probe +set net_ip 127.0.0.1 +set net_port $($Plan.ClientPort) +set password $Password +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 +set r_vsync 1 +set com_maxfps 30 +set r_picmip 2 +set r_picmip_bump 2 +set r_picmip_spec 2 +connect 127.0.0.1:$($Plan.ServerPort)"
        $context.Handle=[IW7LabProcess]::StartOwned($Plan.Image,$arguments,$Plan.GameRoot,"$OutputRoot/client.stdout.log","$OutputRoot/client.stderr.log",$context.DesktopName,$true)
        $context.Client=$context.Handle;$id=$context.Handle.ReadIdentity()
        $context.Identity=[pscustomobject]@{PID=$id.PID;Image=$id.Image;CreatedUtc=[datetime]::FromFileTimeUtc($id.CreationFileTime).ToString('o');SHA256=$Plan.SHA256;Stdout="$OutputRoot/client.stdout.log";Stderr="$OutputRoot/client.stderr.log";DesktopName=$context.DesktopName}
        $context.Identity|ConvertTo-Json|Set-Content "$OutputRoot/client.identity.local.json"
        Add-IW7ResourceProcess -Token $LeaseToken -ProcessId $id.PID
        $context
    }catch{ $_.Exception.Data['BaseClientContext']=$context;throw }
}
