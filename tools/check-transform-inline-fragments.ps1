param([string]$Browser = ".\browser.exe")
$ErrorActionPreference="Stop"
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
$png=Join-Path $out "inline-fragments.png"
& $Browser --render (Join-Path $root "tests/paint/transforms-inline-fragments.html") $png 600 400 590 390 5
if ($LASTEXITCODE -ne 0) { throw "render failed" }
$b=New-Object System.Drawing.Bitmap $png
try {
    $checks=@(@("wrapped nested inline union",40),@("coalesced word retains inner span geometry",80),@("intra-word splits retain source offsets",120),@("inline rectangles follow ancestor rotation",160))
    foreach ($check in $checks) {
        $p=$b.GetPixel($check[1],360)
        if ($p.G -ne 128 -or $p.R -ne 0 -or $p.B -ne 0) { throw "FAIL $($check[0]): $p" }
        Write-Host "PASS $($check[0])"
    }
} finally { $b.Dispose() }
