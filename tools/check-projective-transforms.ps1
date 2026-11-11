param([string]$Browser = ".\_local\browser_xforms.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "projective.png"
& $Browser --render (Join-Path $root "tests/paint/transforms-projective.html") $png 800 500 0 0 3
if ($LASTEXITCODE -ne 0) { throw "Render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$fails = 0
$checks = @(
    @("perspective function expands plane", 135, 80, 255, 0, 0),
    @("perspective property expands child", 360, 100, 255, 0, 0),
    @("perspective origin keeps parent anchor", 245, 80, 255, 255, 255),
    @("near plane covers later far plane", 560, 100, 255, 0, 0),
    @("matrix animation decomposes rotation", 100, 400, 0, 255, 0),
    @("matrix animation keeps transformed center", 100, 355, 0, 255, 0),
    @("360-degree spin reaches half-turn", 350, 280, 0, 255, 0),
    @("spin leaves original position", 440, 320, 255, 255, 255),
    @("rotation transforms following translation", 580, 400, 0, 255, 0),
    @("rotation leaves old translation location", 620, 400, 255, 255, 255)
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
