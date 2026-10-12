$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('iw7-privacy-'+[guid]::NewGuid().ToString('N'))
$path=Join-Path $temp 'src/client/component/dedicated.cpp'
$script:fixture="void send_heartbeat() { if (sv_lanOnly->current.enabled) { return; } send(); }`n"
function git { $global:LASTEXITCODE=0; "void send_heartbeat() { if (sv_lanOnly->current.enabled) { return; } send(); }" }
try {
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
    [IO.File]::WriteAllText($path,$script:fixture)
    $first=& "$repo/ops/Apply-TestPrivacyOverlay.ps1" -NativeRoot $temp -Commit fixture
    $second=& "$repo/ops/Apply-TestPrivacyOverlay.ps1" -NativeRoot $temp -Commit fixture
    if(!$first.TestHeartbeatSuppressed -or $first.SHA256 -cne $second.SHA256){throw 'Idempotent overlay failed.'}
    $known=[IO.File]::ReadAllText($path)
    if(!$known.Contains('has_flag("paris-server-test")') -or !$known.Contains('has_flag("paris-isolated-lab")')){throw 'A test path can advertise.'}
    [IO.File]::AppendAllText($path,'// unrelated owner edit')
    $before=(Get-FileHash $path).Hash
    $rejected=$false
    try { & "$repo/ops/Apply-TestPrivacyOverlay.ps1" -NativeRoot $temp -Commit fixture } catch {
        if($_ -notmatch 'Unowned dedicated edits'){throw}; $rejected=$true
    }
    if(!$rejected -or (Get-FileHash $path).Hash -cne $before){throw 'Unowned source was changed.'}
    function git { $global:LASTEXITCODE=0; 'void send_heartbeat() { send(); }' }
    $rejected=$false
    try { & "$repo/ops/Apply-TestPrivacyOverlay.ps1" -NativeRoot $temp -Commit fixture } catch {
        if($_ -notmatch 'Pinned heartbeat gate changed'){throw}; $rejected=$true
    }
    if(!$rejected -or (Get-FileHash $path).Hash -cne $before){throw 'Changed pinned source was accepted.'}
    'PASS: privacy overlay installation, repeated application, owned-source refusal and changed-upstream refusal.'
} finally {
    Remove-Item Function:\git
    # Only files created by this test; no recursive directory deletion.
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    foreach($relative in @('src/client/component','src/client','src','')){
        $directory=if($relative){Join-Path $temp $relative}else{$temp}
        if(Test-Path -LiteralPath $directory){[IO.Directory]::Delete($directory,$false)}
    }
}
