param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "eye-clip.png"
& $Browser --render (Join-Path $root "tests/paint/transforms-eye-clip.html") $png 860 380 0 0 3
if ($LASTEXITCODE -ne 0) { throw "Render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$fails = 0
$checks = @(
    @("eye-plane crossing keeps visible red surface", 170, 90, 255, 0, 0),
    @("red surface remains continuous across triangle seam", 50, 40, 255, 0, 0),
    @("red surface respects projected edge", 245, 90, 238, 238, 238),
    @("eye-plane crossing keeps visible blue surface", 420, 90, 0, 0, 255),
    @("blue surface respects projected edge", 310, 90, 238, 238, 238),
    @("fully behind plane is discarded", 120, 270, 238, 238, 238),
    @("perspective property keeps crossing descendant", 450, 270, 0, 0, 255),
    @("perspective property retains projected edge", 530, 270, 238, 238, 238),
    @("overflow clip still contains projected surface", 290, 270, 255, 255, 255),
    @("later geometry survives rebuilt buffers", 590, 210, 0, 128, 0),
    @("preserve-3d root finishes clipping without its own transform", 730, 90, 0, 0, 255)
)
try {
    foreach ($check in $checks) {
        $p = $bmp.GetPixel($check[1], $check[2])
        if ([Math]::Abs($p.R-$check[3]) -le 5 -and [Math]::Abs($p.G-$check[4]) -le 5 -and [Math]::Abs($p.B-$check[5]) -le 5) { Write-Host "PASS $($check[0])" }
        else { $fails++; Write-Host "FAIL $($check[0]): $p" }
    }
} finally { $bmp.Dispose() }
Write-Host "$($checks.Count-$fails) PASS / $fails FAIL"
if ($fails) { exit 1 }
