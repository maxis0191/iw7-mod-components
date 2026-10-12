param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
$ErrorActionPreference='Stop'
$relative='src/client/component/dedicated.cpp'
$path=Join-Path $NativeRoot $relative
$base=(((git -C $NativeRoot show ($Commit+':'+$relative)) -join "`n").TrimEnd())+"`n"
if($LASTEXITCODE){throw 'Pinned dedicated source unavailable.'}
$marker='if (sv_lanOnly->current.enabled)'
if($base.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned heartbeat gate changed.'}
# Gate the actual sender, including the startup, timer and manual heartbeat.
# Test flags cannot be overridden by a later config resetting sv_lanOnly.
$overlay=$base.Replace($marker,'if (sv_lanOnly->current.enabled || utils::flags::has_flag("paris-server-test") || utils::flags::has_flag("paris-isolated-lab"))')
$current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
if($current -cne $base -and $current -cne $overlay){throw 'Unowned dedicated edits; preserve them.'}
[IO.File]::WriteAllText($path,$overlay,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{File=$relative;SHA256=(Get-FileHash $path).Hash;TestHeartbeatSuppressed=$true}
