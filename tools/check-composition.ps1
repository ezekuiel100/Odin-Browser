param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root "tests/paint/_out"
New-Item -ItemType Directory -Force $out | Out-Null
$html = '<!doctype html><style>body{margin:0;background:white}.cell{position:absolute;width:40px;height:40px}.group{opacity:.5}.ink{position:absolute;width:30px;height:30px;background:black}.second{left:10px;top:10px}</style>'
for ($i=0; $i -lt 40; $i++) {
    $x = 10 + ($i % 8)*60; $y = 10 + [math]::Floor($i/8)*60
    $html += "<div class='cell group' style='left:${x}px;top:${y}px'><div class='ink'></div><div class='ink second'></div></div>"
}
# These occur after forty group layers: neither mask nor blend may disappear.
$html += '<div class="cell" style="left:10px;top:320px;background:red;mask-image:linear-gradient(to right,transparent,black)"></div>'
$html += '<div class="cell" style="left:70px;top:320px;background:#404040;filter:brightness(1);mix-blend-mode:difference"></div>'
$html += '<div class="cell" style="left:130px;top:320px;background:blue"><div class="cell" style="overflow:hidden;border-radius:20px"><div class="cell" style="background:red"></div></div></div>'
$inputPath = Join-Path $out "composition.html"
$png = Join-Path $out "composition.png"
[IO.File]::WriteAllText($inputPath,$html)
if (Test-Path $png) { Remove-Item -LiteralPath $png }
& $Browser --render $inputPath $png 500 380 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0 -or !(Test-Path $png)) { throw "Composition render failed" }
$bmp = New-Object System.Drawing.Bitmap $png
$fails = 0
try {
    for ($i=0; $i -lt 40; $i++) {
        $x = 10 + ($i % 8)*60; $y = 10 + [math]::Floor($i/8)*60
        $single = $bmp.GetPixel($x+5,$y+5); $overlap = $bmp.GetPixel($x+20,$y+20)
        if ([math]::Abs($single.R-128) -gt 3 -or [math]::Abs($overlap.R-128) -gt 3) {
            Write-Host "FAIL group $i single=$single overlap=$overlap"; $fails++
        }
    }
    $left=$bmp.GetPixel(12,340); $right=$bmp.GetPixel(47,340)
    if ($left.G -lt 225 -or $right.G -gt 30) { Write-Host "FAIL mask after 40 groups: $left $right"; $fails++ }
    $blend=$bmp.GetPixel(90,340)
    if ([math]::Abs($blend.R-191) -gt 2) { Write-Host "FAIL filter and difference: $blend"; $fails++ }
    $corner=$bmp.GetPixel(131,321); $center=$bmp.GetPixel(150,340)
    if ($corner.B -lt 250 -or $corner.R -gt 5) { Write-Host "FAIL rounded clip preserves backdrop: $corner"; $fails++ }
    if ($center.R -lt 250 -or $center.B -gt 5) { Write-Host "FAIL rounded clip retains center: $center"; $fails++ }
} finally { $bmp.Dispose() }
Write-Host "Composition: $(44-$fails)/44 PASS"
if ($fails) { exit 1 }
