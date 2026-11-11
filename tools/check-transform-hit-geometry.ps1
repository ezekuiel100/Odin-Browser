param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "hit-geometry.png"
& $Browser --render (Join-Path $root "tests/paint/transforms-hit-geometry.html") $png 500 250 120 110 5 0 0 1
if ($LASTEXITCODE -ne 0) { throw "Render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
try {
    foreach ($check in @(@("expanded hover",120,110),@("transformed DOM and ancestor bounds",60,170),@("expanded click",110,170))) {
        $p=$bmp.GetPixel($check[1],$check[2])
        if ($p.R -gt 5 -or [Math]::Abs($p.G-128) -gt 5 -or $p.B -gt 5) { throw "FAIL $($check[0]): $p" }
        Write-Host "PASS $($check[0])"
    }
} finally { $bmp.Dispose() }
