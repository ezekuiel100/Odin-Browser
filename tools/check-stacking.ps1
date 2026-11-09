param([string]$Browser = ".\browser_stack.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root "tests/paint/_out"
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$png = Join-Path $outDir "stacking-result.png"
if (Test-Path $png) { Remove-Item -LiteralPath $png }
& $Browser --render (Join-Path $root "tests/paint/stacking-contexts.html") $png 520 760 0 0 3 | Out-Null
if (!(Test-Path $png)) { throw "Render did not produce PNG" }
$bmp = New-Object System.Drawing.Bitmap $png
$names = @("relative-z","auto-escape","zero-confines","negative-behind-flow","flex-z","transform-zero","opacity-zero","negative-in-context","isolation-barrier","grid-z","clip-retained","equal-tree-order","static-z-ignored","filter-barrier","will-change-barrier","contain-barrier","inline-context-escape","clip-path-barrier","opacity-group-overlap","negative-z-order","fixed-context-barrier","sticky-context-barrier","transform-context-barrier","flex-order-tie")
$expected = @("green","green","red","red","green","green","blend","green","red","green","white","green","red","red","red","red","green","red","blend","red","red","red","red","green")
$fails = 0
try {
    for ($i=0; $i -lt $names.Count; $i++) {
        $x = 20 + ($i % 4)*120 + 40
        $y = 20 + [math]::Floor($i/4)*120 + 40
        $p = $bmp.GetPixel($x,$y)
        $ok = switch ($expected[$i]) {
            green { $p.G -gt 245 -and $p.R -lt 10 -and $p.B -lt 10 }
            red { $p.R -gt 245 -and $p.G -lt 10 -and $p.B -lt 10 }
            white { $p.R -gt 245 -and $p.G -gt 245 -and $p.B -gt 245 }
            blend { $p.R -ge 120 -and $p.R -le 135 -and $p.G -ge 120 -and $p.G -le 135 -and $p.B -lt 10 }
        }
        if ($ok) { Write-Host "PASS $($names[$i])" }
        else { Write-Host "FAIL $($names[$i]): $p"; $fails++ }
    }
} finally { $bmp.Dispose() }
Write-Host "$($names.Count-$fails) PASS / $fails FAIL"
if ($fails) { exit 1 }
