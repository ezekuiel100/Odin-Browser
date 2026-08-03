# Roda todos os testes do projeto. Uso:  .\test.ps1
$ErrorActionPreference = "Continue"
$odin = "C:\Odin\dist\odin.exe"
$root = $PSScriptRoot

$pacotes = @("src/css", "src/ui", "src/js", "src/html", "src/net", "src/brotli", "src/woff2")
$falhou = $false

foreach ($p in $pacotes) {
    Write-Host "`n=== Testando $p ===" -ForegroundColor Cyan
    # src/ui e src/css rodam em UMA thread. Os pacotes tem estado GLOBAL de verdade
    # (em css, `g_dark_scheme`: dois testes de light-dark() alternam a MESMA global
    # e um le o valor do outro -- "expected 0x101820, got 0xd6efd"). Em ui: o cache
    # `g_images`, o contador de frames `g_frame`, a fonte de emoji carregada sob
    # demanda), e o runner do Odin paraleliza os testes por padrao. Qualquer teste
    # de layout que use <img> chama image_get e escreve em `g_images` enquanto o
    # teste de eviccao (m179) assume controle exclusivo dele -> falha intermitente,
    # em teste que nada tem a ver com a mudanca em analise. Medido: 10 rodadas
    # paralelas falham de vez em quando, 8 rodadas com 1 thread ficam verdes.
    # Custo: ~2,5s em vez de ~0,15s no pacote ui. Vale o determinismo.
    $argv = @("test", (Join-Path $root $p))
    if ($p -eq "src/ui" -or $p -eq "src/css") { $argv += "-define:ODIN_TEST_THREADS=1" }
    & $odin @argv 2>&1 |
        Select-String -Pattern "Finished|failed|\[ERROR\]" |
        ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $falhou = $true }
}

Write-Host ""
if ($falhou) {
    Write-Host "ALGUNS TESTES FALHARAM" -ForegroundColor Red
    exit 1
} else {
    Write-Host "TODOS OS TESTES PASSARAM" -ForegroundColor Green
    exit 0
}
