param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
$ErrorActionPreference='Stop'
# Frame cuts overlay (a51). Runs after Apply-DebuggerOverlay.ps1 (which rebuilds script_extension.cpp from the pinned blob) and before the opt-in
# overlays that keep receipts (cutscene, owner cheats), which restore exactly the bytes they found. Idempotent. The edits are data:
# ops/frame-cuts/frame-cut-edits.json; the sources they call are src/native/paris_vm_filter.hpp and paris_log_stream.hpp/.cpp.
. "$PSScriptRoot/FrameCuts.Core.ps1"
$spec=Get-IW7FrameCutSpec
if($spec.pin -ne $Commit){return [pscustomobject]@{Applied=$false;Reason="pin $Commit is not $($spec.pin)"}}
$results=@()
foreach($file in $spec.files){
    $path=Join-Path $NativeRoot $file.path
    $base=(((git -C $NativeRoot show ($Commit+':'+$file.path)) -join "`n").TrimEnd())+"`n"
    if($LASTEXITCODE){throw "Pinned source unavailable: $($file.path)"}
    $current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
    $overlay=Add-IW7FrameCutText $file.path $current $Commit
    # An exclusive file has no other overlay: without the edits it must be the pinned blob. script_extension.cpp is also rebuilt from the pinned blob
    # by the debugger overlay, which refuses unknown text itself; here only the edit texts are checked.
    if($file.exclusive -and (Remove-IW7FrameCutText $file.path $current $Commit) -cne $base){throw "Unowned edits in $($file.path); preserve them and use an isolated source checkout."}
    if($overlay -cne $current){[IO.File]::WriteAllText($path,$overlay,[Text.UTF8Encoding]::new($false))}
    $results+=[pscustomobject]@{File=$file.path;SHA256=(Get-FileHash -LiteralPath $path).Hash}
}
[pscustomobject]@{Applied=$true;Pin=$Commit;Files=$results}
