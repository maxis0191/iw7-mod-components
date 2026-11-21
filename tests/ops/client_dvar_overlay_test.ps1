$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('iw7-clientdvar-'+[guid]::NewGuid().ToString('N'))
$path=Join-Path $temp 'src/client/component/patches.cpp'
# The pinned stub, as upstream has it (auroramod iw7-mod v1.1.0 and develop 78d1a0a, fork pin cfca45b).
$global:IW7ClientDvarPinned=@"
namespace patches
{
	namespace
	{
		void cg_set_client_dvar_from_server_stub(void* client_num, void* cgame_glob, const char* dvar_checksum, const char* value)
		{
			unsigned int checksum = static_cast<unsigned int>(atoi(dvar_checksum));
			auto* dvar = game::Dvar_FindMalleableVar(checksum);

			// register new dvar
			if (!dvar)
			{
				game::Dvar_SetFromStringByChecksum(checksum, value, game::DvarSetSource::DVAR_SOURCE_EXTERNAL);
			}
			// only set if dvar has no flags or has external flag
			else if (dvar->flags == game::DVAR_FLAG_NONE ||
				(dvar->flags & game::DVAR_FLAG_EXTERNAL) != 0)
			{
				game::Dvar_SetFromStringFromSource(dvar, value, game::DvarSetSource::DVAR_SOURCE_EXTERNAL);
			}
		}
	}
}
"@.Replace("`r`n","`n")
function git { $global:LASTEXITCODE=0; $global:IW7ClientDvarPinned }
try {
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
    [IO.File]::WriteAllText($path,$global:IW7ClientDvarPinned)
    $first=& "$repo/ops/Apply-ClientDvarOverlay.ps1" -NativeRoot $temp -Commit fixture
    $text=[IO.File]::ReadAllText($path)
    if(!$first.ExternalDvarRegisteredByChecksum){throw 'No result.'}
    if($text.Contains('Dvar_SetFromStringByChecksum(checksum')){throw 'The number is still passed where the engine reads text.'}
    if(!$text.Contains('invoke<game::dvar_t*>(0x140CEBDD0, checksum_text, checksum, game::DVAR_TYPE_STRING')){throw 'Not registered under the server checksum.'}
    if(!$text.Contains('if (created) game::Dvar_SetFromStringFromSource(created, value')){throw 'The new dvar is not set.'}
    if(!$text.Contains('console::info("[Paris dvar] registered from the server: checksum %u (%s)\n", checksum, dvar ? "ok" : "failed");')){throw 'No log line for a registered dvar.'}
    # The helper sits in the same anonymous namespace, before its only caller.
    if($text.IndexOf('game::dvar_t* paris_register_external_dvar(') -gt $text.IndexOf('void cg_set_client_dvar_from_server_stub(')){throw 'Helper after its caller.'}
    $second=& "$repo/ops/Apply-ClientDvarOverlay.ps1" -NativeRoot $temp -Commit fixture
    if($first.SHA256 -cne $second.SHA256){throw 'Repeated application changed the file.'}
    if(([IO.File]::ReadAllText($path).Split([string[]]@('paris_register_external_dvar('),[StringSplitOptions]::None).Count) -ne 3){throw 'Repeated application duplicated the helper.'}
    [IO.File]::AppendAllText($path,"// unrelated owner edit`n")
    $edited=[IO.File]::ReadAllText($path).Replace('if (created) game::','if (created && false) game::')
    [IO.File]::WriteAllText($path,$edited)
    $before=(Get-FileHash $path).Hash
    $rejected=$false
    try { & "$repo/ops/Apply-ClientDvarOverlay.ps1" -NativeRoot $temp -Commit fixture } catch {
        if($_ -notmatch 'Unowned client dvar edits'){throw}; $rejected=$true
    }
    if(!$rejected -or (Get-FileHash $path).Hash -cne $before){throw 'An edit of the overlay text was accepted.'}
    function git { $global:LASTEXITCODE=0; $global:IW7ClientDvarPinned.Replace('game::Dvar_SetFromStringByChecksum(checksum,','game::Dvar_SetFromStringByChecksum(dvar_checksum,') }
    $rejected=$false
    try { & "$repo/ops/Apply-ClientDvarOverlay.ps1" -NativeRoot $temp -Commit fixture } catch {
        if($_ -notmatch 'Pinned client dvar stub changed'){throw}; $rejected=$true
    }
    if(!$rejected -or (Get-FileHash $path).Hash -cne $before){throw 'A changed pin was accepted.'}
    'PASS: client dvar overlay (register under the server checksum), repeated application, owned-text refusal and changed-pin refusal.'
} finally {
    Remove-Item Function:\git
    # Only files created by this test; no recursive directory deletion.
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    foreach($relative in @('src/client/component','src/client','src','')){
        $directory=if($relative){Join-Path $temp $relative}else{$temp}
        if(Test-Path -LiteralPath $directory){[IO.Directory]::Delete($directory,$false)}
    }
}
