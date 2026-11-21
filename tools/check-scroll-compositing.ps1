param([string]$Browser = '.\browser.exe')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root '_local/reports/scroll-compositing'
New-Item -ItemType Directory -Force $out | Out-Null
$fixture = Join-Path $root 'tests/paint/scroll-compositing.html'
$script:checks=0; $script:fails=0
function Check($name, $ok, $pixel) {
    $script:checks++
    if ($ok) { Write-Host "PASS $name" }
    else { $script:fails++; Write-Host "FAIL $name pixel=$pixel" }
}
function Near($bmp,$name,$x,$y,$r,$g,$b) {
    $p=$bmp.GetPixel($x,$y)
    Check $name ([Math]::Abs($p.R-$r) -le 5 -and [Math]::Abs($p.G-$g) -le 5 -and [Math]::Abs($p.B-$b) -le 5) $p
}
function Render($name,$html,$frames,$scrollY) {
    $png=Join-Path $out "$name.png"
    & $Browser --render $html $png 640 520 -1 -1 $frames $scrollY 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "render failed: $name" }
    return New-Object System.Drawing.Bitmap $png
}
$bmp=Render 'initial' $fixture 3 0
try {
    Near $bmp 'rounded frost exposes original corner' 81 41 255 0 0
    Near $bmp 'transparent transitioning overlay does not blur the page' 158 10 255 0 0
    $p=$bmp.GetPixel(160,90)
    Check 'blur mixes both sides of the boundary' ($p.R -gt 100 -and $p.R -lt 155 -and $p.B -gt 100 -and $p.B -lt 155 -and $p.G -lt 5) $p
    $p=$bmp.GetPixel(397,90)
    Check 'blur samples pixels outside the element' ($p.B -gt 70 -and $p.R -gt 90 -and $p.G -lt 5) $p
    $p=$bmp.GetPixel(128,264)
    Check 'reduced blur averages thin stripes without aliasing' ($p.R -ge 115 -and $p.R -le 140 -and [Math]::Abs($p.R-$p.G) -le 3 -and [Math]::Abs($p.R-$p.B) -le 3) $p
    Near $bmp 'brightness clamps before reduced blur averages pixels' 428 264 191 191 191
    Near $bmp 'non-blur grayscale stays active' 490 90 18 18 18
    Near $bmp 'nested rounded group keeps transparent corner' 21 361 0 255 0
    Near $bmp 'nested rounded group preserves opacity' 80 420 0 127 128
    Near $bmp 'outer rounded group keeps its red content' 30 420 128 127 0
} finally { $bmp.Dispose() }
$bmp=Render 'scrolled' $fixture 3 200
try {
    Near $bmp 'scroll preserves nested content and opacity' 80 220 0 127 128
    Near $bmp 'scroll preserves outer rounded corner' 21 161 0 255 0
} finally { $bmp.Dispose() }
$dynamic=Join-Path $out 'dynamic.html'
$html=Get-Content -LiteralPath $fixture -Raw
$html += '<script>setTimeout(function(){document.querySelector(".nested").style.background="#ff0000"},100)</script>'
[IO.File]::WriteAllText($dynamic,$html)
$bmp=Render 'changed-content' $dynamic 30 0
try { Near $bmp 'cached parent reflects changed nested content' 80 420 128 127 0 }
finally { $bmp.Dispose() }
Write-Host "scroll-compositing: $($checks-$fails)/$checks PASS"
if ($fails -gt 0) { exit 1 }
