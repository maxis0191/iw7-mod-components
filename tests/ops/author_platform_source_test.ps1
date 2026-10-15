param([string]$GscToolPath,[string]$SDKSourceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($file in @('ops/Author-Platform.Core.ps1','ops/Invoke-AuthorPlatformContact.ps1')){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Author PowerShell source grammar failed.'}
}
$effects=[Collections.Generic.List[string]]::new()
function Enter-IW7ResourceLease {$effects.Add('lease');throw 'Forbidden source effect.'}
function Start-IW7BaseClient {$effects.Add('client');throw 'Forbidden source effect.'}
function Send-IW7CollisionProbeCommand {$effects.Add('engine');throw 'Forbidden source effect.'}
function Get-CimInstance {$effects.Add('process');throw 'Forbidden source effect.'}
$token='1234567890abcdef1234567890abcdef'
$op=Join-Path $root 'ops/Invoke-AuthorPlatformContact.ps1'
$pending=& $op -Token $token|ConvertFrom-Json
$preview=& $op -Token $token -Anchor @(10,20,30)|ConvertFrom-Json
if(!$pending.CoordinatesPending -or $null -ne $pending.Anchor -or !$preview.PreviewOnly -or $preview.FsGame -cne 'mods/sdk_author_platform' -or
    ($preview.Minimum -join ',') -cne '-118,-108,126' -or ($preview.Maximum -join ',') -cne '138,148,142' -or
    ($preview.VisualOrigin -join ',') -cne '10,20,126' -or ($preview.Start -join ',') -cne '10,20,238' -or
    $preview.ClientCollider -or $preview.RendererVerified -or $preview.RenderBoundsQualified -or $preview.OwnerAccepted){throw 'Author Plan fabricated live evidence or changed P geometry.'}
$refused=0
foreach($argsValue in @(@{Action='Run';Token=$token},@{Action='Run';Token=$token;Anchor=@()},@{Action='Run';Token=$token;Anchor=@(0,0,0)})){
    try{& $op @argsValue}catch{if($_.Exception.Message -notmatch 'retained original server/client session|preview only'){throw};$refused++;continue};throw 'Unowned or preview Author Run accepted.'
}
if($effects.Count){throw 'Author Source Plan/refusal performed a live effect.'}
. (Join-Path $root 'ops/Author-Platform.Core.ps1')
$contract=Get-IW7AuthorPlatformSDKContract
$receipt=[pscustomobject]@{product=$contract.Product;revisions=[pscustomobject]@{'iw7-creator-sdk'=$contract.Revision};
    files=@([pscustomobject]@{path=$contract.Script;bytes=$contract.Bytes;sha256=$contract.SHA256})}
$sdkRefusals=0
foreach($change in @('product','revision','revision-array','bytes-string','hash','duplicate','path')){
    $r=$receipt|ConvertTo-Json -Depth 6|ConvertFrom-Json
    switch($change){
        'product' {$r.product='other'}
        'revision' {$r.revisions.'iw7-creator-sdk'='ffffffffffffffffffffffffffffffffffffffff'}
        'revision-array' {$r.revisions.'iw7-creator-sdk'=@($contract.Revision,$contract.Revision)}
        'bytes-string' {$r.files[0].bytes='5404'}
        'hash' {$r.files[0].sha256='F'*64}
        'duplicate' {$r.files+=,$r.files[0]}
        'path' {$r.files[0].path='different.gsc'}
    }
    try{Assert-IW7AuthorPlatformSDKSource $r 'Z:\not-read'}catch{
        if($_.Exception.Message -notmatch 'Reviewed Author SDK Source|Author SDK script is missing'){throw};$sdkRefusals++;continue
    };throw 'Foreign or coerced SDK contract accepted.'
}
if($SDKSourceRoot){
    . (Join-Path $root 'ops/Base-Client.Core.ps1')
    Assert-IW7AuthorPlatformSDKSource $receipt $SDKSourceRoot
    Write-Output 'PASS exact separately owned SDK GSC Source bytes; no VM/runtime qualification.'
}
if($GscToolPath){
    if((Get-FileHash -LiteralPath $GscToolPath).Hash -cne '1ADFD67414A9B886CBAD57EE0378F622EED485BCEF7711322AEE478E298FADCB'){throw 'Pinned GSC parser differs.'}
    $output=@(& $GscToolPath -m parse -g iw7 -s pc -y (Join-Path $root 'tests/fixtures/author_platform_contact.gsc') 2>&1)
    if($LASTEXITCODE -ne 0 -or ($output -join "`n") -match '\[ERROR\]|failed|exception' -or
        @($output|Where-Object{"$_" -match '^parsed iw7/author_platform_contact.gsc$'}).Count -ne 1){throw 'Author GSC source grammar failed.'}
    Write-Output 'PASS pinned Author GSC grammar; runtime compilation remains untested.'
}
Write-Output "PASS Author Source plans/grammar, $refused causal Run and $sdkRefusals SDK contract refusals; live effects=0."
