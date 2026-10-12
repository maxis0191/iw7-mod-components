param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
$ErrorActionPreference='Stop'
$path=Join-Path $NativeRoot 'src/client/component/network.cpp'
$base=(((git -C $NativeRoot show ($Commit+':src/client/component/network.cpp')) -join "`n").TrimEnd())+"`n"
if($LASTEXITCODE){throw 'Pinned network source unavailable.'}
$marker='const auto result = sendto(*game::query_socket, data, length, 0, &s, sizeof(sockaddr));'
$warning='console::warn("sendto failed: %s\n", std::system_category().message(GetLastError()).data());'
foreach($token in @($marker,$warning)){
    if($base.Split([string[]]@($token),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned UDP send marker changed.'}
}
$overlay=$base.Replace('#include <std_include.hpp>','#include <std_include.hpp>'+"`n"+'#include "paris_incident.hpp"')
$overlay=$overlay.Replace($marker,$marker+"`n`t`t`t"+'const auto send_error = result == SOCKET_ERROR ? WSAGetLastError() : 0;'+"`n`t`t`t"+'paris_incident::send_result(length, result, send_error, &s);'+"`n`t`t`t"+'if (result == SOCKET_ERROR) WSASetLastError(send_error);')
$overlay=$overlay.Replace($warning,'console::warn("sendto failed: %s\n", std::system_category().message(send_error).data());')
$current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
if($current -cne $base -and $current -cne $overlay){throw 'Unowned network edits; preserve and use an isolated source checkout.'}
[IO.File]::WriteAllText($path,$overlay,[Text.UTF8Encoding]::new($false))
# Reuse the upstream-owned detour. A second MinHook detour at SV_DropClient
# prevents startup, even though the first detour itself installs successfully.
$dropPath=Join-Path $NativeRoot 'src/client/component/patches.cpp'
$dropBase=(((git -C $NativeRoot show ($Commit+':src/client/component/patches.cpp')) -join "`n").TrimEnd())+"`n"
if($LASTEXITCODE){throw 'Pinned drop owner source unavailable.'}
$dropMarker="void sv_drop_client_stub(game::client_t* client, const char* reason, bool tellThem)`n`t`t{"
if($dropBase.Split([string[]]@($dropMarker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned existing drop stub changed.'}
$dropOverlay=$dropBase.Replace('#include <std_include.hpp>','#include <std_include.hpp>'+"`n"+'#include "paris_incident.hpp"').Replace($dropMarker,$dropMarker+"`n`t`t`t"+'paris_incident::client_drop(client, reason, tellThem);')
$legacyDropOverlay=$dropOverlay
$ackMarker='__int64 reliable_acknowledge = msg_readlong_hook.invoke<__int64>(msg);'
if($dropBase.Split([string[]]@($ackMarker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned ACK guard changed.'}
$dropOverlay=$dropOverlay.Replace($ackMarker,$ackMarker+"`n`t`t`t`t"+'paris_incident::reliable_ack(reliable_acknowledge);')
$dropCurrent=[IO.File]::ReadAllText($dropPath).Replace("`r`n","`n").TrimEnd()+"`n"
if($dropCurrent -cne $dropBase -and $dropCurrent -cne $dropOverlay -and $dropCurrent -cne $legacyDropOverlay){throw 'Unowned drop owner edits; preserve them.'}
[IO.File]::WriteAllText($dropPath,$dropOverlay,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{File='src/client/component/network.cpp';SHA256=(Get-FileHash $path).Hash;DropSHA256=(Get-FileHash $dropPath).Hash;ReturnValuesUnchanged=$true}
