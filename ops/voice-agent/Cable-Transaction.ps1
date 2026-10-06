#requires -Version 7.4
param(
    [ValidateSet('Snapshot','InstallPlan','RestorePlan','RollbackPlan')][string]$Action='Snapshot',
    [string]$OutputRoot,[string]$PreparedRoot,[string]$BeforePath,[string]$AfterPath
)
# Preparation only: no setup/driver/default-setting command is ever executed.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Cable-Transaction.Core.ps1"
if (!('IW7.VoiceAgent.TokenInventory' -as [type])) { Add-Type -Path "$PSScriptRoot/TokenInventory.cs" }
if (!('IW7.VoiceAgent.CoreAudioInventory' -as [type])) { Add-Type -Path "$PSScriptRoot/CoreAudioInventory.cs" }
function Read-CableSnapshot {
    $raw=@(& "$env:windir/System32/pnputil.exe" /enum-drivers /class Media 2>&1)
    if ($LASTEXITCODE) { throw 'Authoritative MEDIA driver-store enumeration failed.' }
    $packages=@(Convert-IW7MediaPackages ($raw -join "`n") | ForEach-Object {
        $inf=Join-Path "$env:windir/INF" $_.PublishedName
        if (!(Test-Path -LiteralPath $inf)) { throw 'Published INF missing during snapshot.' }
        [pscustomobject]@{PublishedName=$_.PublishedName;OriginalName=$_.OriginalName;InfSHA256=(Get-FileHash -LiteralPath $inf).Hash}
    })
    [pscustomobject]@{
        Schema=1;Utc=[datetime]::UtcNow.ToString('o');Token=[IW7.VoiceAgent.TokenInventory]::Read()
        Endpoints=@([IW7.VoiceAgent.CoreAudioInventory]::Read())
        DirectSoundCapture=@([IW7.VoiceAgent.CoreAudioInventory]::ReadDirectSoundCapture())
        Packages=$packages;RawDriverStore=($raw -join "`n")
        Devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='MEDIA'" | Select-Object Name,PNPDeviceID,ConfigManagerErrorCode,Status)
        Bindings=@(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='MEDIA'" | Select-Object DeviceName,DeviceID,InfName,DriverVersion,DriverProviderName,IsSigned)
        SystemChanged=$false;SetupExecuted=$false;CapturedMicrophone=$false
    }
}
$current=Read-CableSnapshot
if ($Action -eq 'Snapshot') {
    if (!$OutputRoot) { return $current }
    $repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
    $root=[IO.Path]::GetFullPath($OutputRoot)
    if (!$root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $root)) { throw 'Fresh ignored runtime output required.' }
    $cursor=Split-Path $root -Parent
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Snapshot ancestors redirect through reparse point.' }
        $parent=Split-Path $cursor -Parent;if ($parent -eq $cursor) { break };$cursor=$parent
    }
    New-Item -ItemType Directory -Path $root | Out-Null
    $file=Join-Path $root 'snapshot.local.json'
    $current | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding utf8
    return [pscustomobject]@{Snapshot=$file;Elevated=$current.Token.Elevated;ElevationType=$current.Token.ElevationType;PackageCount=$current.Packages.Count;CableEndpointCount=@($current.Endpoints | Where-Object Name -match '^CABLE (Input|Output)').Count;SystemChanged=$false}
}
if (!$PreparedRoot) { throw 'Verified extracted Pack45 directory required.' }
$prepared=[IO.Path]::GetFullPath($PreparedRoot)
$setup=Join-Path $prepared 'unpacked/VBCABLE_Setup_x64.exe'
$inf=Join-Path $prepared 'unpacked/vbMmeCable64_win10.inf'
if ((Get-FileHash -LiteralPath (Join-Path $prepared 'VBCABLE_Driver_Pack45.zip')).Hash -ine 'B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB' -or
    (Get-FileHash -LiteralPath $setup).Hash -ine '734C35DFA6D98F48782A451633CEB471166EC70D60482FD89A1123D0EE3C4F41' -or
    (Get-AuthenticodeSignature -FilePath $setup).Status -ne 'Valid') { throw 'Prepared official package/setup identity changed.' }
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $prepared 'VBCABLE_Driver_Pack45.zip'))
try {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $prepared 'unpacked') -Force)
    if ($files.Count -ne $zip.Entries.Count -or @($files | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) { throw 'Extracted setup directory differs from the official flat archive.' }
    foreach ($entry in $zip.Entries) {
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try { $entryHash=[Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $stream.Dispose();$sha.Dispose() }
        if ((Get-FileHash -LiteralPath (Join-Path $prepared ('unpacked/'+$entry.FullName))).Hash -ine $entryHash) { throw 'An extracted package file changed; refuse setup plan.' }
    }
} finally { $zip.Dispose() }
if ($Action -eq 'InstallPlan') {
    $defaults=@(Get-IW7AudioDefaults $current.Endpoints)
    $existing=@($current.Packages | Where-Object OriginalName -match '^vbMmeCable')
    [pscustomobject]@{
        Kind='not_executed_install_plan';Setup=$setup;Arguments=@('-i','-h');WorkingDirectory=(Split-Path $setup -Parent);WindowStyle='Hidden'
        Elevated=$current.Token.Elevated;ElevationType=$current.Token.ElevationType;ExistingCablePackages=$existing
        ReuseFirst=($existing.Count -gt 0 -or @($current.Endpoints | Where-Object Name -match '^CABLE (Input|Output)').Count -gt 0)
        Defaults=$defaults;ExpectedInfSHA256=(Get-FileHash -LiteralPath $inf).Hash
        Prerequisites=@('Already elevated coordinated shell; never implicit runas/UAC during game','Fresh before snapshot; no occupied owner client','Reviewed pinned restoration CLI ready before setup','No existing/partial VB-CABLE package; reuse or diagnose first','Retain after snapshot and restore only changed roles; coordinated reboot; no automatic reboot')
        RollbackScope='Only newly added exact OEM INF with expected hash; retain export/bindings first; no force, wildcard or pre-existing cable removal'
        CommandEvidence='Signed Pack45 parser and hidden-window/install callbacks inspected offline; options not documented in its reference manual'
        SystemChanged=$false;SetupExecuted=$false
    }
} else {
    if (!$BeforePath -or !$AfterPath) { throw 'Before and immediate-after installation snapshots required.' }
    $before=Get-Content -LiteralPath $BeforePath -Raw | ConvertFrom-Json
    $after=Get-Content -LiteralPath $AfterPath -Raw | ConvertFrom-Json
    if ($Action -eq 'RestorePlan') { New-IW7AudioRestorationPlan $before $after $current }
    else { New-IW7CableRollbackPlan $before $after $current (Get-FileHash -LiteralPath $inf).Hash }
}
