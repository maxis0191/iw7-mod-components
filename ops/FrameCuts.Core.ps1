$ErrorActionPreference='Stop'
# Frame cuts (a51): two changes to fork files of the pinned iw7-mod, kept as data in ops/frame-cuts/frame-cut-edits.json:
#   gsc/script_extension.cpp  the per-opcode replacefunc check tests a one byte filter (src/native/paris_vm_filter.hpp) before it saves any register
#   game/game.cpp             G_LogPrintf appends through one open handle per path (src/native/paris_log_stream.hpp) instead of open, write, close
# Other overlays rebuild a file from the pinned blob and refuse anything else (Apply-DebuggerOverlay.ps1 on script_extension.cpp). These edits are plain text
# replacements that can be taken out again, so that overlay calls Remove-IW7FrameCutText on what it reads, and Apply-FrameCutsOverlay.ps1 runs after it.
function Get-IW7FrameCutSpec {
    $spec=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'frame-cuts/frame-cut-edits.json') -Raw | ConvertFrom-Json
    if($spec.schema -ne 'iw7.frame-cut-edits/1'){throw 'Frame cut edit file: unknown schema.'}
    $spec
}
function Get-IW7FrameCutCount([string]$Text,[string]$Needle){
    $Text.Split([string[]]@($Needle),[StringSplitOptions]::None).Count-1
}
# State of one edit in a text: Applied, Open or throws (the text is neither the pinned one nor this overlay).
function Get-IW7FrameCutState([string]$Path,[string]$Text,$Edit){
    $n=Get-IW7FrameCutCount $Text $Edit.new
    if($n -eq [int]$Edit.count){return 'Applied'}
    if($n -eq 0 -and (Get-IW7FrameCutCount $Text $Edit.old) -eq [int]$Edit.count){return 'Open'}
    throw "Frame cut text not recognised in ${Path}: expected $($Edit.count) of '$(($Edit.old -split "`n")[0].Trim())'."
}
function Add-IW7FrameCutText([string]$Relative,[string]$Text,[string]$Commit){
    $spec=Get-IW7FrameCutSpec
    if($spec.pin -ne $Commit){return $Text}
    $file=@($spec.files|Where-Object{$_.path -ceq $Relative})
    if(!$file){return $Text}
    foreach($edit in $file[0].edits){
        if((Get-IW7FrameCutState $Relative $Text $edit) -eq 'Open'){
            $Text=$Text.Split([string[]]@($edit.old),[StringSplitOptions]::None) -join $edit.new
        }
    }
    $Text
}
function Remove-IW7FrameCutText([string]$Relative,[string]$Text,[string]$Commit){
    $spec=Get-IW7FrameCutSpec
    if($spec.pin -ne $Commit){return $Text}
    $file=@($spec.files|Where-Object{$_.path -ceq $Relative})
    if(!$file){return $Text}
    $edits=@($file[0].edits)
    [array]::Reverse($edits)
    foreach($edit in $edits){
        if((Get-IW7FrameCutState $Relative $Text $edit) -eq 'Applied'){
            $Text=$Text.Split([string[]]@($edit.new),[StringSplitOptions]::None) -join $edit.old
        }
    }
    $Text
}
