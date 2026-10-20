$ErrorActionPreference='Stop'
function ConvertTo-IW7AutoCapacitySource([string]$Path,[string]$Source) {
    if($Source.Contains('auto_capacity.hpp')){throw 'Automatic profile overlay already present.'}
    $Source=$Source.Replace("`r`n","`n")
    $replace={param($Text,$Before,$After)
        if($Text.Split([string[]]@($Before),[StringSplitOptions]::None).Count -ne 2){throw "Automatic profile marker changed: $Path"}
        $Text.Replace($Before,$After)
    }
    if($Path -ceq 'src/common/utils/properties.cpp') {
        if($Source.Contains('paris-auto-managed-data')){throw 'Managed data override already present.'}
        $Source=& $replace $Source '#include "properties.hpp"' ('#include "properties.hpp"'+"`n"+'#include "flags.hpp"')
        $guard=@'
std::filesystem::path get_appdata_path()
	{
        if (utils::flags::has_flag("paris-auto-managed-data")) {
            wchar_t id[65]{};
            if (GetEnvironmentVariableW(L"IW7_AUTO_DATA_ID",id,65)!=64) throw std::runtime_error("Managed client data identity missing");
            for (unsigned i=0;i<64;++i) if (!((id[i]>=L'0' && id[i]<=L'9') || (id[i]>=L'A' && id[i]<=L'F'))) throw std::runtime_error("Invalid managed client data identity");
            static const auto managed=std::filesystem::current_path()/"iw7-mod"/"server-profiles"/"community-data"/std::wstring(id,32);
            return managed;
        }
'@
        return & $replace $Source "std::filesystem::path get_appdata_path()`n`t{" $guard
    }
    $include=if($Path.StartsWith('src/client/component/')){'#include "auto_capacity.hpp"'}else{'#include "component/auto_capacity.hpp"'}
    $Source=& $replace $Source '#include <std_include.hpp>' ('#include <std_include.hpp>'+"`n"+$include)
    switch($Path) {
        'src/client/component/party.cpp' {
            return & $replace $Source 'if (!paris_agent_capacity::compatible_peer(info.get("paris_capacity")))' ('if (auto_capacity::switch_for_server(target,info)) return;'+"`n                "+'if (!paris_agent_capacity::compatible_peer(info.get("paris_capacity")))')
        }
        'src/client/component/filesystem.cpp' {
            $Source=& $replace $Source 'const auto path = "iw7-mod/"s + game;' 'const std::string path = auto_capacity::player_directory();'
            return & $replace $Source 'std::filesystem::path(fs_basepath->current.string) / "iw7-mod" / "players2"' 'std::filesystem::path(fs_basepath->current.string) / auto_capacity::player_directory()'
        }
        'src/client/component/updater.cpp' {
            return & $replace $Source 'delete_old_file();' ('if (auto_capacity::managed_client()) return;'+"`n`t`t`t"+'delete_old_file();')
        }
        'src/client/main.cpp' {
            return & $replace $Source 'limit_parallel_dll_loading();' 'if (!auto_capacity::managed_client()) limit_parallel_dll_loading();'
        }
        default {throw 'Unowned automatic profile overlay path.'}
    }
}
function Set-IW7AutoCapacityOverlay([string]$NativeRoot,[string]$RepoRoot,[bool]$Enabled) {
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $paths=@('src/client/component/party.cpp','src/client/component/filesystem.cpp','src/client/component/updater.cpp','src/common/utils/properties.cpp','src/client/main.cpp')
    $names=@('auto_capacity.cpp','auto_capacity.hpp','auto_capacity_policy.hpp')
    $cursor=$root
    while($cursor){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected automatic profile source root refused.'}
        $parent=Split-Path $cursor -Parent;if($parent -eq $cursor){break};$cursor=$parent
    }
    $receipt=Join-Path $root 'auto-capacity-overlay.local.json'
    if(Test-Path -LiteralPath $receipt) {
        $r=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
        if($r.Schema -cne 'iw7.auto-capacity-overlay/1' -or $r.Root -cne $root -or @($r.Files).Count -ne 5 -or @($r.Added).Count -ne 3){throw 'Invalid automatic profile overlay receipt.'}
        $seen=@{}
        foreach($f in $r.Files){
            if($f.Path -cnotin $paths -or $seen.ContainsKey($f.Path)){throw 'Unowned or duplicate automatic profile path.'};$seen[$f.Path]=$true
            $before=[Convert]::FromBase64String($f.Before)
            if($before.Length -gt 1MB -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($before)) -cne $f.BeforeSHA256){throw 'Automatic profile original bytes changed.'}
            $target=Join-Path $root $f.Path
            if((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
               (Get-FileHash -LiteralPath $target).Hash -cnotin @($f.BeforeSHA256,$f.AfterSHA256)){throw 'Changed automatic profile source; preserve it.'}
        }
        foreach($f in $r.Added){
            if($f.Path -cnotin @($names|ForEach-Object{'src/client/component/'+$_}) -or $seen.ContainsKey($f.Path)){throw 'Unowned automatic component path.'};$seen[$f.Path]=$true
            $target=Join-Path $root $f.Path
            if((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $target).Hash -cne $f.SHA256)){throw 'Changed automatic profile component; preserve it.'}
        }
        foreach($f in $r.Files){[IO.File]::WriteAllBytes((Join-Path $root $f.Path),[Convert]::FromBase64String($f.Before))}
        foreach($f in $r.Added){if(Test-Path -LiteralPath (Join-Path $root $f.Path)){Remove-Item -LiteralPath (Join-Path $root $f.Path)}}
        Remove-Item -LiteralPath $receipt
    }
    if(!$Enabled){return}
    $files=@(foreach($path in $paths){
        $target=Join-Path $root $path;$before=[IO.File]::ReadAllBytes($target)
        $after=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-IW7AutoCapacitySource $path ([Text.Encoding]::UTF8.GetString($before))))
        @{Path=$path;Before=[Convert]::ToBase64String($before);BeforeSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($before));AfterSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($after));Bytes=$after}
    })
    $added=@(foreach($name in $names){
        $path='src/client/component/'+$name
        if(Test-Path -LiteralPath (Join-Path $root $path)){throw 'Existing unowned automatic profile component.'}
        @{Path=$path;Source=(Join-Path $RepoRoot ('src/native/'+$name));SHA256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot ('src/native/'+$name))).Hash}
    })
    $r=@{Schema='iw7.auto-capacity-overlay/1';Root=$root;Files=@($files|ForEach-Object{@{Path=$_.Path;Before=$_.Before;BeforeSHA256=$_.BeforeSHA256;AfterSHA256=$_.AfterSHA256}});Added=@($added|ForEach-Object{@{Path=$_.Path;SHA256=$_.SHA256}})}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($r|ConvertTo-Json -Depth 7))
    $stream=[IO.File]::Open($receipt,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    foreach($f in $files){[IO.File]::WriteAllBytes((Join-Path $root $f.Path),$f.Bytes)}
    foreach($f in $added){Copy-Item -LiteralPath $f.Source -Destination (Join-Path $root $f.Path)}
    $r
}
