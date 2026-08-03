# Runner de reftests no estilo WPT.
# Para cada *.html com <link rel="match" href="..."> em tests/reftest:
#   1. renderiza o teste e o gabarito (ref) para PNG (browser.exe --render)
#   2. compara os dois pixel a pixel
#   3. PASS se a diferenca <= limiar; FAIL caso contrario
#
# Uso:  .\reftest.ps1            (roda tudo)
#       .\reftest.ps1 -Keep      (mantem os PNGs gerados p/ inspecao)

param(
    [switch]$Keep,
    [int]$Width  = 200,
    [int]$Height = 400,
    [double]$Threshold = 0.1   # % maximo de pixels diferentes p/ passar
)

Add-Type -AssemblyName System.Drawing

$root    = $PSScriptRoot
$browser = Join-Path $root "browser.exe"
$dir     = Join-Path $root "tests\reftest"
$outdir  = Join-Path $root "tests\reftest\_out"
New-Item -ItemType Directory -Force -Path $outdir | Out-Null

# build automatico se faltar (odin test mexe no exe da raiz)
if (-not (Test-Path $browser)) {
    Write-Host "browser.exe nao encontrado; compilando..." -ForegroundColor Yellow
    & "C:\Odin\dist\odin.exe" build $root -out:$browser -extra-linker-flags:"/STACK:268435456" 2>&1 | Out-Null
    if (-not (Test-Path $browser)) { Write-Host "build falhou" -ForegroundColor Red; exit 1 }
}

# Compara dois PNGs; devolve o % de pixels diferentes.
function Compare-Png($a, $b) {
    $ba = [System.Drawing.Bitmap]::FromFile($a)
    $bb = [System.Drawing.Bitmap]::FromFile($b)
    try {
        if ($ba.Width -ne $bb.Width -or $ba.Height -ne $bb.Height) { return 100.0 }
        $diff = 0; $total = $ba.Width * $ba.Height
        for ($y = 0; $y -lt $ba.Height; $y++) {
            for ($x = 0; $x -lt $ba.Width; $x++) {
                $pa = $ba.GetPixel($x, $y); $pb = $bb.GetPixel($x, $y)
                # tolerancia por canal (antialiasing leve nao conta como diff)
                if ([Math]::Abs($pa.R - $pb.R) -gt 8 -or
                    [Math]::Abs($pa.G - $pb.G) -gt 8 -or
                    [Math]::Abs($pa.B - $pb.B) -gt 8) { $diff++ }
            }
        }
        return ($diff / $total) * 100.0
    } finally { $ba.Dispose(); $bb.Dispose() }
}

$tests = Get-ChildItem -Path $dir -Filter *.html |
    Where-Object { $_.Name -notlike "*-ref.html" }

$pass = 0; $fail = 0
foreach ($t in $tests) {
    $html = Get-Content $t.FullName -Raw
    $m = [regex]::Match($html, 'rel\s*=\s*"match"\s+href\s*=\s*"([^"]+)"')
    if (-not $m.Success) {
        $m = [regex]::Match($html, 'href\s*=\s*"([^"]+)"\s+rel\s*=\s*"match"')
    }
    if (-not $m.Success) { continue }  # nao e reftest

    $refName = $m.Groups[1].Value
    $refPath = Join-Path $dir $refName
    $testPng = Join-Path $outdir ($t.BaseName + ".png")
    $refPng  = Join-Path $outdir ($t.BaseName + "-ref.png")

    & $browser --render $t.FullName  $testPng $Width $Height | Out-Null
    & $browser --render $refPath     $refPng  $Width $Height | Out-Null

    if (-not (Test-Path $testPng) -or -not (Test-Path $refPng)) {
        Write-Host ("FAIL  {0}  (render falhou)" -f $t.Name) -ForegroundColor Red
        $fail++; continue
    }

    $d = Compare-Png $testPng $refPng
    if ($d -le $Threshold) {
        Write-Host ("PASS  {0}  ({1:N2}% diff)" -f $t.Name, $d) -ForegroundColor Green
        $pass++
    } else {
        Write-Host ("FAIL  {0}  ({1:N2}% diff)" -f $t.Name, $d) -ForegroundColor Red
        $fail++
    }
}

if (-not $Keep) { Remove-Item -Recurse -Force $outdir -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host ("Resultado: {0} PASS / {1} FAIL  (de {2})" -f $pass, $fail, ($pass + $fail)) -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
