param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$GhidraRoot,
    [Parameter(Mandatory)][string]$JavaRoot,
    [string]$Python='python',
    [string]$Uv='uv'
)
$ErrorActionPreference='Stop'
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$GhidraRoot=(Resolve-Path -LiteralPath $GhidraRoot).Path
$JavaRoot=(Resolve-Path -LiteralPath $JavaRoot).Path
if(!(Test-Path -LiteralPath (Join-Path $GhidraRoot 'support/analyzeHeadless.bat')) -or
   !(Test-Path -LiteralPath (Join-Path $JavaRoot 'bin/java.exe'))){throw 'Existing Ghidra and Java installations are required.'}
$pythonPath=Join-Path $InstallRoot 'Scripts/python.exe'
if(!(Test-Path -LiteralPath $pythonPath)){
    if(Test-Path -LiteralPath $InstallRoot){throw 'Refusing to replace a pre-existing non-venv directory.'}
    & $Uv venv --python $Python $InstallRoot
    if($LASTEXITCODE){throw 'Virtual environment creation failed.'}
}
$pin='42d8f80551a765441b1a723f6f1ff45aa3914d5e'
& $Uv pip install --python $pythonPath -r (Join-Path $PSScriptRoot 're-tools/requirements.lock.txt')
if($LASTEXITCODE){throw 'Pinned package installation failed.'}
& $pythonPath -c 'import sys; sys.path.insert(0,sys.argv[1]); from serve_project import verify_package; verify_package(); print("Pinned RE package verified")' (Join-Path $PSScriptRoot 're-tools')
if($LASTEXITCODE){throw 'Package identity validation failed.'}
$manifest=[ordered]@{
    Schema='iw7.re-tools.install/1'; InstalledUtc=[DateTime]::UtcNow.ToString('o')
    Python=$pythonPath; GhidraRoot=$GhidraRoot; JavaRoot=$JavaRoot
    Package='pyghidra-mcp'; Source='https://github.com/clearbluejar/pyghidra-mcp'; Revision=$pin
    RequirementsSHA256=(Get-FileHash (Join-Path $PSScriptRoot 're-tools/requirements.lock.txt')).Hash
    InspectionEntrySHA256=(Get-FileHash (Join-Path $PSScriptRoot 're-tools/serve_project.py')).Hash
    ServiceInstalled=$false; GlobalPathChanged=$false; CodexConfigChanged=$false
    RuntimeQualified=$false
}
$manifest|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $InstallRoot 'iw7-install.json') -Encoding utf8
$manifest|ConvertTo-Json
