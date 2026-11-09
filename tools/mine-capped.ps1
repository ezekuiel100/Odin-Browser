# Minerador com TETO DE MEMORIA. Mesmo trabalho do gap-miner.ps1 (roda
# `browser.exe --diagnose <url> <json>` sobre um corpus), mas com duas travas que
# o gap-miner.ps1 nao tem:
#
#   1. teto POR PROCESSO (-MemCapMB): um watchdog acompanha o working set do
#      browser.exe e o MATA se passar do teto. Vira MEMCAP no relatorio, do mesmo
#      jeito que um TIMEOUT -- o lote continua.
#   2. piso de RAM LIVRE do SISTEMA (-FreeFloorMB): se a memoria livre da maquina
#      cair abaixo do piso, mata o site atual e ABORTA o lote inteiro. E a rede de
#      seguranca contra o que o teto por processo nao previu (varios processos,
#      consumo fora do working set, outra coisa comendo a maquina junto).
#
# Existe porque `--diagnose` RENDERIZA de verdade: cada processo carrega o atlas
# de fontes (~930 MB de piso, ver memoria css-style-perf) e mais ~5,5 KB por no de
# Computed+Box. Num site pesado isso vai a varios GB e trava a maquina -- foi o que
# aconteceu rodando o corpus de 101 sites sem teto.
#
# ATENCAO: comentarios e strings em ASCII puro. PowerShell 5.1 le .ps1 sem BOM
# como ANSI; acento/travessao aqui quebram o PARSE do script (mesma armadilha
# anotada no build.bat).
#
# Uso:
#   .\tools\mine-capped.ps1                                  (corpus curto, teto 2 GB)
#   .\tools\mine-capped.ps1 -Sites tools\sites.txt           (corpus completo)
#   .\tools\mine-capped.ps1 -Browser X.exe -Out dir_a        (para minerar PAREADO)
#   .\tools\mine-capped.ps1 -Filter tailwind                 (so URLs que casam)
#
# Saidas: <Out>\*.json       (1 por site, MESMO formato do gap-miner.ps1 -- o
#                             `gap-miner.ps1 -Aggregate` consome sem mudanca)
#         <Out>\summary.tsv  (1 linha por site, para o DIFF PAREADO por nome)

param(
    [string]$Browser     = "",
    [string]$Out         = "",
    [string]$Sites       = "",
    [string]$Filter      = "",
    [int]$MemCapMB       = 2000,
    [int]$FreeFloorMB    = 2500,
    [int]$TimeoutSec     = 60,
    [int]$PollMs         = 100
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not $Browser) { $Browser = Join-Path $root "browser.exe" }
if (-not $Out)     { $Out     = Join-Path $root "_local\gap-mine" }
if (-not $Sites)   { $Sites   = Join-Path $root "tools\sites-short.txt" }

if (-not (Test-Path $Browser)) { Write-Host "browser nao encontrado: $Browser" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Sites))   { Write-Host "corpus nao encontrado: $Sites"   -ForegroundColor Red; exit 1 }

$logDir = Join-Path $Out "logs"
New-Item -ItemType Directory -Force -Path $Out    | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Safe-Name($url) {
    $n = $url -replace '^https?://', '' -replace '[^A-Za-z0-9._-]', '_'
    if ($n.Length -gt 100) { $n = $n.Substring(0, 100) }
    return $n.TrimEnd('_', '.')
}

function Write-FailJson($path, $url, $reason) {
    @{ url = $url; ok = $false; error = $reason } | ConvertTo-Json -Compress |
        Out-File -FilePath $path -Encoding utf8
}

function Free-MB {
    try { return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }
    catch { return 999999 }   # nao sabendo medir, NAO aborta o lote por engano
}

$urls = Get-Content $Sites -Encoding UTF8 | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }
if ($Filter) { $urls = @($urls | Where-Object { $_ -like "*$Filter*" }) }

$free0 = Free-MB
Write-Host ("Minerando {0} site(s) | teto {1} MB/processo | piso {2} MB livres | timeout {3}s" -f `
    $urls.Count, $MemCapMB, $FreeFloorMB, $TimeoutSec) -ForegroundColor Cyan
Write-Host ("browser: {0}" -f $Browser) -ForegroundColor DarkGray
Write-Host ("RAM livre agora: {0} MB" -f $free0) -ForegroundColor DarkGray
if ($free0 -lt $FreeFloorMB) {
    Write-Host "RAM livre JA esta abaixo do piso -- nao vou comecar." -ForegroundColor Red
    exit 1
}

$rows    = @()
$aborted = $false
$idx     = 0

foreach ($url in $urls) {
    $idx++
    $name = Safe-Name $url
    $json = Join-Path $Out    "$name.json"
    $elog = Join-Path $logDir "$name.log"
    $olog = Join-Path $logDir "$name.out.log"
    if (Test-Path $json) { Remove-Item $json -Force }

    $t0 = Get-Date
    $p = Start-Process -FilePath $Browser -ArgumentList @("--diagnose", $url, $json) `
         -RedirectStandardError $elog -RedirectStandardOutput $olog -NoNewWindow -PassThru

    # -- watchdog --------------------------------------------------------------
    $peak    = 0L
    $verdict = ""          # "" = terminou sozinho
    $ticks   = 0
    $freeEvery = [Math]::Max(1, [int](1000 / $PollMs))
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds $PollMs
        $ticks++
        try { $p.Refresh(); if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 } } catch { break }

        if ($peak -gt ($MemCapMB * 1MB)) { $verdict = "MEMCAP"; break }
        if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) { $verdict = "TIMEOUT"; break }

        # piso do sistema: checado a cada ~1s (a chamada CIM e cara p/ o poll)
        if (($ticks % $freeEvery) -eq 0) {
            if ((Free-MB) -lt $FreeFloorMB) { $verdict = "ABORT_RAM"; break }
        }
    }
    if ($verdict -ne "") {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(5000) | Out-Null } catch {}
        Start-Sleep -Milliseconds 300   # solta os handles dos redirects
    }
    $secs   = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $peakMB = [int]($peak / 1MB)

    if ($verdict -eq "ABORT_RAM") {
        Write-FailJson $json $url "ABORT_RAM (piso de $FreeFloorMB MB)"
        Write-Host ("  [{0,3}/{1}] ABORT_RAM {2} -- RAM livre abaixo do piso, PARANDO o lote" -f $idx, $urls.Count, $url) -ForegroundColor Red
        $rows += [pscustomobject]@{ url=$url; status="ABORT_RAM"; boxes=""; page_h=""; css_unknown=""; js_uncaught=""; peak_mb=$peakMB; secs=$secs }
        $aborted = $true
        break
    }
    if ($verdict -eq "MEMCAP") {
        Write-FailJson $json $url "MEMCAP (${MemCapMB}MB)"
        Write-Host ("  [{0,3}/{1}] MEMCAP   {2} (pico {3} MB, {4}s)" -f $idx, $urls.Count, $url, $peakMB, $secs) -ForegroundColor Magenta
        $rows += [pscustomobject]@{ url=$url; status="MEMCAP"; boxes=""; page_h=""; css_unknown=""; js_uncaught=""; peak_mb=$peakMB; secs=$secs }
        continue
    }
    if ($verdict -eq "TIMEOUT") {
        Write-FailJson $json $url "TIMEOUT (${TimeoutSec}s)"
        Write-Host ("  [{0,3}/{1}] TIMEOUT  {2} (pico {3} MB)" -f $idx, $urls.Count, $url, $peakMB) -ForegroundColor Magenta
        $rows += [pscustomobject]@{ url=$url; status="TIMEOUT"; boxes=""; page_h=""; css_unknown=""; js_uncaught=""; peak_mb=$peakMB; secs=$secs }
        continue
    }

    if (-not (Test-Path $json)) {
        Write-FailJson $json $url ("CRASH (exit={0})" -f $p.ExitCode)
        Write-Host ("  [{0,3}/{1}] CRASH    {2} (exit={3}, pico {4} MB)" -f $idx, $urls.Count, $url, $p.ExitCode, $peakMB) -ForegroundColor Red
        $rows += [pscustomobject]@{ url=$url; status="CRASH"; boxes=""; page_h=""; css_unknown=""; js_uncaught=""; peak_mb=$peakMB; secs=$secs }
        continue
    }

    try { $r = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $r = $null }
    if ($null -eq $r -or -not $r.ok) {
        $why = "json ilegivel"
        if ($r) { $why = $r.error }
        Write-Host ("  [{0,3}/{1}] FAIL     {2} ({3}, pico {4} MB)" -f $idx, $urls.Count, $url, $why, $peakMB) -ForegroundColor Red
        $rows += [pscustomobject]@{ url=$url; status="FAIL"; boxes=""; page_h=""; css_unknown=""; js_uncaught=""; peak_mb=$peakMB; secs=$secs }
        continue
    }

    $nCss = @($r.css_unknown.PSObject.Properties).Count
    $tag  = "OK"
    $col  = "Green"
    if ($r.blocked) { $tag = "BLOCKED"; $col = "DarkYellow" }
    elseif ($r.boxes -lt 12 -or $r.page_h -lt 100) { $tag = "BLANK"; $col = "Yellow" }
    Write-Host ("  [{0,3}/{1}] {2,-8} {3} ({4} caixas, h={5}, {6} css?, {7} js!, pico {8} MB, {9}s)" -f `
        $idx, $urls.Count, $tag, $url, $r.boxes, $r.page_h, $nCss, $r.js_uncaught_total, $peakMB, $secs) -ForegroundColor $col
    $rows += [pscustomobject]@{ url=$url; status=$tag; boxes=$r.boxes; page_h=$r.page_h;
                                css_unknown=$nCss; js_uncaught=$r.js_uncaught_total; peak_mb=$peakMB; secs=$secs }
}

# -- resumo --------------------------------------------------------------------
$tsv = Join-Path $Out "summary.tsv"
$rows | Export-Csv -Path $tsv -Delimiter "`t" -NoTypeInformation -Encoding UTF8

$peaks = @($rows | Where-Object { $_.peak_mb -gt 0 } | ForEach-Object { $_.peak_mb })
$maxPeak = 0
if ($peaks.Count -gt 0) { $maxPeak = ($peaks | Measure-Object -Maximum).Maximum }

Write-Host ""
Write-Host ("resumo -> {0}" -f $tsv) -ForegroundColor Cyan
$rows | Group-Object status | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Name, $_.Count) }
Write-Host ("  pico MAXIMO de um processo: {0} MB (teto {1} MB)" -f $maxPeak, $MemCapMB) -ForegroundColor DarkGray
Write-Host ("  RAM livre no fim: {0} MB (era {1} MB)" -f (Free-MB), $free0) -ForegroundColor DarkGray
if ($aborted) { Write-Host "LOTE ABORTADO pelo piso de RAM -- resultado INCOMPLETO." -ForegroundColor Red; exit 2 }
