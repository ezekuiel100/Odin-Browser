param([string]$Browser = ".\browser.exe")
$ErrorActionPreference="Stop"
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root "_local/reports/transforms"
New-Item -ItemType Directory -Force $out | Out-Null
function Render($name,$mx,$my,$click=0) {
    $png=Join-Path $out "$name.png"
    & $Browser --render (Join-Path $root "tests/paint/transforms-inline-controls.html") $png 600 400 $mx $my 5 0 0 $click
    if ($LASTEXITCODE -ne 0) { throw "render failed" }
    return New-Object System.Drawing.Bitmap $png
}
function BlueCount($bmp,$x0,$y0,$x1,$y1) {
    $n=0
    for ($y=$y0;$y -lt $y1;$y++) { for ($x=$x0;$x -lt $x1;$x++) {
        $p=$bmp.GetPixel($x,$y)
        if ($p.B -gt 200 -and $p.R -lt 30 -and $p.G -lt 30) { $n++ }
    }}
    return $n
}
function Check($name,$ok) { if (!$ok) { throw "FAIL $name" }; Write-Host "PASS $name" }
$b=Render "inline-hover" 115 50
try { Check "expanded link decoration hover" ((BlueCount $b 30 55 120 75) -gt 100) } finally { $b.Dispose() }
$b=Render "inline-idle" 260 100
try { Check "idle link has no decoration" ((BlueCount $b 30 55 120 75) -eq 0) } finally { $b.Dispose() }
$b=Render "inline-opacity" 385 50
try { $p=$b.GetPixel(385,35); Check "expanded inline opacity hover" ($p.R -eq 255 -and $p.G -eq 0) } finally { $b.Dispose() }
$b=Render "input-focus" 210 180 1
try { Check "expanded native input receives focus" ((BlueCount $b 25 150 50 210) -gt 20) } finally { $b.Dispose() }
$b=Render "input-outside" 260 180 1
try { Check "outside native input stays unfocused" ((BlueCount $b 25 150 50 210) -eq 0) } finally { $b.Dispose() }
$b=Render "button-hover" 370 180
try {
    $p=$b.GetPixel(370,180); Check "inline-block receives expanded hover" ($p.G -eq 128 -and $p.R -eq 0)
    $p=$b.GetPixel(310,270); Check "inline-block DOM bounds include ancestor scale" ($p.G -eq 128 -and $p.R -eq 0)
} finally { $b.Dispose() }
$b=Render "select-popup" 210 290 1
try {
    # Popup background below the projected control, beyond its layout box.
    $p=$b.GetPixel(210,330)
    Check "transformed select opens projected popup" ($p.R -lt 245 -and $p.G -lt 250)
} finally { $b.Dispose() }

$b=Render "select-idle" 260 100
try { $p=$b.GetPixel(210,330); Check "idle select has no popup" ($p.R -eq 255 -and $p.G -eq 255 -and $p.B -eq 255) } finally { $b.Dispose() }
