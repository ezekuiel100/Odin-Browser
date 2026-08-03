# Baixa os arquivos .test (JSON) de tokenizer do html5lib-tests. Ao contrario de
# tree-construction, a pasta tokenizer AINDA EXISTE no master. Cada .test tem:
#   {"tests":[ {"description","input","output":[...],
#               "initialStates"?, "lastStartTag"?, "doubleEscaped"?} ]}
#
# Uso:  .\tools\fetch-html5lib-tokenizer.ps1
#
# Saida: tests\html5lib-tokenizer\*.test

$ErrorActionPreference = "Stop"
$root    = Split-Path $PSScriptRoot -Parent
$outDir  = Join-Path $root "tests\html5lib-tokenizer"
$rawBase = "https://raw.githubusercontent.com/html5lib/html5lib-tests/master/tokenizer"
$apiBase = "https://api.github.com/repos/html5lib/html5lib-tests/contents/tokenizer?ref=master"
$UA      = @{ "User-Agent" = "odin-browser-html5lib-tok-fetch" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "=== html5lib tokenizer ===" -ForegroundColor Cyan
try {
    $listing = Invoke-RestMethod -Uri $apiBase -Headers $UA -TimeoutSec 30
} catch {
    Write-Host "listagem falhou: $($_.Exception.Message)" -ForegroundColor Red; exit 1
}

$files = $listing | Where-Object { $_.type -eq 'file' -and $_.name -match '\.test$' }
$count = 0
foreach ($f in $files) {
    try {
        $c = (Invoke-WebRequest -Uri "$rawBase/$($f.name)" -Headers $UA -UseBasicParsing -TimeoutSec 30).Content
    } catch { Write-Host "  falhou: $($f.name)" -ForegroundColor Red; continue }
    $c = $c -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Join-Path $outDir $f.name), $c, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  + {0}" -f $f.name) -ForegroundColor Green
    $count++
}

Write-Host ("`nTotal: {0} arquivos .test em {1}" -f $count, $outDir) -ForegroundColor Cyan
Write-Host "Rode:  .\html5lib-tokenizer.ps1" -ForegroundColor Cyan
