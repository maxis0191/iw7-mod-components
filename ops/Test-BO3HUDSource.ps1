param([string]$Python='python',[string]$LuaRuntime)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(!$LuaRuntime){
    $cache=Join-Path $root 'runtime/bo3-hud-lua51-test'
    [IO.Directory]::CreateDirectory($cache)|Out-Null
    $wheel=Join-Path $cache 'lupa-2.6-cp312-cp312-win_amd64.whl'
    $hash='C735A1CE8EE60EDB0FE71D665F1E6B7C55C6021F1D340EB8C865952C602CD36F'
    $version=& $Python -c 'import sys; print("%d.%d" % sys.version_info[:2])'
    if($LASTEXITCODE -or $version.Trim() -cne '3.12'){throw 'Pinned Lua source test wheel requires Windows x64 CPython3.12.'}
    if(!(Test-Path -LiteralPath $wheel)){
        Invoke-WebRequest -Uri 'https://files.pythonhosted.org/packages/b8/15/5121e68aad3584e26e1425a5c9a79cd898f8a152292059e128c206ee817c/lupa-2.6-cp312-cp312-win_amd64.whl' -OutFile $wheel
    }
    if((Get-FileHash -LiteralPath $wheel).Hash -cne $hash){throw 'Official Lupa2.6 wheel bytes changed; preserve cache.'}
    $LuaRuntime=Join-Path $cache 'site'
    if(!(Test-Path -LiteralPath (Join-Path $LuaRuntime 'lupa/lua51.cp312-win_amd64.pyd'))){
        & $Python -m pip install --no-index --no-deps --target $LuaRuntime $wheel
        if($LASTEXITCODE){throw 'Pinned binary Lua test runtime install failed.'}
    }
}
& $Python -B (Join-Path $root 'tests/ops/bo3_zombies_hud_test.py') --lua-runtime $LuaRuntime
if($LASTEXITCODE){throw 'Authored Lua source controls failed; no runtime qualification.'}
