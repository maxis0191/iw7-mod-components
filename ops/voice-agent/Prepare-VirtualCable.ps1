#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [string]$ArchivePath
)
# Download/validate/extract only. Never executes vendor setup/control panel,
# installs/removes a driver, opens audio streams or changes endpoint settings.
$ErrorActionPreference='Stop'
$source='https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
$expected='B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
$root=[IO.Path]::GetFullPath($OutputRoot)
if (!$root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $root)) { throw 'Fresh directory under ignored repository runtime required.' }
$cursor=Split-Path $root -Parent
while ($cursor) {
    if (Test-Path -LiteralPath $cursor) {
        if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Package output ancestors must not redirect through reparse points.' }
    }
    $parent=Split-Path $cursor -Parent
    if ($parent -eq $cursor) { break };$cursor=$parent
}
$packageBytes=if ($ArchivePath) {
    $file=[IO.File]::Open([IO.Path]::GetFullPath($ArchivePath),'Open','Read','Read')
    try {
        if ($file.Length -gt 2MB) { throw 'Local package exceeds reviewed size bound.' }
        $buffer=[byte[]]::new([int]$file.Length);$file.ReadExactly($buffer);$buffer
    } finally { $file.Dispose() }
} else {
    $client=[Net.Http.HttpClient]::new()
    $cancel=[Threading.CancellationTokenSource]::new([timespan]::FromSeconds(30));$response=$null;$stream=$null
    try {
        $response=$client.GetAsync($source,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        if ($response.Content.Headers.ContentLength -gt 2MB) { throw 'Remote package exceeds reviewed size bound.' }
        $stream=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $buffer=[byte[]]::new(2MB+1);$read=0
        do { $next=$stream.ReadAsync($buffer,$read,$buffer.Length-$read,$cancel.Token).GetAwaiter().GetResult();$read+=$next } while ($next -gt 0 -and $read -lt $buffer.Length)
        if ($read -gt 2MB) { throw 'Remote package exceeds reviewed size bound.' }
        $result=[byte[]]::new($read);[Array]::Copy($buffer,$result,$read);$result
    } finally { if ($stream) {$stream.Dispose()};if ($response) {$response.Dispose()};$cancel.Dispose();$client.Dispose() }
}
if ($packageBytes.Length -gt 2MB -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($packageBytes)) -ne $expected) { throw 'Official package bytes differ from the reviewed SHA256; nothing extracted.' }
$tool=Get-Command signtool.exe -ErrorAction SilentlyContinue
$signTool=if ($tool) { $tool.Source } else {
    $sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    @(Get-ChildItem -LiteralPath $sdk -Directory | Sort-Object Name -Descending | ForEach-Object {
        $candidate=Join-Path $_.FullName 'x64/signtool.exe';if (Test-Path -LiteralPath $candidate) { $candidate }
    } | Select-Object -First 1)[0]
}
if (!$signTool -or (Get-AuthenticodeSignature -LiteralPath $signTool).Status -ne 'Valid') { throw 'Existing signed Windows SDK signtool required for kernel catalogue membership validation.' }
[IO.Directory]::CreateDirectory($root) | Out-Null
$archive=Join-Path $root 'VBCABLE_Driver_Pack45.zip'
[IO.File]::WriteAllBytes($archive,$packageBytes)
$unpacked=Join-Path $root 'unpacked';[IO.Directory]::CreateDirectory($unpacked) | Out-Null
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$total=0L
    if ($zip.Entries.Count -gt 128) { throw 'Package entry count exceeds preparation bound.' }
    foreach ($entry in $zip.Entries) {
        $total+=$entry.Length
        if ($entry.FullName -notmatch '^[a-zA-Z0-9_.]{1,128}$' -or !$names.Add($entry.FullName) -or $entry.Length -gt 2MB -or $total -gt 16MB) { throw 'Package entry/path/size bound exceeded.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $unpacked $entry.FullName),$false)
    }
} finally { $zip.Dispose() }
$signatures=@(foreach ($leaf in @('VBCABLE_Setup_x64.exe','VBCABLE_ControlPanel.exe','vbaudio_cable64_win10.cat','vbaudio_cable64_win10.sys')) {
    $path=Join-Path $unpacked $leaf;$signature=Get-AuthenticodeSignature -LiteralPath $path
    $publisher=if ($leaf -like '*.cat') { 'Microsoft Windows Hardware Compatibility Publisher' } else { 'BUREL VINCENT Entrepreneur individuel' }
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike ('CN='+$publisher+',*')) { throw ('Reviewed publisher/signature mismatch: '+$leaf) }
    [pscustomobject]@{File=$leaf;SHA256=(Get-FileHash -LiteralPath $path).Hash;Status=$signature.Status.ToString();Publisher=$publisher;
        CertificateSHA1=$signature.SignerCertificate.Thumbprint;TimeStamperSHA1=$signature.TimeStamperCertificate.Thumbprint}
})
$catalogue=Join-Path $unpacked 'vbaudio_cable64_win10.cat'
$kernel=@(foreach ($leaf in @('vbaudio_cable64_win10.sys','vbMmeCable64_win10.inf')) {
    $log=& $signTool verify /kp /v /c $catalogue (Join-Path $unpacked $leaf) 2>&1
    $exit=$LASTEXITCODE
    $log | Set-Content -LiteralPath (Join-Path $root ($leaf+'.signature.log'))
    if ($exit -ne 0) { throw ('Windows kernel policy/catalogue membership verification failed: '+$leaf) }
    [pscustomobject]@{File=$leaf;KernelPolicyExit=$exit;Catalogue='vbaudio_cable64_win10.cat'}
})
$manifest=[ordered]@{Schema=1;Kind='downloaded_verified_not_installed';Utc=[datetime]::UtcNow.ToString('o');
    Source=$source;OfficialPage='https://vb-audio.com/Cable/index.htm';PackageSHA256=$expected;DriverVersion='3.3.1.7';DriverDate='2024-10-07';
    ArchiveBytes=$packageBytes.Length;Signatures=$signatures;KernelCatalogue=$kernel;
    SignToolSHA256=(Get-FileHash -LiteralPath $signTool).Hash;PreparationSHA256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;
    Files=@(Get-ChildItem -LiteralPath $unpacked -File | ForEach-Object { [pscustomobject]@{File=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash} });
    SetupExecuted=$false;DriverInstalled=$false;ChangedAudioDefaults=$false;CapturedMicrophone=$false}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'manifest.local.json')
[pscustomobject]@{OutputRoot=$root;PackageSHA256=$expected;KernelPolicyVerified=$true;DriverInstalled=$false;Manifest=(Join-Path $root 'manifest.local.json')}
