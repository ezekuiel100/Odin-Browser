param([string]$Browser = ".\browser.exe", [switch]$ExpectBroken)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local\reports\inline-effects"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "inline-effects.png"
if (Test-Path $png) { Remove-Item -LiteralPath $png -Force }
& $Browser --render (Join-Path $root "tests\paint\inline-effects.html") $png 720 400 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $png)) { throw "inline-effects: render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$checks = 0; $fails = 0
function Pixel($name, $x, $y, $r, $g, $b) {
    $p = $bmp.GetPixel($x,$y)
    $ok = [Math]::Abs($p.R-$r) -le 4 -and [Math]::Abs($p.G-$g) -le 4 -and [Math]::Abs($p.B-$b) -le 4
    $script:checks++
    if ($ok) { Write-Host "PASS $name" } else { $script:fails++; Write-Host "FAIL $name pixel=$p" }
}
try {
    Pixel "inline opacity zero" 20 25 255 255 255
    Pixel "empty relative inline anchors its absolute child" 420 35 0 255 0
    Pixel "inline visibility hidden" 20 85 255 255 255
    Pixel "visible descendant of hidden inline" 60 85 0 0 255
    Pixel "opacity group includes overlapping absolute" 30 165 127 127 255
    Pixel "nested opacity multiplies" 20 225 191 191 191
    Pixel "positioned inline atom stays inside hidden group" 20 285 255 255 255
    Pixel "absolute-only opacity scope stays hidden" 20 345 255 255 255
    Pixel "absolute tooltip inside inline button" 420 250 0 255 0
    Pixel "fixed inside inline button uses viewport" 610 310 0 255 0
} finally { $bmp.Dispose() }
Write-Host "inline-effects: $($checks-$fails)/$checks PASS"
if ($ExpectBroken) {
    if ($fails -eq 0) { throw "negative control unexpectedly passed" }
    exit 0
}
if ($fails -gt 0) { exit 1 }
exit 0
