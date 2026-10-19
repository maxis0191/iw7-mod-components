$ErrorActionPreference='Stop'
function ConvertTo-IW7OwnerCheatsSource([string]$Path,[string]$Source) {
    $include='#include "owner_cheats.hpp"'
    if($Source.Contains($include)){throw 'Owner cheats overlay already present in unqualified source.'}
    $pch='#include <std_include.hpp>'
    if($Source.Split([string[]]@($pch),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned precompiled-header marker changed.'}
    $Source=$Source.Replace($pch,$pch+"`n"+$include)
    switch($Path) {
        'command.cpp' {
            $marker='if (!game::shared::cheats_ok(client_num, true))'
            $count=$Source.Split([string[]]@($marker),[StringSplitOptions]::None).Count-1
            if($count -ne 10){throw "Expected ten native per-client cheat checks; found $count."}
            return $Source.Replace($marker,'if (!owner_cheats::server_allowed(client_num) && !game::shared::cheats_ok(client_num, true))')
        }
        'dvar_cheats.cpp' {
            $marker='(!game::shared::cheats_ok() && *game::isCheatOverride)'
            if($Source.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned local cheat-dvar gate changed.'}
            return $Source.Replace($marker,'(!owner_cheats::client_allowed() && !game::shared::cheats_ok() && *game::isCheatOverride)')
        }
        'auth.cpp' {
            $marker='game::SV_ClientMP_DirectConnect(from);'
            if($Source.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned direct-connect invalidation marker changed.'}
            return $Source.Replace($marker,"owner_cheats::invalidate(from);`n`t`t`t"+$marker)
        }
        default {throw 'Unowned native overlay path.'}
    }
}
function Remove-IW7OwnerCheatsOverlay([string]$NativeRoot) {
    $receiptPath=Join-Path $NativeRoot 'owner-cheats-overlay.local.json'
    if(!(Test-Path -LiteralPath $receiptPath)){return}
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    if($receipt.Schema -cne 'iw7.owner-cheats-overlay/1' -or $receipt.Root -cne [IO.Path]::GetFullPath($NativeRoot)){throw 'Invalid owner-cheats overlay receipt.'}
    $allowed=@('command.cpp','auth.cpp','dvar_cheats.cpp','owner_cheats.cpp','owner_cheats.hpp','owner_cheats_policy.hpp','owner_cheats_crypto.hpp')
    if(@($receipt.Files).Count -ne $allowed.Count){throw 'Incomplete owner-cheats overlay receipt.'}
    $seen=@{}
    foreach($row in $receipt.Files){
        if($row.Name -cnotin $allowed -or $seen.ContainsKey($row.Name)){throw 'Unowned/duplicate owner-cheats overlay path.'}
        $seen[$row.Name]=$true
        $path=Join-Path $NativeRoot ('src/client/component/'+$row.Name)
        if(!(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -cne $row.AfterSHA256){throw 'Changed owner-cheats overlay; preserve source and receipt.'}
        if($row.Name -cin @('command.cpp','auth.cpp','dvar_cheats.cpp') -and !$row.Before){throw 'Missing original native overlay bytes.'}
    }
    foreach($row in $receipt.Files){
        $path=Join-Path $NativeRoot ('src/client/component/'+$row.Name)
        if($row.Before){[IO.File]::WriteAllBytes($path,[Convert]::FromBase64String($row.Before))}else{Remove-Item -LiteralPath $path}
    }
    Remove-Item -LiteralPath $receiptPath
}
function Add-IW7OwnerCheatsOverlay([string]$NativeRoot,[string]$SourceRoot) {
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $receiptPath=Join-Path $root 'owner-cheats-overlay.local.json'
    if(Test-Path -LiteralPath $receiptPath){throw 'Remove the qualified owner-cheats overlay before reapplying.'}
    $files=@()
    foreach($name in @('command.cpp','auth.cpp','dvar_cheats.cpp')){
        $path=Join-Path $root ('src/client/component/'+$name)
        $before=[IO.File]::ReadAllBytes($path)
        $after=ConvertTo-IW7OwnerCheatsSource $name ([Text.Encoding]::UTF8.GetString($before))
        $files+=@{Name=$name;Before=[Convert]::ToBase64String($before);Bytes=[Text.UTF8Encoding]::new($false).GetBytes($after)}
    }
    foreach($name in @('owner_cheats.cpp','owner_cheats.hpp','owner_cheats_policy.hpp','owner_cheats_crypto.hpp')){
        $path=Join-Path $root ('src/client/component/'+$name)
        if(Test-Path -LiteralPath $path){throw 'Unowned owner-cheats translation unit; preserve it.'}
        $files+=@{Name=$name;Before=$null;Bytes=[IO.File]::ReadAllBytes((Join-Path $SourceRoot ('src/native/'+$name)))}
    }
    # All inputs are validated before the first write; retain restoration bytes.
    $rows=@($files|ForEach-Object{@{Name=$_.Name;Before=$_.Before;AfterSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($_.Bytes))}})
    $receipt=@{Schema='iw7.owner-cheats-overlay/1';Root=$root;Files=$rows}
    $receipt|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
    foreach($file in $files){[IO.File]::WriteAllBytes((Join-Path $root ('src/client/component/'+$file.Name)),$file.Bytes)}
    $receipt
}
