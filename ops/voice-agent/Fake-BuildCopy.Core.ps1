 . "$PSScriptRoot/../Base-Client.Core.ps1"
function Set-IW7FakeCaptureBuildCopy([string]$RepoRoot,[string]$NativeRoot,[bool]$Enabled) {
    $names=@('voice_test_capture.cpp','voice_test_capture.hpp','paris_voice_test_capture.cpp','paris_voice_test_capture.hpp','voice_test_binding.hpp','voice_capture_wire.hpp')
    $prepared=@()
    foreach($name in $names){
        $source=Resolve-IW7BasePath $RepoRoot ('src/native/'+$name)
        $target=Resolve-IW7BasePath $NativeRoot ('src/client/component/'+$name)
        $bytes=[IO.File]::ReadAllBytes($source)
        $sourceHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if($name -ceq 'voice_test_capture.cpp'){
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            if(!$text.StartsWith('#include "voice_test_capture.hpp"')){throw 'Exact fake COM standalone source prefix required.'}
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes("#include <std_include.hpp>`n#pragma comment(lib, `"bcrypt.lib`")`n#pragma comment(lib, `"dxguid.lib`")`n"+$text)
        }
        $copiedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if(Test-Path -LiteralPath $target){
            if((Get-FileHash -LiteralPath $target).Hash -cnotin @($sourceHash,$copiedHash)){throw 'Unknown fake capture overlay; preserve it.'}
        }
        $prepared+=[pscustomobject]@{Name=$name;Target=$target;Bytes=$bytes;SourceSHA256=$sourceHash;CopiedSHA256=$copiedHash}
    }
    # Validate every source/target before the first copy/remove; no recursive IO.
    foreach($row in $prepared){
        if($Enabled){[IO.File]::WriteAllBytes($row.Target,$row.Bytes)}
        elseif(Test-Path -LiteralPath $row.Target){Remove-Item -LiteralPath $row.Target}
    }
    [pscustomobject]@{Compiled=$Enabled;Files=$(if($Enabled){$names}else{@()});Copies=@($prepared|Select-Object Name,SourceSHA256,CopiedSHA256);Activation='explicit fake flag only; Prepared silence before protected relay v2 ARM'}
}
