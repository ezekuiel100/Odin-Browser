param([string]$Browser = ".\browser.exe")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "_local\reports\font-loading"
New-Item -ItemType Directory -Force $out | Out-Null
$declarations = @()
$specs = @(
    @{File='arial.ttf';Weight=400;Style='normal';Reference='ReferenceRegular'},
    @{File='arialbd.ttf';Weight=700;Style='normal';Reference='ReferenceBold'},
    @{File='ariali.ttf';Weight=400;Style='italic';Reference='ReferenceItalic'}
)
foreach ($spec in $specs) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $env:WINDIR ('Fonts\' + $spec.File)))
    $uri = 'data:font/ttf;base64,' + [Convert]::ToBase64String($bytes)
    $declarations += '@font-face{font-family:Probe; font-weight:' + $spec.Weight + ';font-style:' + $spec.Style + ';src:url(' + $uri + ')}'
    $declarations += '@font-face{font-family:' + $spec.Reference + ';src:url(' + $uri + ')}'
}
$html = '<html><style>' + ($declarations -join "`n") + 'body{margin:0;background:white}div{position:absolute;left:10px;font-size:32px;font-family:Probe}#normal{top:10px}#bold{top:70px;font-weight:700}#italic{top:130px;font-style:italic}#rnormal{top:190px;font-family:ReferenceRegular}#rbold{top:250px;font-family:ReferenceBold}#ritalic{top:310px;font-family:ReferenceItalic}</style>'
foreach ($id in @('normal','bold','italic','rnormal','rbold','ritalic')) {
    $html += '<div id="' + $id + '">Animate.css AVATAR</div>'
}
$html += '</html>'
$inputPath = Join-Path $out 'font-loading.html'
$png = Join-Path $out 'font-loading.png'
[IO.File]::WriteAllText($inputPath, $html)
& $Browser --render $inputPath $png 760 380 0 0 5
if ($LASTEXITCODE -ne 0) { throw 'font render failed' }
$bmp = New-Object System.Drawing.Bitmap $png
try {
    $checks = 0
    foreach ($top in @(10,70,130)) {
        $same = $true; $ink = 0
        for ($y=$top;$y -lt ($top+50);$y++) { for ($x=0;$x -lt 600;$x++) {
            $pixel = $bmp.GetPixel($x,$y)
            if ($pixel.R -lt 220) { $ink++ }
            # Identical glyphs at different atlas UVs can differ by one gray
            # level due to texture sampling. Preserve a tight pixel tolerance.
            if ([Math]::Abs([int]$pixel.R - [int]$bmp.GetPixel($x,($y+180)).R) -gt 2) { $same=$false }
        }}
        if ($ink -lt 100) { throw "blank font sample at y=$top" }
        if (-not $same) { throw "wrong font variant at y=$top" }
        $checks += 2
        Write-Host "PASS font variant and visible text at y=$top"
    }
    Write-Host "font-loading: $checks/$checks PASS"
} finally { $bmp.Dispose() }
