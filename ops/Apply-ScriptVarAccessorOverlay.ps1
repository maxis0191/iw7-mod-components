param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
$ErrorActionPreference='Stop'
# The client project's script accessors (scripting::array, entity field get and set, script_value type tests) read the GSC variable
# tables through a fixed structure at the stock address. This overlay makes them read through src/native/script_var_layout.hpp
# (stock layout, or the relocated tables of script_variables.cpp). The edits are data: ops/script-variables/accessor-edits.json.
# Only the pinned file or exactly this overlay is accepted; anything else is an unowned edit and stops the build.
$spec=Get-Content -LiteralPath "$PSScriptRoot/script-variables/accessor-edits.json" -Raw | ConvertFrom-Json
if($spec.schema -ne 'iw7.script-var-accessor-edits/1'){throw 'Accessor edit file: unknown schema.'}
if($spec.pin -ne $Commit){return [pscustomobject]@{Applied=$false;Reason="pin $Commit is not $($spec.pin)"}}
$results=@()
foreach($file in $spec.files){
    $path=Join-Path $NativeRoot $file.path
    $base=(((git -C $NativeRoot show ($Commit+':'+$file.path)) -join "`n").TrimEnd())+"`n"
    if($LASTEXITCODE){throw "Pinned source unavailable: $($file.path)"}
    $overlay=$base
    foreach($edit in $file.edits){
        $parts=$overlay.Split([string[]]@($edit.old),[StringSplitOptions]::None)
        if($parts.Count -ne ([int]$edit.count+1)){throw "Pinned accessor text changed in $($file.path): expected $($edit.count) of '$(($edit.old -split "`n")[0].Trim())'."}
        $overlay=$parts -join $edit.new
    }
    if($overlay.Contains('scr_VarGlob')){throw "Accessor overlay left a stock table read in $($file.path)."}
    $current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
    if($current -cne $base -and $current -cne $overlay){throw "Unowned edits in $($file.path); preserve them and use an isolated source checkout."}
    [IO.File]::WriteAllText($path,$overlay,[Text.UTF8Encoding]::new($false))
    $results+=[pscustomobject]@{File=$file.path;SHA256=(Get-FileHash -LiteralPath $path).Hash}
}
[pscustomobject]@{Applied=$true;Pin=$Commit;Files=$results}
