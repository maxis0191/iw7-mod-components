$ErrorActionPreference='Stop'
# Frame cuts (a51): the overlay composes with the debugger overlay (which rebuilds script_extension.cpp from the pinned blob) in every order a kept
# native tree meets, and takes no unowned text. Needs a checkout of the pinned iw7-mod (IW7_NATIVE_ROOT or tools/iw7-mod-native); skipped without.
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$pin='cfca45b11ee14641945b9a264a95638387f48a4a'
. "$repo/ops/FrameCuts.Core.ps1"
$source=@($env:IW7_NATIVE_ROOT,(Join-Path $repo 'tools/iw7-mod-native'))|Where-Object{$_ -and (Test-Path -LiteralPath (Join-Path $_ '.git'))}|Select-Object -First 1
if(!$source){Write-Output 'frame cuts overlay test: skipped (no checkout of the pinned iw7-mod; set IW7_NATIVE_ROOT).';return}
git -C $source cat-file -e "$pin^{commit}"
if($LASTEXITCODE){Write-Output 'frame cuts overlay test: skipped (checkout lacks the pin).';return}
$work=Join-Path ([IO.Path]::GetTempPath()) ('iw7-frame-cuts-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$tree=Join-Path $work 'tree'
function Fail([string]$m){throw "frame cuts overlay test: $m"}
function Read-Native([string]$rel){[IO.File]::ReadAllText((Join-Path $tree $rel)).Replace("`r`n","`n")}
function Pinned([string]$rel){(((git -C $tree show ($pin+':'+$rel)) -join "`n").TrimEnd())+"`n"}
$ext='src/client/component/gsc/script_extension.cpp'
$game='src/client/game/game.cpp'
try{
    New-Item -ItemType Directory -Path $work | Out-Null
    git clone -q --no-checkout --shared $source $tree
    if($LASTEXITCODE){Fail 'clone'}
    git -C $tree checkout -q $pin
    if($LASTEXITCODE){Fail 'checkout'}
    $baseExt=Pinned $ext; $baseGame=Pinned $game
    $spec=Get-IW7FrameCutSpec
    # 1 fresh tree: applied once, idempotent, every edit present
    $r=& "$repo/ops/Apply-FrameCutsOverlay.ps1" -NativeRoot $tree -Commit $pin
    if(!$r.Applied){Fail 'not applied on the pinned tree'}
    $h1=(Get-FileHash (Join-Path $tree $ext)).Hash+(Get-FileHash (Join-Path $tree $game)).Hash
    & "$repo/ops/Apply-FrameCutsOverlay.ps1" -NativeRoot $tree -Commit $pin | Out-Null
    if(((Get-FileHash (Join-Path $tree $ext)).Hash+(Get-FileHash (Join-Path $tree $game)).Hash) -ne $h1){Fail 'second application changed the files'}
    $cutExt=Read-Native $ext
    foreach($needle in @('paris_vm_filter::table','paris_vm_filter::mark(what.u.codePosValue)','paris_vm_filter::clear()','a.je(end)')){if(!$cutExt.Contains($needle)){Fail "script_extension.cpp lacks $needle"}}
    if(!(Read-Native $game).Contains('paris_log_stream::instance().append(file, line)')){Fail 'game.cpp lacks the kept handle'}
    # the cuts come out again, byte for byte
    if((Remove-IW7FrameCutText $ext $cutExt $pin) -cne $baseExt){Fail 'removal does not give the pinned script_extension.cpp'}
    # 2 other pins and other files are left alone
    if((Add-IW7FrameCutText $ext $baseExt 'historical') -cne $baseExt){Fail 'a foreign pin was edited'}
    if((Add-IW7FrameCutText 'src/client/component/scheduler.cpp' 'x' $pin) -cne 'x'){Fail 'an unlisted file was edited'}
    # 3 debugger overlay on top (build with Debugger), then again (kept tree), cuts survive and the debugger step does not refuse
    foreach($round in 1,2){
        & "$repo/ops/Apply-DebuggerOverlay.ps1" -NativeRoot $tree -Commit $pin -Enabled
        & "$repo/ops/Apply-FrameCutsOverlay.ps1" -NativeRoot $tree -Commit $pin | Out-Null
        $t=Read-Native $ext
        if(!$t.Contains('paris_debugger::scope paris_function_scope') -or !$t.Contains('paris_vm_filter::table')){Fail "round $round`: debugger text and cuts are not both present"}
        if((Remove-IW7FrameCutText $ext $t $pin).Contains('paris_vm_filter')){Fail "round $round`: removal left cut text"}
    }
    # 4 build without Debugger on a tree that had it: the debugger text goes, the cuts are put back
    & "$repo/ops/Apply-DebuggerOverlay.ps1" -NativeRoot $tree -Commit $pin
    & "$repo/ops/Apply-FrameCutsOverlay.ps1" -NativeRoot $tree -Commit $pin | Out-Null
    $t=Read-Native $ext
    if($t.Contains('paris_debugger')){Fail 'debugger text stayed after a build without it'}
    if($t -cne $cutExt){Fail 'file after the round trip differs from pinned plus cuts'}
    # 5 an unowned edit in an exclusive file is refused, in script_extension.cpp the debugger step refuses it
    [IO.File]::AppendAllText((Join-Path $tree $game),"`n// foreign`n")
    $refused=$false; try{& "$repo/ops/Apply-FrameCutsOverlay.ps1" -NativeRoot $tree -Commit $pin|Out-Null}catch{$refused=$true}
    if(!$refused){Fail 'an unowned game.cpp edit was accepted'}
    [IO.File]::WriteAllText((Join-Path $tree $game),(Read-Native $game).Replace("`n// foreign`n","`n").TrimEnd()+"`n")
    $e=Read-Native $ext
    [IO.File]::WriteAllText((Join-Path $tree $ext),$e.Replace('vm_execute_hooks.clear();','vm_execute_hooks.clear(); // foreign'))
    $refused=$false; try{& "$repo/ops/Apply-DebuggerOverlay.ps1" -NativeRoot $tree -Commit $pin -Enabled}catch{$refused=$true}
    if(!$refused){Fail 'an unowned script_extension.cpp edit passed the debugger step'}
    Write-Output 'frame cuts overlay test: ok (apply, idempotent, removal, debugger on twice and off, unowned edits refused)'
}finally{
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
