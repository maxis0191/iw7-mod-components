param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(![IO.Path]::IsPathFullyQualified($OutputDirectory) -or (Test-Path -LiteralPath $OutputDirectory)){throw 'A fresh absolute output directory is required.'}
$root=[IO.Path]::GetFullPath($OutputDirectory)
$cursor=Split-Path $root -Parent
while($cursor){
    if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected key-kit ancestry refused.'}
    $parent=Split-Path $cursor -Parent;if($parent -eq $cursor){break};$cursor=$parent
}
[IO.Directory]::CreateDirectory($root)|Out-Null
$security=[Security.AccessControl.DirectorySecurity]::new()
$security.SetAccessRuleProtection($true,$false)
foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $root -AclObject $security
$owner=[Security.Cryptography.ECDsaCng]::new(256)
$server=[Security.Cryptography.ECDsaCng]::new(256)
try {
    $clientRoot=Join-Path $root 'client/iw7-mod/owner-cheats'
    $serverRoot=Join-Path $root 'server/iw7-mod/owner-cheats'
    [IO.Directory]::CreateDirectory($clientRoot)|Out-Null
    [IO.Directory]::CreateDirectory($serverRoot)|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $clientRoot 'client-private.blob'),$owner.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob))
    [IO.File]::WriteAllBytes((Join-Path $clientRoot 'trusted-server-public.blob'),$server.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob))
    [IO.File]::WriteAllBytes((Join-Path $serverRoot 'server-private.blob'),$server.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob))
    [IO.File]::WriteAllBytes((Join-Path $serverRoot 'owner-public.blob'),$owner.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob))
    Write-Output "Owner-only key kit prepared: $root"
} finally {$owner.Dispose();$server.Dispose()}
