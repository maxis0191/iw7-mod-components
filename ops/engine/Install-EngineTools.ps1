<#
.SYNOPSIS
Installs the engine command and its MCP server into the RE lab (a stable path outside any worktree) and
registers the MCP server for Claude Code at user scope, so every agent can call it.

  pwsh -File ops/engine/Install-EngineTools.ps1            # copy + register
  pwsh -File ops/engine/Install-EngineTools.ps1 -NoRegister

The knowledge file stays in the repository: the installed command reads and writes
<repository>/ops/engine/knowledge/engine-knowledge.json of the checkout given by -KnowledgeRepo (default: this
checkout), through the IW7_ENGINE_KNOWLEDGE environment variable set in the registration.
#>
param(
    [string]$Lab = (Join-Path $env:USERPROFILE 'Documents\IW7-RE-Lab'),
    [string]$KnowledgeRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$Python = (Get-Command python -ErrorAction Stop).Source,
    [switch]$NoRegister
)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $Lab 'engine\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
foreach ($f in 'engine.py','engine_mcp.py') { Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $bin $f) -Force }
$knowledge = Join-Path $KnowledgeRepo 'ops\engine\knowledge\engine-knowledge.json'
& $Python -c "import capstone" 2>$null
if ($LASTEXITCODE) { throw "$Python lacks capstone: python -m pip install capstone" }
Write-Host "installed engine.py and engine_mcp.py in $bin; knowledge file $knowledge"
if (!$NoRegister) {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (!$claude) { Write-Warning 'claude CLI not found: register by hand (docs/ENGINE.md)'; return }
    & claude mcp remove --scope user iw7-engine 2>$null | Out-Null
    & claude mcp add --scope user -e "IW7_ENGINE_KNOWLEDGE=$knowledge" iw7-engine -- $Python -I (Join-Path $bin 'engine_mcp.py')
    Write-Host 'registered MCP server iw7-engine (user scope); new sessions see its tools'
}
