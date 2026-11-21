param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
# A dvar the server sets on a client that does not have it yet (setclientdvar of a name the client never registered).
# The server sends the decimal text of Dvar_GenerateChecksum(name). The pinned stub cg_set_client_dvar_from_server_stub
# (patches.cpp) then calls the engine's Dvar_SetFromStringByChecksum (0x140CECDB0) with the number, but that function
# takes the checksum as text (its first call is atoi): the number is read as a pointer and the client stops with an
# access violation at iw7_ship.exe+0x12C6DAF (21 Nov 2026: 10 of 10 lab dumps, maxis_dj 0x18AB14DA and maxis_name
# 0x9C7F72B5 sent to a client at Maxis UI tier 1). Passing the text would not be enough: that function registers a
# missing dvar under the checksum of the text, a dvar no name finds. Dvar_FindVar(name) is
# Dvar_FindMalleableVar(Dvar_GenerateChecksum(name)), so the dvar is registered here under the server's checksum
# (Dvar_RegisterVariant 0x140CEBDD0, external string, the engine's own flags and description) and then set: the
# client's code reads it by its real name (Lua Engine.GetDvarString("maxis_dj")).
# Runs after Apply-IncidentOverlay.ps1, which owns the rest of patches.cpp; the tree is reset to the pin before every build.
$ErrorActionPreference='Stop'
$relative='src/client/component/patches.cpp'
$path=Join-Path $NativeRoot $relative
$base=(((git -C $NativeRoot show ($Commit+':'+$relative)) -join "`n").TrimEnd())+"`n"
if($LASTEXITCODE){throw 'Pinned patches source unavailable.'}
$stub="void cg_set_client_dvar_from_server_stub(void* client_num, void* cgame_glob, const char* dvar_checksum, const char* value)"
$call="game::Dvar_SetFromStringByChecksum(checksum, value, game::DvarSetSource::DVAR_SOURCE_EXTERNAL);"
foreach($token in @($stub,$call)){
    if($base.Split([string[]]@($token),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned client dvar stub changed.'}
}
$helper=@(
    "// Paris: register a dvar the server sets before the client has it, under the server's checksum (Apply-ClientDvarOverlay.ps1).",
    "`t`tgame::dvar_t* paris_register_external_dvar(const unsigned int checksum, const char* checksum_text)",
    "`t`t{",
    "`t`t`tgame::DvarValue value{};",
    "`t`t`tvalue.string = `"`";",
    "`t`t`tgame::DvarLimits domain{};",
    "`t`t`t// Dvar_RegisterVariant: name (read only by its error messages), checksum, type, flags, value, domain, description.",
    "`t`t`treturn utils::hook::invoke<game::dvar_t*>(0x140CEBDD0, checksum_text, checksum, game::DVAR_TYPE_STRING,",
    "`t`t`t`tstatic_cast<unsigned int>(game::DVAR_FLAG_EXTERNAL), &value, &domain, `"External Dvar`");",
    "`t`t}",
    "",
    "`t`t") -join "`n"
$fixed=@(
    "auto* created = paris_register_external_dvar(checksum, dvar_checksum);",
    "`t`t`t`tif (created) game::Dvar_SetFromStringFromSource(created, value, game::DvarSetSource::DVAR_SOURCE_EXTERNAL);") -join "`n"
$current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
if($current.Contains('paris_register_external_dvar(')){
    # Already applied to this tree (a repeated run without a reset): the text must be exactly what this script writes.
    $previous=$current.Replace($fixed,$call).Replace($helper+$stub,$stub)
    if($previous.Split([string[]]@($call),[StringSplitOptions]::None).Count -ne 2 -or $previous.Contains('paris_register_external_dvar')){throw 'Unowned client dvar edits; preserve them.'}
    $current=$previous
}
foreach($token in @($stub,$call)){
    if($current.Split([string[]]@($token),[StringSplitOptions]::None).Count -ne 2){throw 'Unowned client dvar edits; preserve them.'}
}
$overlay=$current.Replace($stub,$helper+$stub).Replace($call,$fixed)
[IO.File]::WriteAllText($path,$overlay,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{File=$relative;SHA256=(Get-FileHash $path).Hash;ExternalDvarRegisteredByChecksum=$true}
