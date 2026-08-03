# Baixa os arquivos .dat de tree-construction do html5lib-tests
# (html5lib/html5lib-tests) — a suite padrao de conformancia de PARSING de HTML
# que praticamente todo navegador usa. Cada .dat tem varios casos no formato:
#   #data        <- o HTML de entrada
#   #errors      <- erros de parse esperados (ignoramos)
#   #document    <- a arvore DOM esperada, serializada
#
# Uso:  .\tools\fetch-html5lib.ps1            (baixa todos os .dat)
#       .\tools\fetch-html5lib.ps1 -Only tests1,tests2   (so alguns arquivos)
#
# Saida: tests\html5lib\*.dat

param(
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"
$root    = Split-Path $PSScriptRoot -Parent
$outDir  = Join-Path $root "tests\html5lib"
# A pasta tree-construction FOI REMOVIDA do master do html5lib-tests em 2026-06-26
# (commit 224991e). Fixamos a SHA do commit-pai (9329e64), o ultimo estado com a
# pasta intacta (57 .dat) — fonte reprodutivel. O raw serve nessa SHA.
$ref     = "9329e64694e7835d0dcff9811e22856ef6ad16f9"
$rawBase = "https://raw.githubusercontent.com/html5lib/html5lib-tests/$ref/tree-construction"
$apiBase = "https://api.github.com/repos/html5lib/html5lib-tests/contents/tree-construction?ref=$ref"
$UA      = @{ "User-Agent" = "odin-browser-html5lib-fetch" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "=== html5lib tree-construction ===" -ForegroundColor Cyan
try {
    $listing = Invoke-RestMethod -Uri $apiBase -Headers $UA -TimeoutSec 30
} catch {
    Write-Host "listagem falhou: $($_.Exception.Message)" -ForegroundColor Red; exit 1
}

$files = $listing | Where-Object { $_.type -eq 'file' -and $_.name -match '\.dat$' }
if ($Only.Count -gt 0) {
    $files = $files | Where-Object { $n = ($_.name -replace '\.dat$',''); $Only -contains $n -or $Only -contains $_.name }
}

$count = 0
foreach ($f in $files) {
    try {
        $c = (Invoke-WebRequest -Uri "$rawBase/$($f.name)" -Headers $UA -UseBasicParsing -TimeoutSec 30).Content
    } catch { Write-Host "  falhou: $($f.name)" -ForegroundColor Red; continue }
    # grava com LF (o formato .dat e sensivel a \n; evita \r\n do Windows)
    $c = $c -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Join-Path $outDir $f.name), $c)
    Write-Host ("  + {0}" -f $f.name) -ForegroundColor Green
    $count++
}

Write-Host ("`nTotal: {0} arquivos .dat em {1}" -f $count, $outDir) -ForegroundColor Cyan
Write-Host "Rode:  .\html5lib-test.ps1" -ForegroundColor Cyan
