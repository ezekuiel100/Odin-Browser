param([string]$Browser = ".\browser.exe", [switch]$ExpectBroken)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local\reports\scroll"
New-Item -ItemType Directory -Force $out | Out-Null
$checks = 0; $fails = 0

function Render($name, $html, $frames, $scrollY, $wheel, $mx, $my) {
    $inputPath = Join-Path $out "$name.html"
    $outputPath = Join-Path $out "$name.png"
    [IO.File]::WriteAllText($inputPath, $html)
    & $Browser --render $inputPath $outputPath 320 200 $mx $my $frames $scrollY $wheel | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Render failed: $name" }
    return New-Object System.Drawing.Bitmap $outputPath
}

function Pixel($bmp, $name, $x, $y, $r, $g, $b) {
    $p = $bmp.GetPixel($x, $y)
    $script:checks++
    if ([Math]::Abs($p.R-$r) -le 4 -and [Math]::Abs($p.G-$g) -le 4 -and [Math]::Abs($p.B-$b) -le 4) {
        Write-Host "PASS $name"
    } else { $script:fails++; Write-Host "FAIL $name pixel=$p" }
}

# More than 4 MB of paint commands, including many offscreen siblings.
$long = '<html><body style="margin:0">' +
    ('<div style="height:2px;background:#dddddd"></div>' * 6000) +
    '<div style="height:200px;background:#00ff00"></div></body></html>'
$bmp = Render "long-bottom" $long 3 12000 0 -1 -1
try { Pixel $bmp "large page paints its bottom after scrolling" 100 100 0 255 0 }
finally { $bmp.Dispose() }

if (-not $ExpectBroken) {
    $inner = '<html><body style="margin:0"><div style="width:200px;height:100px;overflow:auto">' +
        '<div style="height:40px;background:#ff0000"></div>' +
        '<div style="height:400px;background:#00ff00"></div></div></body></html>'
    $bmp = Render "inner-idle" $inner 1 0 0 50 50
    try {
        Pixel $bmp "idle container starts at top" 50 35 255 0 0
        Pixel $bmp "idle second band is visible" 50 45 0 255 0
    } finally { $bmp.Dispose() }
    $bmp = Render "inner-first-frame" $inner 1 0 -1 50 50
    try {
        Pixel $bmp "first wheel frame keeps part of the first band" 50 25 255 0 0
        Pixel $bmp "first wheel frame moves content smoothly" 50 35 0 255 0
        Pixel $bmp "container clip leaves the page clear" 50 140 255 255 255
    } finally { $bmp.Dispose() }
    $bmp = Render "inner-end" $inner 30 0 -1 50 50
    try { Pixel $bmp "repeated wheel reaches lower content" 50 25 0 255 0 }
    finally { $bmp.Dispose() }
}
Write-Host "scroll-paint: $($checks-$fails)/$checks PASS"
if ($ExpectBroken) {
    if ($fails -eq 0) { throw "Negative control unexpectedly passed" }
    exit 0
}
if ($fails -gt 0) { exit 1 }
