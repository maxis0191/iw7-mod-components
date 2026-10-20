$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/agent-capacity/Peer-Overlay.Core.ps1"
function Reject([scriptblock]$Body){$caught=$false;try{& $Body|Out-Null}catch{$caught=$true};if(!$caught){throw 'Expected peer overlay refusal.'}}
$auth=@'
#include <std_include.hpp>
void connect_client() {
    utils::info_string info_string{ std::string{params[2]} };
    game::dvar_t* password = game::Dvar_FindVar("password");
}
void connect_server() {
    if (steam_id.empty() || challenge.empty()) { return; }
    owner_cheats::invalidate(from);
    game::SV_ClientMP_DirectConnect(from);
}
'@
$party=@'
#include <std_include.hpp>
void response() {
    info.set("protocol", utils::string::va("%i", PROTOCOL));
    if (info.get("challenge") != expected) { return; }
    const auto gamename = info.get("gamename");
}
'@
$a=ConvertTo-IW7CapacityPeerSource 'auth.cpp' $auth
$p=ConvertTo-IW7CapacityPeerSource 'party.cpp' $party
if($a.IndexOf('compatible_peer') -gt $a.IndexOf('owner_cheats::invalidate(from);') -or
   !$a.Contains('owner_cheats::invalidate(from);') -or
   !$a.Contains('info_string.set("paris_capacity"') -or
   $p.IndexOf('compatible_peer') -lt $p.IndexOf('info.get("challenge")') -or
   $p.IndexOf('compatible_peer') -gt $p.IndexOf('const auto gamename') -or
   !$p.Contains('info.set("protocol", utils::string::va("%i", PROTOCOL));')){throw 'Admission ordering or standard protocol changed.'}
Reject {ConvertTo-IW7CapacityPeerSource 'auth.cpp' $a}
Reject {ConvertTo-IW7CapacityPeerSource 'party.cpp' ($party+$party)}
Reject {ConvertTo-IW7CapacityPeerSource 'other.cpp' $auth}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-capacity-peer-'+[guid]::NewGuid().ToString('N'))
$component=Join-Path $root 'src/client/component';[IO.Directory]::CreateDirectory($component)|Out-Null
try{
    [IO.File]::WriteAllText("$component/auth.cpp",$auth)
    [IO.File]::WriteAllText("$component/party.cpp",'missing marker')
    $original=(Get-FileHash "$component/auth.cpp").Hash
    Reject {Add-IW7CapacityPeerOverlay $root}
    if((Get-FileHash "$component/auth.cpp").Hash -cne $original -or (Test-Path "$root/capacity-peer-overlay.local.json")){throw 'Preflight failure mutated the first source.'}
    [IO.File]::WriteAllText("$component/party.cpp",$party)
    $partyOriginal=(Get-FileHash "$component/party.cpp").Hash
    $receipt=Add-IW7CapacityPeerOverlay $root
    $partyAfter=(Get-FileHash "$component/party.cpp").Hash
    [IO.File]::AppendAllText("$component/auth.cpp",'foreign change')
    Reject {Remove-IW7CapacityPeerOverlay $root}
    if((Get-FileHash "$component/party.cpp").Hash -cne $partyAfter){throw 'Foreign first-source edit caused partial restoration.'}
    [IO.File]::WriteAllBytes("$component/auth.cpp",[Convert]::FromBase64String(($receipt.Files|Where-Object Name -CEQ 'auth.cpp').Before))
    Remove-IW7CapacityPeerOverlay $root
    if((Get-FileHash "$component/auth.cpp").Hash -cne $original -or (Get-FileHash "$component/party.cpp").Hash -cne $partyOriginal -or (Test-Path "$root/capacity-peer-overlay.local.json")){throw 'Partial-application recovery changed original bytes.'}
    Add-IW7CapacityPeerOverlay $root|Out-Null
    Remove-IW7CapacityPeerOverlay $root
    if((Get-FileHash "$component/auth.cpp").Hash -cne $original -or (Get-FileHash "$component/party.cpp").Hash -cne $partyOriginal){throw 'Normal round trip changed original bytes.'}
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(!$resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^iw7-capacity-peer-[0-9a-f]{32}$'){throw 'Temporary cleanup boundary differs.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Capacity peer admission overlay: ordering, legacy protocol preservation, preflight, foreign edits and byte-exact restoration PASS. No game or network.'
