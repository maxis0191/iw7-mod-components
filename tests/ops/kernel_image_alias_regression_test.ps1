param([string]$SourcePath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'native/kernel_image_alias_regression_test.cs'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(![Environment]::Is64BitProcess -or ![OperatingSystem]::IsWindows()){throw 'Actual Win32 kernel/main-module alias regression requires an x64 Windows shell.'}
if('IW7.BootProof.KernelImageAliasRegression' -as [type]){throw 'Fresh shell required for the pinned actual Win32 regression.'}
Add-Type -Path $SourcePath
$result=[IW7.BootProof.KernelImageAliasRegression]::Run()
if(!$result.KernelStayedOriginal -or !$result.ModuleAliasObserved -or !$result.Restored -or !$result.InsufficientCapacityRefused -or
    $result.InsufficientCapacityError -ne 122 -or $result.GameLaunched -or $result.OtherProcessWritten -or $result.ImageFileWritten){throw 'Kernel image identity regression failed.'}
Write-Output 'Actual Win32 kernel/main-module alias regression PASS; metadata restored; insufficient capacity rejected.'
$result
