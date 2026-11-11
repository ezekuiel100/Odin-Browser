param([string]$Browser = ".\browser.exe")
$ErrorActionPreference="Stop"
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
$png=Join-Path $out "dom-projection.png"
& $Browser --render (Join-Path $root "tests/paint/transforms-dom-projection.html") $png 320 100 310 90 5
if ($LASTEXITCODE -ne 0) { throw "render failed" }
$b=New-Object System.Drawing.Bitmap $png
try {
    $checks=@(@("DOM projects corners on both sides of the eye plane",30),@("DOM retains behind-camera border box",70),@("zero W keeps box and client rect",110),@("small positive W divides coordinates",150),@("small negative W divides coordinates",190),@("zero W keeps inline fragment geometry",230),@("individual zero-W corners contribute to bounds",270))
    foreach ($check in $checks) {
        $p=$b.GetPixel($check[1],30)
        if ($p.G -ne 128 -or $p.R -ne 0 -or $p.B -ne 0) { throw "FAIL $($check[0]): $p" }
        Write-Host "PASS $($check[0])"
    }
} finally { $b.Dispose() }
