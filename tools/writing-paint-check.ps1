param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$exe = if ([IO.Path]::IsPathRooted($Browser)) { $Browser } else { Join-Path $root $Browser }
$out = Join-Path $root "_local\writing"
New-Item -ItemType Directory -Force $out | Out-Null
$png = Join-Path $out "paint-writing.png"
& $exe --render (Join-Path $root "tests\paint\writing-modes.html") $png 500 380 0 0 3 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao renderizar fixture" }
$bmp = [Drawing.Bitmap]::new($png)
try {
    function Ink-Bounds([int]$x0,[int]$y0,[int]$x1,[int]$y1) {
        $minx=$x1; $miny=$y1; $maxx=-1; $maxy=-1; $count=0
        for ($y=$y0; $y -lt $y1; $y++) {
            for ($x=$x0; $x -lt $x1; $x++) {
                $p=$bmp.GetPixel($x,$y)
                if ($p.R -lt 90 -and $p.G -lt 90 -and $p.B -lt 90) {
                    $minx=[Math]::Min($minx,$x); $maxx=[Math]::Max($maxx,$x)
                    $miny=[Math]::Min($miny,$y); $maxy=[Math]::Max($maxy,$y); $count++
                }
            }
        }
        return @{ W=$maxx-$minx+1; H=$maxy-$miny+1; Count=$count }
    }
    $side=Ink-Bounds 10 10 90 180
    if ($side.Count -lt 40 -or $side.H -le $side.W*1.5) { throw "Sideways nao gira o run para o eixo vertical" }
    Write-Output "PASS sideways rotates the whole run"
    $up=Ink-Bounds 110 10 190 180
    if ($up.Count -lt 40 -or $up.H -le $up.W*2) { throw "Upright nao empilha os glifos" }
    Write-Output "PASS upright stacks glyphs"
    $yellow=0; $rightmost=-1
    for ($y=210; $y -lt 260; $y++) {
        for ($x=10; $x -lt 370; $x++) {
            $p=$bmp.GetPixel($x,$y)
            if ($p.R -gt 220 -and $p.G -gt 140 -and $p.G -lt 220 -and $p.B -lt 40) { $yellow++; $rightmost=[Math]::Max($rightmost,$x) }
        }
    }
    if ($yellow -lt 1500) { throw "Fundo inline RTL perdeu a extensao visual" }
    Write-Output "PASS RTL inline background covers both words"
    if ($rightmost -lt 350) { throw "Linha RTL nao termina na borda inline-start" }
    Write-Output "PASS RTL line aligns at the right content edge"
    $complex=Ink-Bounds 10 280 480 340
    if ($complex.Count -lt 200) { throw "Trechos shaped nao foram pintados" }
    Write-Output "PASS complex scripts produce visible ink"
    Write-Output "writing-paint: 5 PASS / 0 FAIL"
} finally { $bmp.Dispose() }
