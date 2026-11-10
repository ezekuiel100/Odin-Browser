param([string]$Browser = ".\browser.exe", [switch]$ExpectBroken)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local\reports\inline-controls"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "inline-controls.png"
if (Test-Path $png) { Remove-Item -LiteralPath $png }
& $Browser --render (Join-Path $root "tests\paint\inline-controls.html") $png 720 260 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $png)) { throw "render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$fails = 0; $checks = 0
function Check($name,$ok) {
    $script:checks++
    if ($ok) { Write-Host "PASS $name" } else { $script:fails++; Write-Host "FAIL $name" }
}
try {
    $same = $true
    for ($y=10;$y -lt 50;$y++) { for ($x=10;$x -lt 240;$x++) {
        if ($bmp.GetPixel($x,$y).ToArgb() -ne $bmp.GetPixel($x,($y+60)).ToArgb()) { $same=$false }
    }}
    Check "inline font normal resets inherited italic and bold" $same
    Check "before icon keeps geometry" ($bmp.GetPixel(14,154).B -eq 255 -and $bmp.GetPixel(14,154).R -eq 0)
    Check "after icon keeps geometry and order" ($bmp.GetPixel(22,164).G -eq 255 -and $bmp.GetPixel(22,164).R -eq 0)
    Check "positioned pseudo on flattened inline keeps its box" ($bmp.GetPixel(410,160).G -eq 255 -and $bmp.GetPixel(410,160).R -eq 0)
    foreach ($x in @(110,210,310)) {
        $white = $true
        for ($dy=150;$dy -lt 180;$dy++) { for ($dx=$x;$dx -lt ($x+28);$dx++) {
            $p=$bmp.GetPixel($dx,$dy)
            if ($p.R -ne 255 -or $p.G -ne 255 -or $p.B -ne 255) { $white=$false }
        }}
        Check "hidden generated content at x=$x" $white
    }
} finally { $bmp.Dispose() }
Write-Host "inline-controls: $($checks-$fails)/$checks PASS"
if ($ExpectBroken) { if ($fails -eq 0) { throw "negative control unexpectedly passed" }; exit 0 }
if ($fails -gt 0) { exit 1 }
