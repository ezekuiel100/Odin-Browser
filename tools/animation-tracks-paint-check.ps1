param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$exe = if ([IO.Path]::IsPathRooted($Browser)) { $Browser } else { Join-Path $root $Browser }
$out = Join-Path $root "_local\animations"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "animation-tracks.png"
& $exe --render (Join-Path $root "tests\paint\animation-tracks.html") $png 360 330 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Render failed" }
$bmp = [Drawing.Bitmap]::new($png)
try {
    function Check-Pixel([string]$name,[int]$x,[int]$y,[int]$r,[int]$g,[int]$b) {
        $p=$bmp.GetPixel($x,$y)
        if ([Math]::Abs($p.R-$r) -gt 4 -or [Math]::Abs($p.G-$g) -gt 4 -or [Math]::Abs($p.B-$b) -gt 4) {
            throw "$name at ($x,$y): got $($p.R),$($p.G),$($p.B); expected $r,$g,$b"
        }
        Write-Output "PASS $name"
    }
    Check-Pixel "pixel translation" 70 20 0 204 0
    Check-Pixel "old position is empty" 20 20 255 255 255
    Check-Pixel "pixels and percentages interpolate" 45 80 0 204 0
    Check-Pixel "base translation replaced" 55 140 0 204 0
    Check-Pixel "base translation not accumulated" 110 140 255 255 255
    Check-Pixel "sparse opacity track from zero base" 160 20 127 229 127
    Check-Pixel "single keyframe implicit start" 195 80 0 204 0
    Check-Pixel "last animation identity replaces translation" 160 140 0 204 0
    Check-Pixel "translated subtree" 65 205 0 0 255
    Check-Pixel "offscreen animation enters viewport" 60 270 0 204 0
    Write-Output "animation-tracks-paint: 10 PASS / 0 FAIL"
} finally { $bmp.Dispose() }
