$ErrorActionPreference='Stop'
function ConvertTo-IW7CutsceneSource([string]$Path,[string]$Source) {
    $pch='#include <std_include.hpp>'
    if($Source.Contains('#include "../cutscene.hpp"')){throw 'Cutscene overlay already present.'}
    if($Source.Split([string[]]@($pch),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned cutscene include marker changed.'}
    $Source=$Source.Replace($pch,$pch+"`n"+'#include "../cutscene.hpp"')
    switch($Path){
        'gsc/script_extension.cpp' {
            $marker="`tnamespace function`n`t{"
            $Source=$Source.Replace("`r`n","`n")
            if($Source.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned VM redirect namespace changed.'}
            return $Source.Replace($marker,"`tvoid redirect_code(const char* from,const char* to) { vm_execute_hooks[from]=to; }`n`n"+$marker)
        }
        'gsc/script_loading.cpp' {
            $marker='return game::DB_FindXAssetHeader(type, name, allow_create_default).scriptfile;'
            if($Source.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Pinned unlinked ScriptFile observation marker changed.'}
            return $Source.Replace($marker,'auto* original = game::DB_FindXAssetHeader(type, name, allow_create_default).scriptfile;'+"`n`t`t"+'cutscene::observe_script(real_name, original);'+"`n`t`treturn original;")
        }
        default{throw 'Unowned cutscene overlay path.'}
    }
}
function Remove-IW7CutsceneOverlay([string]$NativeRoot){
    $receiptPath=Join-Path $NativeRoot 'cutscene-overlay.local.json'
    if(!(Test-Path -LiteralPath $receiptPath)){return}
    $r=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    $allowed=@('gsc/script_extension.cpp','gsc/script_loading.cpp','cutscene.cpp','cutscene.hpp','cutscene_policy.hpp')
    if($r.Schema -cne 'iw7.cutscene-overlay/1' -or $r.Root -cne [IO.Path]::GetFullPath($NativeRoot) -or @($r.Files).Count -ne $allowed.Count){throw 'Invalid cutscene overlay receipt.'}
    $seen=@{}
    foreach($f in $r.Files){
        if($f.Name -cnotin $allowed -or $seen.ContainsKey($f.Name)){throw 'Unowned/duplicate cutscene overlay path.'}
        $seen[$f.Name]=$true
        $p=Join-Path $NativeRoot ('src/client/component/'+$f.Name)
        if(!(Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p).Hash -cne $f.AfterSHA256){throw 'Changed cutscene overlay; preserve source and receipt.'}
        if($f.Name.StartsWith('gsc/') -and !$f.Before){throw 'Missing original cutscene overlay bytes.'}
    }
    foreach($f in $r.Files){
        $p=Join-Path $NativeRoot ('src/client/component/'+$f.Name)
        if($f.Before){[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String($f.Before))}else{Remove-Item -LiteralPath $p}
    }
    Remove-Item -LiteralPath $receiptPath
}
function Add-IW7CutsceneOverlay([string]$NativeRoot,[string]$SourceRoot){
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $receiptPath=Join-Path $root 'cutscene-overlay.local.json'
    if(Test-Path -LiteralPath $receiptPath){throw 'Remove qualified cutscene overlay before reapplying.'}
    $files=@()
    foreach($name in @('gsc/script_extension.cpp','gsc/script_loading.cpp')){
        $p=Join-Path $root ('src/client/component/'+$name)
        $before=[IO.File]::ReadAllBytes($p)
        $after=ConvertTo-IW7CutsceneSource $name ([Text.Encoding]::UTF8.GetString($before))
        $files+=@{Name=$name;Before=[Convert]::ToBase64String($before);Bytes=[Text.UTF8Encoding]::new($false).GetBytes($after)}
    }
    foreach($name in @('cutscene.cpp','cutscene.hpp','cutscene_policy.hpp')){
        if(Test-Path -LiteralPath (Join-Path $root ('src/client/component/'+$name))){throw 'Unowned cutscene translation unit.'}
        $files+=@{Name=$name;Before=$null;Bytes=[IO.File]::ReadAllBytes((Join-Path $SourceRoot ('src/native/'+$name)))}
    }
    $rows=@($files|ForEach-Object{@{Name=$_.Name;Before=$_.Before;AfterSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($_.Bytes))}})
    $r=@{Schema='iw7.cutscene-overlay/1';Root=$root;Files=$rows}
    $r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
    foreach($f in $files){[IO.File]::WriteAllBytes((Join-Path $root ('src/client/component/'+$f.Name)),$f.Bytes)}
    $r
}
