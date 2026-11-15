$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Build-Voice removes the capacity family of sources that the checkout does not own from a kept native tree (a47): runs the block on a temp tree.
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$text=[IO.File]::ReadAllText((Join-Path $root 'ops/Build-Voice.ps1'))
$start=$text.IndexOf('$staleSources = @()',[StringComparison]::Ordinal)
$end=$text.IndexOf('Push-Location $root',$start,[StringComparison]::Ordinal)
if($start -lt 0 -or $end -lt $start){throw 'The stale source block of Build-Voice was not found.'}
$block=$text.Substring($start,$end-$start)
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('bv-foreign-'+[guid]::NewGuid().ToString('N'))
try{
    $tree=Join-Path $tmp 'tree'; $repo=Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $tree 'src/client/component'),(Join-Path $repo 'src/native') | Out-Null
    git -C $tree init -q
    Set-Content -LiteralPath (Join-Path $tree 'src/client/component/script_variables_upstream.cpp') -Value 'tracked'
    git -C $tree add -A; git -C $tree -c user.name=t -c user.email=t@t commit -q -m t
    foreach($n in 'script_variables.cpp','script_variables.hpp','script_variables_sites.inc','agent_capacity_new_thing.inc','agent_capacity.cpp','paris_other.cpp'){ Set-Content -LiteralPath (Join-Path $tree "src/client/component/$n") -Value 'x' }
    Set-Content -LiteralPath (Join-Path $repo 'src/native/agent_capacity.cpp') -Value 'owned'
    $global:root=$tree; $global:repo=$repo
    $out=& ([scriptblock]::Create('$root=$global:root; $repo=$global:repo; '+$block))
    $left=@(Get-ChildItem -LiteralPath (Join-Path $tree 'src/client/component') -File | ForEach-Object Name | Sort-Object)
    $want=@('agent_capacity.cpp','paris_other.cpp','script_variables_upstream.cpp')
    if(($left -join ',') -cne ($want -join ',')){throw "Left: $($left -join ', '); wanted: $($want -join ', ')"}
    if(!("$out" -match 'Removed 4 source file')){throw "No removal line: $out"}
    # a second run removes nothing
    $again=& ([scriptblock]::Create('$root=$global:root; $repo=$global:repo; '+$block))
    if("$again" -match 'Removed'){throw 'A second run removed files again.'}
    'build_voice_foreign_sources_test: ok'
}finally{ Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
