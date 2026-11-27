# Real-font incremental geometry oracle and exact rendering comparison.
# Usage: .\geometry-check.ps1 [-Probe _local/builds/geometry-probe.exe]
# Output is retained under _local/geometry-check; no reference images are updated.
param([string]$Probe = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out = Join-Path $root '_local/geometry-check'
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (-not $Probe) {
    $Probe = Join-Path $root '_local/builds/geometry-probe.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $Probe -Parent) | Out-Null
    & C:/Odin/dist/odin.exe build (Join-Path $root 'tools/geometry-probe') "-out:$Probe" -o:speed '-extra-linker-flags:C:\Odin\dist\vendor\sdl2\SDL2.lib /STACK:1073741824'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif (-not [IO.Path]::IsPathRooted($Probe)) { $Probe = Join-Path $root $Probe }
Push-Location $root
try {
    foreach ($mode in @('incremental','full')) {
        # Windows PowerShell represents native stderr as error records, even
        # for successful diagnostic output. The process exit code is decisive.
        $ErrorActionPreference = 'Continue'
        & $Probe $mode $out *> (Join-Path $out "$mode.log")
        $probeExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($probeExit -ne 0) { Get-Content (Join-Path $out "$mode.log"); exit 1 }
        if (-not (Select-String -Path (Join-Path $out "$mode.log") -SimpleMatch "DONE mode=$mode steps=16" -Quiet)) {
            Write-Host "FAIL: incomplete $mode probe"; exit 1
        }
    }
} finally { Pop-Location }

# stb emits deterministic PNGs without changing metadata. Equal encoded bytes
# prove pixel equality; different images fail conservatively, with no fuzzy budget.
$pass = 0; $fail = 0; $changed = 0
for ($step = 0; $step -lt 16; $step++) {
    $a = Join-Path $out "incremental-$step.png"
    $b = Join-Path $out "full-$step.png"
    if (-not (Test-Path $a) -or -not (Test-Path $b)) { Write-Host "FAIL step $step (missing image)"; $fail++; continue }
    $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
    $hb = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
    if ($ha -eq $hb) { Write-Host "PASS step $step (identical PNG)"; $pass++ }
    else { Write-Host "FAIL step $step (different PNG)"; $fail++ }
    if ($step -gt 0) {
        $prev = (Get-FileHash -LiteralPath (Join-Path $out "incremental-$($step-1).png") -Algorithm SHA256).Hash
        if ($ha -ne $prev) { $changed++ }
    }
}
if ($changed -lt 8) { Write-Host "FAIL: mutations changed only $changed images"; $fail++ }
Write-Host "geometry-check: $pass PASS / $fail FAIL; $changed visible state changes"
if ($fail -gt 0) { exit 1 }
exit 0
