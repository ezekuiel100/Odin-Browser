# Snapshot oficial fixado por SHA, sem excluir features ou modos.
# -PerDir 0 seleciona todos os testes. Use diretorio novo a cada revisao.
param(
    [ValidateRange(0, 100000)][int]$PerDir = 5,
    [string[]]$Only = @('language', 'built-ins', 'annexB'),
    [string]$Revision = 'main',
    [string]$OutDir = '_local/test262-expanded'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
$fetchArgs = @((Join-Path $PSScriptRoot 'test262-fetch.py'), '--revision', $Revision,
    '--out', $OutDir, '--cache', (Join-Path $root '_local/test262-cache'),
    '--per-dir', $PerDir, '--only') + $Only
& python @fetchArgs
exit $LASTEXITCODE
