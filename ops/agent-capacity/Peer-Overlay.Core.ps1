$ErrorActionPreference='Stop'
function ConvertTo-IW7CapacityPeerSource([string]$Path,[string]$Source) {
    if($Source.Contains('paris_agent_capacity.hpp')){throw 'Capacity peer overlay already present.'}
    $Source=$Source.Replace("`r`n","`n")
    $replace={param($Text,$Before,$After)
        if($Text.Split([string[]]@($Before),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned capacity peer marker changed.'}
        $Text.Replace($Before,$After)
    }
    $Source=& $replace $Source '#include <std_include.hpp>' ('#include <std_include.hpp>'+"`n"+'#include "paris_agent_capacity.hpp"')
    switch($Path){
        'auth.cpp' {
            $marker='game::dvar_t* password = game::Dvar_FindVar("password");'
            $Source=& $replace $Source $marker ('info_string.set("paris_capacity", paris_agent_capacity::wire_contract(paris_agent_capacity::installed()));'+"`n`t`t`t"+$marker)
            $marker='if (steam_id.empty() || challenge.empty())'
            $guard=@'
if (!paris_agent_capacity::compatible_peer(info_string.get("paris_capacity")))
            {
                network::send(*from,"error",paris_agent_capacity::installed() ?
                    "This server requires the Paris 48-zombie client update." :
                    "This server uses the standard client layout. Restart your client normally.",'\n');
                return;
            }
            if (steam_id.empty() || challenge.empty())
'@
            return & $replace $Source $marker $guard
        }
        'party.cpp' {
            $marker='info.set("protocol", utils::string::va("%i", PROTOCOL));'
            $Source=& $replace $Source $marker ($marker+"`n`t`t`t`t"+'info.set("paris_capacity", paris_agent_capacity::wire_contract(paris_agent_capacity::installed()));')
            $marker='const auto gamename = info.get("gamename");'
            $guard=@'
if (!paris_agent_capacity::compatible_peer(info.get("paris_capacity")))
                {
                    info_response_error(paris_agent_capacity::installed() ?
                        "This client is in Paris 48 mode. Restart normally to join this server." :
                        "This server requires the Paris 48-zombie client. Restart with the Paris 48 launcher.");
                    return;
                }
                const auto gamename = info.get("gamename");
'@
            return & $replace $Source $marker $guard
        }
        default {throw 'Unowned capacity peer path.'}
    }
}
function Remove-IW7CapacityPeerOverlay([string]$NativeRoot) {
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $path=Join-Path $root 'capacity-peer-overlay.local.json'
    if(!(Test-Path -LiteralPath $path)){return}
    $r=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    if($r.Schema -cne 'iw7.capacity-peer-overlay/1' -or $r.Root -cne $root -or @($r.Files).Count -ne 2){throw 'Invalid capacity peer receipt.'}
    $seen=@{}
    foreach($f in $r.Files){
        if($f.Name -cnotin @('auth.cpp','party.cpp') -or $seen.ContainsKey($f.Name)){throw 'Unowned or duplicate capacity peer file.'}
        $seen[$f.Name]=$true
        $before=[Convert]::FromBase64String($f.Before)
        if($before.Length -gt 1MB -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($before)) -cne $f.BeforeSHA256){throw 'Original capacity peer bytes differ.'}
        $target=Join-Path $root ('src/client/component/'+$f.Name)
        if(!(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -cnotin @($f.BeforeSHA256,$f.AfterSHA256)){throw 'Changed capacity peer source; preserve it.'}
    }
    foreach($f in $r.Files){[IO.File]::WriteAllBytes((Join-Path $root ('src/client/component/'+$f.Name)),[Convert]::FromBase64String($f.Before))}
    Remove-Item -LiteralPath $path
}
function Add-IW7CapacityPeerOverlay([string]$NativeRoot) {
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $path=Join-Path $root 'capacity-peer-overlay.local.json'
    if(Test-Path -LiteralPath $path){throw 'Remove the qualified capacity peer overlay before reapplying.'}
    $files=@()
    foreach($name in @('auth.cpp','party.cpp')){
        $target=Join-Path $root ('src/client/component/'+$name)
        $before=[IO.File]::ReadAllBytes($target)
        if($before.Length -gt 1MB){throw 'Capacity peer source exceeds its bound.'}
        $after=ConvertTo-IW7CapacityPeerSource $name ([Text.Encoding]::UTF8.GetString($before))
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($after)
        $files+=@{Name=$name;Before=[Convert]::ToBase64String($before);BeforeSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($before));AfterSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes));Bytes=$bytes}
    }
    $r=@{Schema='iw7.capacity-peer-overlay/1';Root=$root;Files=@($files|ForEach-Object{@{Name=$_.Name;Before=$_.Before;BeforeSHA256=$_.BeforeSHA256;AfterSHA256=$_.AfterSHA256}})}
    $out=[Text.UTF8Encoding]::new($false).GetBytes(($r|ConvertTo-Json -Depth 6));$stream=[IO.File]::Open($path,'CreateNew','Write','None')
    try{$stream.Write($out,0,$out.Length)}finally{$stream.Dispose()}
    foreach($f in $files){[IO.File]::WriteAllBytes((Join-Path $root ('src/client/component/'+$f.Name)),$f.Bytes)}
    $r
}
