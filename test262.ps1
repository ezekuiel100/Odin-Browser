# Test262: variantes isoladas, scripts/modulos/async e relatorio por teste.
param(
    [string]$Filter = '',
    [switch]$Verbose,
    [switch]$ShowThrow,
    [string]$Browser = '',
    [ValidateRange(1, 3600)][int]$TimeoutSec = 10,
    [string]$Suite = '',
    [ValidateRange(1, 32)][int]$Jobs = 4,
    [string]$Report = '_local/reports/test262-latest.json',
    [string]$Baseline = '',
    [switch]$Build
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Suite) {
    $expanded = Join-Path $root '_local/test262-expanded'
    $Suite = if (Test-Path (Join-Path $expanded 'manifest.json')) { $expanded } else { Join-Path $root 'tests/test262' }
}
if (-not $Browser) { $Build = $true }
if ($Build) {
    New-Item -ItemType Directory -Force (Join-Path $root '_local/builds') | Out-Null
    $Browser = Join-Path $root '_local/builds/test262.exe'
    & C:/Odin/dist/odin.exe build (Join-Path $root 'tools/js262') "-out:$Browser" -o:speed '-extra-linker-flags:/STACK:1073741824'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$runArgs = @((Join-Path $root 'tools/test262-run.py'), '--suite', $Suite, '--browser', $Browser,
    '--timeout', $TimeoutSec, '--jobs', $Jobs, '--report', $Report)
if ($Filter) { $runArgs += @('--filter', $Filter) }
if ($Baseline) { $runArgs += @('--baseline', $Baseline) }
if ($Verbose) { $runArgs += '--verbose' }
if ($ShowThrow) { $runArgs += '--show-throw' }
& python @runArgs
exit $LASTEXITCODE
