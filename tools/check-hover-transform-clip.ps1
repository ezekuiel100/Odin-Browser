param([string]$Browser = ".\browser.exe", [switch]$ExpectBroken)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local/reports/hover-transform-clip"
New-Item -ItemType Directory -Force $out | Out-Null
$html = Get-Content (Join-Path $root "tests/paint/hover-transform-clip.html") -Raw
$script:checks=0; $script:fails=0
function Pixel($bmp,$name,$x,$y,$r,$g,$b) {
    $p=$bmp.GetPixel($x,$y); $script:checks++
    if ([Math]::Abs($p.R-$r) -le 5 -and [Math]::Abs($p.G-$g) -le 5 -and [Math]::Abs($p.B-$b) -le 5) { Write-Host "PASS $name" }
    else { $script:fails++; Write-Host "FAIL $name ($p)" }
}
function Render($name,$content,$mx=140,$my=140) {
    $path=Join-Path $out "$name.html"; $png=Join-Path $out "$name.png"
    [IO.File]::WriteAllText($path,$content)
    & $Browser --render $path $png 400 450 $mx $my 3 | Out-Null
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $png)) { throw "render failed: $name" }
    return New-Object System.Drawing.Bitmap $png
}
function Halo($bmp,$name,$x,$y,$present) {
    $p=$bmp.GetPixel($x,$y); $script:checks++
    $visible=($p.R -gt 30 -and $p.R -gt $p.B)
    if ($visible -eq $present) { Write-Host "PASS $name" }
    else { $script:fails++; Write-Host "FAIL $name ($p)" }
}
$shadow='<!doctype html><style>body{margin:80px;background:#17172c}.card{width:100px;height:100px;background:#222237;border-radius:12px;overflow:hidden}.card:hover{box-shadow:0 0 24px 4px #ff8000}</style><div class="card"></div>'
$bmp=Render "shadow-hover" $shadow 120 120
try {
    Halo $bmp "hover introduces outer blurred shadow" 70 120 $true
    Halo $bmp "hover shadow extends below card" 120 190 $true
} finally { $bmp.Dispose() }
$bmp=Render "shadow-idle" $shadow 350 400
try { Pixel $bmp "idle has no hover shadow" 70 120 23 23 44 } finally { $bmp.Dispose() }
$bmp=Render "shadow-scaled" ($shadow.Replace('box-shadow:','transform:scale(1.08);box-shadow:')) 120 120
try { Halo $bmp "hover shadow survives scaled overflow clip" 65 120 $true } finally { $bmp.Dispose() }
$clear=$shadow.Replace('background:#222237;','background:#222237;box-shadow:0 0 24px 4px #ff8000;').Replace('.card:hover{box-shadow:0 0 24px 4px #ff8000}', '.card:hover{box-shadow:none}')
$bmp=Render "shadow-clear" $clear 120 120
try { Pixel $bmp "hover none clears base shadow" 70 120 23 23 44 } finally { $bmp.Dispose() }
$bmp=Render "shadow-base" $clear 350 400
try { Halo $bmp "base shadow remains outside hover" 70 120 $true } finally { $bmp.Dispose() }
$trans=$shadow.Replace('background:#222237', 'background:rgba(255,255,255,0.05)')
$idle=Render "shadow-translucent-idle" $trans 350 400
$inside=$idle.GetPixel(120,120); $idle.Dispose()
$bmp=Render "shadow-translucent" $trans 120 120
try {
    Pixel $bmp "shadow does not tint translucent interior" 120 120 $inside.R $inside.G $inside.B
    Halo $bmp "translucent card keeps exterior halo" 70 120 $true
    Halo $bmp "rounded cutout preserves shadow outside corner" 81 81 $true
    $profile=@(45..78 | ForEach-Object { $bmp.GetPixel($_,120).R })
    $levels=@($profile | Select-Object -Unique)
    $maxStep=0
    for ($i=1; $i -lt $profile.Count; $i++) { $maxStep=[Math]::Max($maxStep,[Math]::Abs($profile[$i]-$profile[$i-1])) }
    $script:checks++
    if ($levels.Count -ge 20 -and $maxStep -le 10) { Write-Host "PASS Gaussian halo has smooth falloff" }
    else { $script:fails++; Write-Host "FAIL halo levels=$($levels.Count), largest step=$maxStep" }
} finally { $bmp.Dispose() }
$bmp=Render "shadow-translucent-scaled" ($trans.Replace('box-shadow:', 'transform:scale(1.08);box-shadow:')) 120 120
try { Pixel $bmp "scaled shadow does not tint translucent interior" 120 120 $inside.R $inside.G $inside.B } finally { $bmp.Dispose() }
$empty=$shadow.Replace('background:#222237', 'background:transparent')
$bmp=Render "shadow-transparent" $empty 120 120
try { Pixel $bmp "transparent card interior remains clear" 120 120 23 23 44 } finally { $bmp.Dispose() }
$offset=$empty.Replace('0 0 24px 4px #ff8000', '12px 8px 0 #ff8000')
$bmp=Render "shadow-offset" $offset 120 120
try {
    Pixel $bmp "offset shadow still excludes original box" 170 120 23 23 44
    Pixel $bmp "zero blur preserves sharp offset shadow" 186 120 255 128 0
    Pixel $bmp "offset shadow does not extend on opposite side" 70 120 23 23 44
} finally { $bmp.Dispose() }
$bmp=Render "shadow-negative-spread" ($empty.Replace('0 0 24px 4px #ff8000', '0 0 0 -8px #ff8000')) 120 120
try { Pixel $bmp "negative spread shadow inside box is removed" 120 120 23 23 44 } finally { $bmp.Dispose() }
$bmp=Render "hover" $html
try {
    Pixel $bmp "hover image reaches enlarged top" 80 33 255 0 0
    Pixel $bmp "hover image reaches enlarged left" 36 100 255 0 0
    Pixel $bmp "hover image reaches enlarged right" 248 100 0 0 255
    Pixel $bmp "rounded outer corner stays clear" 33 28 23 23 44
    Pixel $bmp "image still ends above caption" 80 260 34 34 55
} finally { $bmp.Dispose() }
$bmp=Render "idle" $html 350 400
try {
    Pixel $bmp "idle photo stays in original box" 50 100 255 0 0
    Pixel $bmp "idle does not grow" 36 100 23 23 44
} finally { $bmp.Dispose() }
$nested=$html.Replace('overflow:hidden','overflow:visible').Replace('<img ', '<div style="overflow:hidden;width:200px;height:200px"><img ').Replace('<div class="caption">','</div><div class="caption">')
$bmp=Render "nested" $nested
try { Pixel $bmp "descendant clip follows parent scale" 36 100 255 0 0 } finally { $bmp.Dispose() }
$outer=$html.Replace('<div class="card">','<div style="width:180px;height:308px;overflow:hidden"><div class="card">')+'</div>'
$bmp=Render "outer" $outer
try {
    Pixel $bmp "ancestor clip still hides expanded left" 36 100 23 23 44
    Pixel $bmp "ancestor clip still hides expanded right" 230 100 23 23 44
    Pixel $bmp "ancestor clip preserves visible image" 80 100 255 0 0
} finally { $bmp.Dispose() }
$bmp=Render "rotate" ($html.Replace('scale(1.08)','rotate(90deg)'))
try { Pixel $bmp "local clip follows rotation" 280 150 255 0 0 } finally { $bmp.Dispose() }
$rounded=Get-Content (Join-Path $root "tests/paint/hover-rounded-backdrop.html") -Raw
$reference=$rounded.Replace('overflow:hidden','overflow:visible').Replace('<div class="photo"></div>','')
$ref=Render "rounded-backdrop-reference" $reference 120 120
$bmp=Render "rounded-backdrop" $rounded 120 120
try {
    foreach ($pt in @(@(76,74),@(243,74),@(76,306),@(243,306))) {
        $p=$ref.GetPixel($pt[0],$pt[1])
        Pixel $bmp "hover corner reveals actual backdrop $($pt -join ',')" $pt[0] $pt[1] $p.R $p.G $p.B
    }
    Pixel $bmp "rounded clip keeps center photo" 120 140 224 64 64
    Pixel $bmp "rounded clip keeps left border" 75 140 255 128 0
    foreach ($position in @('absolute','relative')) {
        $positioned=$rounded.Replace('.photo {', ".photo { position:$position; top:0; left:0; z-index:2;")
        $pos=Render "rounded-backdrop-$position" $positioned 120 120
        try {
            foreach ($pt in @(@(76,74),@(243,74),@(76,306),@(243,306))) {
                $p=$ref.GetPixel($pt[0],$pt[1])
                Pixel $pos "positioned $position corner reveals actual backdrop $($pt -join ',')" $pt[0] $pt[1] $p.R $p.G $p.B
            }
            Pixel $pos "positioned $position content remains visible" 120 140 224 64 64
        } finally { $pos.Dispose() }
    }
} finally { $bmp.Dispose(); $ref.Dispose() }
Write-Host "hover-transform-clip: $($checks-$fails) PASS / $fails FAIL"
if ($ExpectBroken) { if ($fails -gt 0) { exit 0 }; exit 1 }
if ($fails -gt 0) { exit 1 }; exit 0
