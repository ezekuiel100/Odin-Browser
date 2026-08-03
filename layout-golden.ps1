# Harness de golden-tests da arvore de layout (estilo Ladybird layout-tree dump).
#
# Para cada tests\layout\*.html:
#   browser.exe --dumplayout <html> <tmp.txt> 800 600
# e compara o dump com tests\layout\<nome>.expected.txt (o "golden" commitado).
# Um diff textual acusa QUALQUER regressao de layout (largura colapsada, caixa
# que muda de posicao/tamanho) de forma precisa -- ao contrario do reftest de
# pixel. Alimentado por casos reduzidos de quebra REAL (o loop do Ladybird:
# site quebra -> reduz -> golden permanente).
#
# Uso:  .\layout-golden.ps1              (roda; compara com os goldens)
#       .\layout-golden.ps1 -Update      (regera os goldens; use ao ADICIONAR
#                                          um caso ou apos mudanca de layout
#                                          INTENCIONAL, revisando o diff antes)
#       .\layout-golden.ps1 -Filter grid (so fixtures cujo nome casa)
#       .\layout-golden.ps1 -Verbose     (mostra o diff completo de cada FAIL)
#       .\layout-golden.ps1 -Browser browser_ctl.exe  (A/B contra outro binario)
#
# -Browser existe para o A/B: com mais de uma frente mexendo na arvore, comparar
# contra o golden commitado atribui a QUEM RODOU tudo que mudou desde que ele foi
# gerado. Rodar os dois binarios e diffar as duas saidas isola a mudanca.

param(
    [switch]$Update,
    [string]$Filter = "",
    [switch]$Verbose,
    [int]$Width  = 800,
    [int]$Height = 600,
    [string]$Browser = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = if ($Browser -ne "") {
    if ([System.IO.Path]::IsPathRooted($Browser)) { $Browser } else { Join-Path $root $Browser }
} else { Join-Path $root "browser.exe" }
$dir  = Join-Path $root "tests\layout"
$tmp  = Join-Path $env:TEMP "layout-golden-tmp.txt"

if (-not (Test-Path $exe)) {
    Write-Host "browser.exe ausente - buildar primeiro" -ForegroundColor Red
    exit 1
}

$fixtures = Get-ChildItem -Path $dir -Filter *.html | Sort-Object Name
if ($Filter) { $fixtures = $fixtures | Where-Object { $_.Name -like "*$Filter*" } }

$pass = 0; $fail = 0; $new = 0
$failed = @()

foreach ($fx in $fixtures) {
    $name     = [IO.Path]::GetFileNameWithoutExtension($fx.Name)
    $expected = Join-Path $dir "$name.expected.txt"

    & $exe --dumplayout $fx.FullName $tmp $Width $Height 2>$null | Out-Null
    if (-not (Test-Path $tmp)) {
        Write-Host ("  {0,-28} ERRO (sem dump)" -f $name) -ForegroundColor Red
        $fail++; $failed += $name; continue
    }
    $got = Get-Content $tmp -Raw -Encoding UTF8

    if ($Update -or -not (Test-Path $expected)) {
        Set-Content -Path $expected -Value $got -Encoding UTF8 -NoNewline
        if ($Update) { $tag = "GRAVADO" } else { $tag = "NOVO" }
        Write-Host ("  {0,-28} {1}" -f $name, $tag) -ForegroundColor Yellow
        $new++; continue
    }

    $want = Get-Content $expected -Raw -Encoding UTF8
    if ($got -eq $want) {
        Write-Host ("  {0,-28} PASS" -f $name) -ForegroundColor Green
        $pass++
    } else {
        Write-Host ("  {0,-28} DIFF" -f $name) -ForegroundColor Red
        $fail++; $failed += $name
        $gl = $got  -split "`r?`n"
        $wl = $want -split "`r?`n"
        $max = [Math]::Max($gl.Count, $wl.Count)
        $shown = 0
        for ($i = 0; $i -lt $max; $i++) {
            if ($i -lt $wl.Count) { $a = $wl[$i] } else { $a = "" }
            if ($i -lt $gl.Count) { $b = $gl[$i] } else { $b = "" }
            if ($a -ne $b) {
                Write-Host ("      L{0}  - {1}" -f ($i+1), $a) -ForegroundColor DarkGray
                Write-Host ("      L{0}  + {1}" -f ($i+1), $b) -ForegroundColor DarkYellow
                $shown++
                if (-not $Verbose -and $shown -ge 6) {
                    Write-Host "      ... (use -Verbose p/ o diff completo)"
                    break
                }
            }
        }
    }
}

Write-Host ""
Write-Host ("=== layout-golden: {0} PASS / {1} FAIL / {2} gravado(s) (de {3}) ===" -f $pass, $fail, $new, $fixtures.Count)
if ($failed.Count -gt 0) {
    Write-Host ("FAIL: " + ($failed -join ", ")) -ForegroundColor Red
}
if ($fail -gt 0) { exit 1 } else { exit 0 }
