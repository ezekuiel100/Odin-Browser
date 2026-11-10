param([string]$Browser = ".\browser.exe", [switch]$ExpectBroken)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local\reports\image-rounding"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "image-rounded.png"
if (Test-Path $png) { Remove-Item -LiteralPath $png -Force }
& $Browser --render (Join-Path $root "tests\paint\image-rounded.html") $png 640 560 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $png)) { throw "image-rounding: render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$checks = 0; $fails = 0
function Pixel($name, $x, $y, $r, $g, $b) {
    $p = $bmp.GetPixel($x,$y)
    $ok = [Math]::Abs($p.R-$r) -le 4 -and [Math]::Abs($p.G-$g) -le 4 -and [Math]::Abs($p.B-$b) -le 4
    $script:checks++
    if ($ok) { Write-Host "PASS $name" } else { $script:fails++; Write-Host "FAIL $name pixel=$p" }
}
try {
    Pixel "circle reveals actual yellow element behind corner" 22 22 255 255 0
    Pixel "circle lower corner" 22 118 0 255 0
    Pixel "circle red half" 50 70 255 0 0
    Pixel "circle blue half" 90 70 0 0 255
    Pixel "inline circle corner" 162 22 0 255 0
    Pixel "inline circle center" 180 70 255 0 0
    Pixel "independent large top-left corner" 302 22 0 255 0
    Pixel "independent square top-right corner" 398 22 0 0 255
    Pixel "independent small bottom-right corner outside" 398 118 0 255 0
    Pixel "independent small bottom-right corner inside" 385 112 0 0 255
    Pixel "percentage ellipse corner" 442 22 0 255 0
    Pixel "percentage ellipse near horizontal tip" 445 70 255 0 0
    Pixel "cover corner" 22 162 0 255 0
    Pixel "cover right object-position selects blue" 45 210 0 0 255
    Pixel "contain letterbox" 210 170 0 255 0
    Pixel "contain still intersects circle" 162 187 0 255 0
    Pixel "contain red half" 185 210 255 0 0
    Pixel "contain blue half" 235 210 0 0 255
    Pixel "scrolled circle keeps original curvature" 304 165 255 0 0
    Pixel "scrolled circle bottom corner" 302 218 0 255 0
    Pixel "border remains black" 442 210 0 0 0
    Pixel "padding remains yellow outside content curve" 463 183 255 255 0
    Pixel "border-box content keeps its height" 480 235 255 0 0
    Pixel "opacity corner stays transparent" 22 302 0 255 0
    Pixel "opacity red over green" 50 350 128 127 0
    Pixel "transformed corner" 172 302 0 255 0
    Pixel "transformed center" 190 350 255 0 0
    Pixel "rounded-full scientific notation" 302 302 0 255 0
    Pixel "square control corner" 442 302 255 0 0
    Pixel "percentage width produces a full circle" 90 480 0 0 255
    Pixel "percentage circle corner stays transparent" 22 442 0 255 0
    Pixel "flex paint reaches the bottom of its square box" 250 510 255 0 0
    Pixel "flex circle corner stays transparent" 222 442 0 255 0
    $p = $bmp.GetPixel(470,480)
    $script:checks++
    if ($p.R -gt 140 -and $p.R -lt 220 -and $p.B -gt 35 -and $p.B -lt 115 -and $p.G -lt 4) {
        Write-Host "PASS linear filtering interpolates photos instead of nearest-neighbor blocks"
    } else {
        $script:fails++; Write-Host "FAIL linear photo filtering pixel=$p"
    }
} finally { $bmp.Dispose() }

# Regression from Famosos-BR's actual markup: img width=80 height=90, but
# width/height:100% inside an 80x80 flex wrapper with align-items:center.
$png = Join-Path $out "famosos-avatar.png"
if (Test-Path $png) { Remove-Item -LiteralPath $png -Force }
& $Browser --render (Join-Path $root "tests\paint\famosos-avatar.html") $png 640 240 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $png)) { throw "famosos-avatar: render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
try {
    Pixel "Famosos: image must not extend above its square wrapper" 100 21 34 34 53
    Pixel "Famosos: image must not extend below its square wrapper" 105 106 34 34 53
    Pixel "Famosos: square wrapper top-left corner stays clear" 67 26 34 34 53
    Pixel "Famosos: red photo half remains visible" 90 64 255 0 0
    Pixel "Famosos: blue photo half remains visible" 125 64 0 0 255
    $minX=640; $maxX=-1; $minY=240; $maxY=-1
    for ($y=0; $y -lt 128; $y++) {
        for ($x=50; $x -lt 160; $x++) {
            $p=$bmp.GetPixel($x,$y)
            if ($p.G -lt 10 -and (($p.R -gt 200 -and $p.B -lt 10) -or ($p.B -gt 200 -and $p.R -lt 10))) {
                $minX=[Math]::Min($minX,$x); $maxX=[Math]::Max($maxX,$x)
                $minY=[Math]::Min($minY,$y); $maxY=[Math]::Max($maxY,$y)
            }
        }
    }
    $w=$maxX-$minX+1; $h=$maxY-$minY+1
    $checks++
    if ($w -ge 78 -and $w -le 80 -and [Math]::Abs($w-$h) -le 1) {
        Write-Host "PASS Famosos: painted avatar has equal width and height ($w x $h)"
    } else { $fails++; Write-Host "FAIL Famosos: painted avatar is oval ($w x $h)" }
} finally { $bmp.Dispose() }
Write-Host "image-rounding: $($checks-$fails)/$checks PASS"
if ($ExpectBroken) {
    if ($fails -eq 0) { throw "negative control unexpectedly passed" }
    exit 0
}
if ($fails -gt 0) { exit 1 }
exit 0
