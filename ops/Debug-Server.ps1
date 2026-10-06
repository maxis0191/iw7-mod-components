param(
    [ValidateSet('Doctor','Identity','Observe','Snapshot','AnalyzeDump','Etw','Decompile')][string]$Action='Doctor',
    [int]$ProcessId,
    [string]$ExpectedImage,
    [datetimeoffset]$ExpectedCreatedUtc,
    [string]$ExpectedSHA256,
    [string]$InputPath,
    [string]$SymbolsPath,
    [string]$OutputPath,
    [string]$Scenario='unspecified observation',
    [ValidateRange(1,120)][int]$Seconds=30,
    [ValidateRange(100,5000)][int]$IntervalMs=500,
    [ValidateRange(0,65535)][int]$Port=0,
    [switch]$Threads,
    [switch]$MicrosoftSymbols,
    [string]$ReferenceRoot,
    [string]$FunctionList,
    [string]$GhidraRoot
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7 (the bundled pwsh is sufficient).' }
$repo=Split-Path $PSScriptRoot -Parent
$runtime=Join-Path $repo 'runtime/debugger'
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
function Write-Result($Value) { $Value | ConvertTo-Json -Depth 12 }
function New-DebugOutput([string]$Path,[string]$Extension) {
    if (!$Path) { $Path=Join-Path $runtime ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+$Extension) }
    $Path=[IO.Path]::GetFullPath($Path)
    $ignored=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
    if (!$Path.StartsWith($ignored+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($Path) -ne $Extension -or (Test-Path -LiteralPath $Path)) { throw 'Evidence needs a new file under this worktree runtime with the requested extension.' }
    $parent=Split-Path $Path -Parent
    $cursor=$parent
    while ($cursor -and $cursor.StartsWith($repo,[StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Evidence directory may not be redirected.' }
        $cursor=Split-Path $cursor -Parent
    }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $Path
}
function Get-DebugIdentity([int]$Id) {
    if ($Id -le 0) { throw 'A positive ProcessId is required.' }
    $process=Get-Process -Id $Id -ErrorAction Stop
    try {
        $image=$process.MainModule.FileName
        [ordered]@{PID=$Id;Image=$image;CreatedUtc=$process.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $image).Hash}
    } finally { $process.Dispose() }
}
function Assert-DebugIdentity {
    if (!$ExpectedImage -or $ExpectedCreatedUtc -eq [datetimeoffset]::MinValue -or $ExpectedSHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Supply exact expected image, creation time and SHA256 from Identity.' }
    $actual=Get-DebugIdentity $ProcessId
    if ([IO.Path]::GetFullPath($ExpectedImage) -ne $actual.Image -or
        ([datetimeoffset]$ExpectedCreatedUtc).UtcDateTime.Ticks -ne ([datetimeoffset]$actual.CreatedUtc).UtcDateTime.Ticks -or
        $ExpectedSHA256 -ne $actual.SHA256) { throw 'Process identity changed; refusing acquisition.' }
    $actual
}
function Get-Cdb {
    $package=Get-AppxPackage Microsoft.WinDbg -ErrorAction SilentlyContinue
    if (!$package -or $package.Version -ne '1.2606.22001.0') { throw 'Install pinned debugger with ops/Install-Tools.ps1 -IncludeWinDbg.' }
    $path=Join-Path $package.InstallLocation 'amd64/cdb.exe'
    if ((Get-FileHash -LiteralPath $path).Hash -ne '5F54ABAFCA3AE5638BBF807D402FABB350A64575C1DFA9FBFC7F5732DF5BEE67') { throw 'CDB checksum mismatch.' }
    $path
}
function Invoke-DebugTool([string]$Exe,[string[]]$Arguments,[int]$Timeout=120) {
    $start=[Diagnostics.ProcessStartInfo]::new($Exe)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($Timeout*1000)) {
            $process.Kill($true); $process.WaitForExit()
            throw "Owned diagnostic process exceeded ${Timeout}s; it was closed. No game process was stopped."
        }
        [pscustomobject]@{Code=$process.ExitCode;Text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}
switch ($Action) {
    'Doctor' {
        $cdb=$null; $cdbError=$null
        try { $cdb=Get-Cdb } catch { $cdbError=$_.Exception.Message }
        $status=Get-IW7ResourceStatus
        Write-Result ([ordered]@{Schema='iw7.debugger/1';Kind='doctor';PowerShell=$PSVersionTable.PSVersion.ToString();
            Python=(Get-Command python -ErrorAction SilentlyContinue).Source;CDB=$cdb;CDBError=$cdbError;
            WPR=(Get-Command wpr -ErrorAction SilentlyContinue).Source;
            Elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
            SourceCommit=(git -C $repo rev-parse HEAD);PhysicalPercent=$status.Budget.PhysicalUsedPercent;CommitPercent=$status.Budget.CommitUsedPercent;
            HeavyHolders=@($status.Leases | Select-Object Kind,Owner,Scope);Commands=@('Identity','Observe','Snapshot','AnalyzeDump','Etw','Decompile');
            Limits='No always-on service, no automatic deployment/restarts. Raw dumps/ETL can contain private data and remain local.'})
    }
    'Identity' { Write-Result (Get-DebugIdentity $ProcessId) }
    'Observe' {
        $identity=Assert-DebugIdentity
        $destination=New-DebugOutput $OutputPath '.jsonl'
        $arguments=@("$PSScriptRoot/iw7_capture.py",'--pid',"$ProcessId",'--image',$identity.Image,'--created',$identity.CreatedUtc,'--sha256',$identity.SHA256,
            '--seconds',"$Seconds",'--interval-ms',"$IntervalMs",'--port',"$Port",'--scenario',$Scenario,'--output',$destination)
        if ($Threads) { $arguments+='--threads' }
        & python @arguments
        if ($LASTEXITCODE) { throw 'Verified observer failed; preserve any partial trace.' }
    }
    'Snapshot' {
        $identity=Assert-DebugIdentity
        $labRoot=[IO.Path]::GetFullPath((Join-Path $repo 'runtime/isolated-lab'))
        $record=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -OperationTimeoutSec 5
        if (!$identity.Image.StartsWith($labRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
            !$record -or $record.CommandLine -notmatch '(?:^|\s)-paris-isolated-lab(?:\s|$)') { throw 'Live snapshots require this worktree isolated lab identity; production is refused.' }
        $destination=New-DebugOutput $OutputPath '.dmp'
        & python "$PSScriptRoot/iw7_capture.py" --pid $ProcessId --image $identity.Image --created $identity.CreatedUtc --sha256 $identity.SHA256 `
            --snapshot --scenario $Scenario --output $destination
        if ($LASTEXITCODE) { throw 'Lab snapshot failed; retain partial diagnostics.' }
    }
    'AnalyzeDump' {
        $cdb=Get-Cdb
        $dumpPath=(Resolve-Path -LiteralPath $InputPath).Path
        if ([IO.Path]::GetExtension($dumpPath) -ne '.dmp') { throw 'CDB needs an extracted .dmp; Python dump accepts crash ZIPs directly.' }
        $destination=New-DebugOutput $OutputPath '.txt'
        $symbolArgs=@()
        if ($SymbolsPath) {
            $symbols=(Resolve-Path -LiteralPath $SymbolsPath).Path
            if ($symbols -match '[;"\r\n]') { throw 'Unsupported symbol path characters.' }
            $symbolArgs=@('-y',$symbols)
        }
        if ($MicrosoftSymbols) {
            $cache=Join-Path $runtime 'microsoft-symbols'; [IO.Directory]::CreateDirectory($cache) | Out-Null
            $symbolArgs=@('-y',($(if ($SymbolsPath) { $symbols+';' } else { '' })+'srv*'+$cache+'*https://msdl.microsoft.com/download/symbols'))
        }
        $result=Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'Offline CDB crash triage' -PhysicalBytes 2GB -CommitBytes 3GB -Body {
            Invoke-DebugTool $cdb (@('-z',$dumpPath)+$symbolArgs+@('-c','!analyze -v; .ecxr; kv; ~* kP; lmv; .time; !address -summary; q')) 120
        }
        [IO.File]::WriteAllText($destination,$result.Text,[Text.UTF8Encoding]::new($false))
        if ($result.Code) { throw "CDB failed ($($result.Code)); preserve $destination." }
        & python "$PSScriptRoot/iw7_debugger.py" cdb $destination
        if ($LASTEXITCODE) { throw 'CDB result parsing failed.' }
        Write-Result @{Output=$destination;ExitCode=$result.Code;Meaning='Check PE/PDB/dump identities with symbols before trusting source attribution.'}
    }
    'Etw' {
        # A unique WPR instance prevents stop/cancel of any other recording.
        $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (!$admin) { throw 'WPR requires an elevated PowerShell session. No recording or elevation was started.' }
        $destination=New-DebugOutput $OutputPath '.etl'
        $session='IW7Debugger-'+[guid]::NewGuid().ToString('N')
        $wpr=(Get-Command wpr -ErrorAction Stop).Source
        Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'Bounded named WPR CPU recording' -PhysicalBytes 1GB -CommitBytes 2GB -Body {
            $start=Invoke-DebugTool $wpr @('-start','CPU.light','-instancename',$session) 20
            if ($start.Code) { throw "WPR could not start its private instance: $($start.Text)" }
            $stopped=$false
            try {
                $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
                do { Start-Sleep -Milliseconds 250 } while ([datetime]::UtcNow -lt $deadline)
                $stop=Invoke-DebugTool $wpr @('-stop',$destination,'IW7 bounded CPU trace','-skipPdbGen','-instancename',$session) 120
                if ($stop.Code) { throw "Private WPR stop failed: $($stop.Text)" }
                $stopped=$true
            } finally {
                if (!$stopped) { $cancel=Invoke-DebugTool $wpr @('-cancel','-instancename',$session) 20; if ($cancel.Code) { Write-Warning "Only own WPR instance remains to diagnose: $session" } }
            }
        }
        Write-Result @{Schema='iw7.debugger/1';Kind='etw';Instance=$session;Output=$destination;SHA256=(Get-FileHash $destination).Hash;
            Meaning='CPU stacks for the full host. Filter the verified process identity; OS traces can contain private data. WPR timing is not renderer FPS.'}
    }
    'Decompile' {
        # Reuse the reviewed range-bounded Ghidra script with a caller-selected list.
        if (!$GhidraRoot) { $GhidraRoot=Join-Path $repo 'tools/ghidra' }
        $destination=New-DebugOutput $OutputPath '.c'
        $references=(Resolve-Path -LiteralPath $ReferenceRoot).Path
        $functions=(Resolve-Path -LiteralPath $FunctionList).Path
        $lines=@(Get-Content -LiteralPath $functions | Where-Object { $_ -and !$_.StartsWith('#') })
        if (!$lines.Count -or $lines.Count -gt 128 -or @($lines | Where-Object { $_ -notmatch '^[A-Za-z0-9_]+,[0-9a-fA-F]+$' }).Count) { throw 'Use 1..128 function_name,preferred_hex_address rows.' }
        $project=Join-Path $env:LOCALAPPDATA ('IW7Debugger/ghidra-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($project) | Out-Null
        $inputs=@('unpacked-text.bin','unpacked-rdata.bin','unpacked-pdata.bin')
        $hashes=@($inputs | ForEach-Object { @{Name=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $references $_)).Hash} })
        $oldJava=$env:JAVA_HOME
        try {
            $env:JAVA_HOME=Join-Path $GhidraRoot 'jdk-21.0.12.1+1'
            Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'Selected debugger Ghidra ranges' -PhysicalBytes 4GB -CommitBytes 6GB -Body {
                & (Join-Path $GhidraRoot 'ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat') $project engine `
                    -import (Join-Path $references 'unpacked-text.bin') -loader BinaryLoader -loader-baseAddr 140001000 -processor x86:LE:64:default -cspec windows -noanalysis `
                    -scriptPath (Join-Path $PSScriptRoot 'ghidra') -postScript DecompileSelected.java `
                    (Join-Path $references 'unpacked-rdata.bin') 141435000 (Join-Path $references 'unpacked-pdata.bin') $functions $destination `
                    -log (Join-Path $project 'headless.log')
                if ($LASTEXITCODE -or !(Test-Path -LiteralPath $destination)) { throw "Ghidra failed; retain $project diagnostics." }
            }
        } finally { $env:JAVA_HOME=$oldJava }
        Write-Result @{Schema='iw7.debugger/1';Kind='reverse';Output=$destination;References=$hashes;FunctionListSHA256=(Get-FileHash $functions).Hash;
            Meaning='Local game-derived code. Selected addresses require matching unpacked retail layout; never commit or redistribute output.'}
    }
}
