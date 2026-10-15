$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/ops/Author-Platform.Core.ps1"
$token='1234567890abcdef1234567890abcdef';$nonce='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$gen='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$scene="[SDK author platform] SCENE_READY; token=$token; entity=710; instance=900; uses=0; physics_unverified=1; runtime_ready=0.`n"
function Pair([long]$Tick){
    $stamp="server_pid=42; client_nonce=$nonce; server_generation=$gen; slot=0; native_tick_ms=$Tick; protected=1"
    "[Collision player] PLAYER_READY token=$token; $stamp; anchor_x=10; anchor_y=20; anchor_z=30`n"+
    "[Author display] READY token=$token; $stamp; anchor_x=10; anchor_y=20; anchor_z=30; entity=710; instance=900; x=10; y=20; z=126; angles=0,0,0; scale=1; uses=0; sdk_armed=0; collision_arm=0`n"
}
$first=$scene+(Pair 1400);$text=$first+(Pair 1600)
function Read-Display([string]$Value){Read-IW7AuthorDisplayReady $Value $token 42 $nonce 1100 1700}
$before=Read-Display $first;$after=Read-Display $text
if(!$before.Ready -or !$after.Ready -or $after.Entity -ne 710 -or $after.Instance -ne 900 -or ($after.Anchor -join ',') -cne '10,20,30'){throw 'Display readiness rejected the protected visual.'}
$rejected=0
$bad=@(
    $text.Replace('collision_arm=0','collision_arm=1'),
    $text.Replace('sdk_armed=0','sdk_armed=1'),
    $text.Replace('uses=0','uses=1'),
    $text.Replace('protected=1','protected=0'),
    $text.Replace('entity=710','entity=711').Replace($scene.Replace('entity=710','entity=711'),$scene),
    $text.Replace('native_tick_ms=1600','native_tick_ms=1400'),
    $text.Replace('native_tick_ms=1600','native_tick_ms=1701'),
    $text.Replace('z=126; angles','z=127; angles'),
    $text.Replace('anchor_x=10','anchor_x=NaN'),
    ($text+$scene),
    ($text+"[Collision player] PLACED token=$token phase=F0 x=10 y=20 z=238`n"),
    ($text+"[Collision provider] created world=0 entity=711 instance=7`n"),
    ($text+"[Author contact] USE_EDGE token=$token sequence=1`n"),
    ($text+"[SDK author platform] USED; token=$token; uses=1`n"),
    ($text+"[SDK author platform] RESTORE_PENDING`n"),
    ($text+"[Collision player] FAIL token=$token reason=display_readiness_lost`n")
)
foreach($case in $bad){if($case -ceq $text){throw 'Causal display mutation changed nothing.'};try{$r=Read-Display $case}catch{$rejected++;continue};if($r.Ready){throw 'Invalid display evidence accepted.'};$rejected++}
foreach($tail in @('[SDK author platform] RESTORE_PENDING',"[Author display] READY token=$token", "[Collision player] FAIL token=$token reason=partial",
    "[Collision player] PLAYER_READY token=$token; malformed", "[SDK author platform] USED; token=$token;")){
    if((Read-Display ($text+$tail)).Ready){throw 'Earlier display hid an unterminated own critical row.'};$rejected++
}
if((Read-IW7AuthorDisplayReady $text $token 42 $nonce 1100 2101).Ready){throw 'Expired display accepted.'};$rejected++
$rows=@(
    @{type='step_start';id='display-original-frame';action='capture'},
    @{type='capture';id='display-original-frame';path='C:\synthetic-metadata\original.bmp';sha256=('a'*64)},
    @{type='step_complete';id='display-original-frame';action='capture';witness='native_frame'},
    @{type='released'},@{type='complete';passed=$true}
)
$captureInput=[pscustomobject]@{Passed=$true;Name='author-platform-display';GameplayAssertions=0;Evidence='C:\synthetic-metadata\scenario.jsonl'}
$result=New-IW7AuthorDisplayResult $before $after $captureInput $rows 1450 1550
if($result.Schema -cne 'iw7.author-platform-display/1' -or !$result.DisplayEpisodeExecuted -or !$result.ContactNotRun -or
    $result.PixelsVerified -or $result.LifecycleClosed -or $result.LeaseReleased -or $result.OriginalHostExitObserved -or
    $result.PSObject.Properties.Name -contains 'MeasurementPassed'){throw 'Typed display overclaimed measurement, pixels or closure.'}
foreach($change in @('visual','capture-order','input','move-step','no-capture','duplicate-capture','no-release','cleanup-gap','record-order')){
    $a=$after.PSObject.Copy();$i=$captureInput.PSObject.Copy();$r=@($rows|ConvertTo-Json -Depth 5|ConvertFrom-Json -AsHashtable);$start=1450L;$end=1550L
    switch($change){
        'visual' {$a.Instance++}
        'capture-order' {$end=1601}
        'input' {$i.Passed=$false}
        'move-step' {$r[0].action='hold'}
        'no-capture' {$r=@($r|Where-Object type -CNE 'capture')}
        'duplicate-capture' {$r+=,$r[1]}
        'no-release' {$r=@($r|Where-Object type -CNE 'released')}
        'cleanup-gap' {$r+=@{type='cleanup_gap'}}
        'record-order' {$r=@($r[0],$r[2],$r[1],$r[3],$r[4])}
    }
    try{$null=New-IW7AuthorDisplayResult $before $a $i $r $start $end}catch{$rejected++;continue};throw 'Unqualified display result accepted.'
}
$op="$root/ops/Invoke-AuthorPlatformContact.ps1"
$p=& $op -Token $token -Phase DisplayOnly|ConvertFrom-Json
$contact=& $op -Token $token|ConvertFrom-Json
if($p.Phase -cne 'DisplayOnly' -or !$p.CoordinatesPending -or $p.Config -notmatch 'set paris_author_platform_display_only 1' -or
    $contact.Phase -cne 'Contact' -or $contact.Config -notmatch 'set paris_author_platform_display_only 0'){throw 'Display seal or backward-compatible Contact default changed.'}
try{& $op -Token $token -Phase displayonly;throw 'Case-variant phase accepted.'}catch{if($_.Exception.Message -eq 'Case-variant phase accepted.'){throw};$rejected++}
try{& $op -Action Run -Phase DisplayOnly -Token $token;throw 'Unowned display ran.'}catch{if($_.Exception.Message -notmatch 'retained original server/client session'){throw};$rejected++}
# Inspect the actual operation branch. No process, image, frame, SDK, native
# import or runtime is touched by the synthetic Source transcript cases above.
$ast=[Management.Automation.Language.Parser]::ParseFile($op,[ref]$null,[ref]$null)
$branch=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Extent.Text.StartsWith("if(`$Phase -ceq 'DisplayOnly')")})
if($branch.Count -ne 1 -or $branch[0].Extent.Text -match 'Send-IW7CollisionProbeCommand|button=|MeasurementPassed|Read-IW7AuthorPlatformResult'){
    throw 'Display branch calls contact/control paths.'
}
$fixture=Get-Content -LiteralPath "$root/tests/fixtures/author_platform_contact.gsc" -Raw
if(!$fixture.Contains('else if (getdvarint("paris_collision_probe_arm")) break;') -or
    !$fixture.Contains('if (state.display_only) { fail(state, "display_readiness_expired"); return; }')){throw 'Display could reach the contact body.'}
# Execute that exact branch using metadata-only doubles; no BMP is created/read.
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('iw7-display-source-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tmp)|Out-Null
try{
    $branchResult=& {
        $Phase='DisplayOnly';$Session=[pscustomobject]@{OutputRoot=$tmp;StartedTick=1L};$ServerIdentity=[pscustomobject]@{Stdout='unused';PID=42}
        $firstReady=[pscustomobject]@{Ready=$true;Generation=$gen;Anchor=@(10,20,30)}
        function Read-IW7BaseLog {'synthetic Source metadata'}
        function Read-IW7AuthorDisplayReady($Text,$Token,$ServerId,$ClientNonce,$NotBeforeTick,$NowTick){
            [pscustomobject]@{Ready=$true;Generation=$gen;Anchor=@(10,20,30);Entity=710;Instance=900;CollisionArm=0;SDKUses=0;Tick=$NotBeforeTick}
        }
        function Update-IW7BaseClient {}
        function Send-IW7CollisionProbeCommand {throw 'Source display dispatched collision arm.'}
        function Write-CollisionInputScenario($Name,$Steps){
            if($Name -cne 'author-platform-display' -or $Steps.Count -ne 1 -or $Steps[0].action -cne 'capture'){throw 'Display added an input driver/action.'}
            'synthetic-source-scenario'
        }
        function Invoke-IW7AgentScenario($Session,$ScenarioPath){
            $records=@(@{type='step_start';id='display-original-frame';action='capture'},
                @{type='capture';id='display-original-frame';path=(Join-Path $tmp 'original.bmp');sha256=('a'*64)},
                @{type='step_complete';id='display-original-frame';action='capture';witness='native_frame'},
                @{type='released'},@{type='complete';passed=$true})
            $path=Join-Path $tmp 'synthetic-source.jsonl'
            [IO.File]::WriteAllLines($path,@($records|ForEach-Object {ConvertTo-Json $_ -Compress}))
            [pscustomobject]@{Passed=$true;Name='author-platform-display';GameplayAssertions=0;Evidence=$path}
        }
        & ([scriptblock]::Create($branch[0].Extent.Text))
    }
    if(!$branchResult.DisplayEpisodeExecuted -or !$branchResult.ContactNotRun -or $branchResult.PixelsVerified -or
        (Test-Path -LiteralPath (Join-Path $tmp 'original.bmp'))){throw 'Source branch failed or touched an image.'}
}finally{
    $resolved=[IO.Path]::GetFullPath($tmp)
    if(!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'iw7-display-source-*'){throw 'Unexpected Source test cleanup root.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS display-only Source: protected visual/typed capture positives, $rejected causal refusals; no image/process/game effects."
