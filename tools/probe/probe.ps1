# Sonda de CAPACIDADE do motor JS: mede o que a engine entrega, feature a feature.
#
# Complementa as outras suites em vez de repeti-las:
#   - Test262  mede CONFORMIDADE da linguagem contra a spec (e boa parte do FAIL
#              la e metadata pedante, nao bug)
#   - WPT      mede LAYOUT/CSS
#   - esta     mede se a API que um SITE REAL chama devolve o que ele espera
#
# O achado que justifica o formato: o grosso do que falta NAO lanca TypeError --
# e stub que devolve valor neutro (getComputedStyle vazio, rect zerado, observer
# que nunca dispara). A pagina nao quebra, ela fica ERRADA EM SILENCIO. Por isso
# cada teste EXERCITA a API e confere o RESULTADO; sonda por `typeof x === "function"`
# marca os quatro stubs acima como OK (foi o erro da auditoria de 2026-07-20).
#
# Arquivos:
#   probe_lang.js        placar da LINGUAGEM   (roda por --js262, sem janela)
#   probe_dom.html       placar do DOM/web     (roda por --render)
#   probe_lang_dump.js   diagnostico: imprime o VALOR CRU (para desambiguar falha)
#   probe_dom_dump.html  diagnostico: idem, e nas 3 FASES (parse/setTimeout/rAF),
#                        que e o que distingue "layout ainda nao rodou" de "sempre 0"
#   probe_module*.       repro do modulo que se auto-importa (PRECISA de HTTP)
#
# Veredito: nao ha "tudo verde" aqui -- o placar E o inventario de gaps. O que vale
# como gate e o DIFF POR NOME contra baseline.txt (mesma disciplina do
# wpt-baseline-fails.txt): sai 1 se aparecer gap NOVO.
#
# Uso:
#   .\tools\probe\probe.ps1                    (lang + dom + module, diff vs baseline)
#   .\tools\probe\probe.ps1 -Only lang
#   .\tools\probe\probe.ps1 -Dump              (so o diagnostico de valor cru)
#   .\tools\probe\probe.ps1 -ShowOk            (lista tambem o que passou)
#   .\tools\probe\probe.ps1 -Browser x.exe     (para comparar DOIS binarios)
#   .\tools\probe\probe.ps1 -WriteBaseline     (regrava baseline.txt com esta rodada)
#
# ATENCAO: comentarios e strings em ASCII puro. PowerShell 5.1 le .ps1 sem BOM
# como ANSI e acento aqui quebra o PARSE (mesma armadilha do mine-capped.ps1).

param(
    [ValidateSet("all", "lang", "dom", "module")]
    [string]$Only = "all",
    [string]$Browser = "",
    [switch]$Dump,
    [switch]$ShowOk,
    [switch]$WriteBaseline,
    [int]$Port = 8731,
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $here)
if (-not $Browser) { $Browser = Join-Path $root "browser.exe" }
if (-not (Test-Path $Browser)) {
    Write-Host "browser.exe nao encontrado em $Browser. Rode build.bat primeiro." -ForegroundColor Red
    exit 1
}
$outDir = Join-Path $here "out"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# ---- roda o exe capturando stdout/stderr em ARQUIVO ---------------------------
# (Start-Process em vez de `& exe`: em PS 5.1 redirecionar stderr de nativa no
#  pipeline vira NativeCommandError e suja o $? mesmo com exit 0.)
function Invoke-Probe($argList, $tag) {
    $so = Join-Path $outDir "$tag.stdout.txt"
    $se = Join-Path $outDir "$tag.stderr.txt"
    $p = Start-Process -FilePath $Browser -ArgumentList $argList -NoNewWindow -PassThru `
                       -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        Write-Host "  TIMEOUT ($TimeoutSec s) em $tag" -ForegroundColor Red
        return @()
    }
    if (-not (Test-Path $so)) { return @() }
    return @(Get-Content $so)
}

# ---- placar: le as linhas "STATUS<TAB>categoria<TAB>nome[<TAB>detalhe]" -------
function Show-Scorecard($lines, $suite) {
    $rows = @()
    foreach ($l in $lines) {
        if ($l -match "^(OK|BAD|FAIL)`t([^`t]*)`t([^`t]*)`t?(.*)$") {
            $rows += [pscustomobject]@{
                Suite = $suite; Status = $Matches[1]; Cat = $Matches[2]
                Name = $Matches[3]; Detail = $Matches[4]
            }
        }
    }
    if ($rows.Count -eq 0) {
        Write-Host "  nenhuma linha de resultado -- a sonda rodou? veja $outDir\$suite.stderr.txt" -ForegroundColor Red
        return $rows
    }
    foreach ($g in ($rows | Group-Object Cat)) {
        $ok = @($g.Group | Where-Object { $_.Status -eq "OK" }).Count
        $col = "Yellow"
        if ($ok -eq $g.Count) { $col = "Green" }
        if ($ok -eq 0)        { $col = "Red" }
        Write-Host ("  {0,-16} {1,3}/{2,-3} OK" -f $g.Name, $ok, $g.Count) -ForegroundColor $col
        foreach ($r in $g.Group) {
            if ($r.Status -eq "OK") {
                if ($ShowOk) { Write-Host ("      OK   " + $r.Name) -ForegroundColor DarkGray }
                continue
            }
            $d = ""
            if ($r.Detail) { $d = "   " + $r.Detail }
            Write-Host ("      " + $r.Status.PadRight(4) + " " + $r.Name + $d) -ForegroundColor Gray
        }
    }
    return $rows
}

$all = @()

# ---- LINGUAGEM ----------------------------------------------------------------
if ($Only -eq "all" -or $Only -eq "lang") {
    Write-Host "`n=== LINGUAGEM (--js262, sem janela) ===" -ForegroundColor Cyan
    $lines = Invoke-Probe @("--js262", (Join-Path $here "probe_lang.js")) "lang"
    $all += Show-Scorecard $lines "lang"
}

# ---- DOM ----------------------------------------------------------------------
if ($Only -eq "all" -or $Only -eq "dom") {
    Write-Host "`n=== DOM / WEB (--render) ===" -ForegroundColor Cyan
    $png = Join-Path $outDir "probe_dom.png"
    # 6 frames: o bloco "pos-layout" da sonda roda num setTimeout, e com 1 frame
    # ele nao dispararia (as perguntas de geometria/estilo resolvido mediriam o
    # momento errado -- ver o comentario dentro do probe_dom.html).
    $lines = Invoke-Probe @("--render", (Join-Path $here "probe_dom.html"), $png, "800", "600", "-1", "-1", "6") "dom"
    $all += Show-Scorecard $lines "dom"
}

# ---- MODULO (precisa de HTTP) --------------------------------------------------
$modStatus = ""
if ($Only -eq "all" -or $Only -eq "module") {
    Write-Host "`n=== MODULO que se auto-importa (via HTTP) ===" -ForegroundColor Cyan
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "  SKIP: python nao encontrado (o repro precisa de servidor; de file:// o <script src> nao carrega)" -ForegroundColor DarkYellow
        $modStatus = "SKIP"
    } else {
        $srv = Start-Process -FilePath $py.Source -ArgumentList @("-m", "http.server", "$Port") `
                             -WorkingDirectory $here -PassThru -WindowStyle Hidden
        try {
            $up = $false
            for ($i = 0; $i -lt 25; $i++) {
                try {
                    $c = New-Object System.Net.Sockets.TcpClient
                    $c.Connect("127.0.0.1", $Port); $c.Close(); $up = $true; break
                } catch { Start-Sleep -Milliseconds 200 }
            }
            if (-not $up) {
                Write-Host "  SKIP: servidor nao subiu na porta $Port" -ForegroundColor DarkYellow
                $modStatus = "SKIP"
            } else {
                $png = Join-Path $outDir "probe_module.png"
                $lines = Invoke-Probe @("--render", "http://localhost:$Port/probe_module.html", $png, "400", "300") "module"
                $evals  = @($lines | Where-Object { $_ -match "MODPROBE eval" }).Count
                $inline = @($lines | Where-Object { $_ -match "MODPROBE inline" }).Count
                $vazio  = @($lines | Where-Object { $_ -match "ns VAZIO" }).Count
                foreach ($l in ($lines | Where-Object { $_ -match "MODPROBE" })) { Write-Host ("      " + $l) -ForegroundColor Gray }
                if ($inline -eq 0) {
                    Write-Host "  INCONCLUSIVO: nem o script inline rodou" -ForegroundColor Red
                    $modStatus = "ERRO"
                } elseif ($evals -eq 1 -and $vazio -eq 0) {
                    Write-Host "  OK: avaliado 1x e namespace completo" -ForegroundColor Green
                    $modStatus = "OK"
                } else {
                    Write-Host ("  GAP: modulo avaliado {0}x (esperado 1) / namespace vazio em {1} avaliacao(oes)" -f $evals, $vazio) -ForegroundColor Yellow
                    $modStatus = "GAP"
                }
            }
        } finally {
            try { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# ---- DIAGNOSTICO de valor cru (opcional) ---------------------------------------
if ($Dump -and ($Only -eq "all" -or $Only -eq "lang")) {
    Write-Host "`n=== DUMP: valores crus da LINGUAGEM ===" -ForegroundColor Cyan
    $lines = Invoke-Probe @("--js262", (Join-Path $here "probe_lang_dump.js")) "lang_dump"
    foreach ($l in $lines) { if ($l -match "^V`t|^===") { Write-Host ("  " + $l) -ForegroundColor Gray } }
}
if ($Dump -and ($Only -eq "all" -or $Only -eq "dom")) {
    Write-Host "`n=== DUMP: valores crus do DOM (3 fases) ===" -ForegroundColor Cyan
    $png = Join-Path $outDir "probe_dom_dump.png"
    $lines = Invoke-Probe @("--render", (Join-Path $here "probe_dom_dump.html"), $png, "800", "600", "-1", "-1", "6") "dom_dump"
    foreach ($l in $lines) { if ($l -match "^V`t|^---|^===") { Write-Host ("  " + $l) -ForegroundColor Gray } }
}

if ($all.Count -eq 0) {
    if ($Dump) { exit 0 }
    Write-Host "`nnenhum placar coletado." -ForegroundColor Red
    exit 1
}

# ---- TOTAIS --------------------------------------------------------------------
$OK  = @($all | Where-Object { $_.Status -eq "OK" }).Count
$BAD = @($all | Where-Object { $_.Status -eq "BAD" }).Count
$FL  = @($all | Where-Object { $_.Status -eq "FAIL" }).Count
Write-Host ("`nTOTAL: {0} OK / {1} BAD / {2} FAIL  (de {3})" -f $OK, $BAD, $FL, $all.Count) -ForegroundColor Cyan
if ($modStatus) { Write-Host ("MODULO: " + $modStatus) -ForegroundColor Cyan }

# ---- conjunto NOMEADO + diff contra baseline -----------------------------------
# Chave = suite|categoria|nome, SEM o detalhe: o valor observado varia (got=...) e
# so o conjunto de nomes prova ausencia de regressao.
$now = @($all | Where-Object { $_.Status -ne "OK" } | ForEach-Object { "$($_.Suite)|$($_.Cat)|$($_.Name)" } | Sort-Object)
$nowFile = Join-Path $here "probe_now.txt"
[System.IO.File]::WriteAllLines($nowFile, $now)   # sem BOM

$baseFile = Join-Path $here "baseline.txt"
if ($WriteBaseline) {
    [System.IO.File]::WriteAllLines($baseFile, $now)
    Write-Host ("baseline.txt regravado com {0} gaps nomeados." -f $now.Count) -ForegroundColor Cyan
    exit 0
}
if (-not (Test-Path $baseFile)) {
    Write-Host "baseline.txt nao existe -- rode com -WriteBaseline para criar." -ForegroundColor DarkYellow
    exit 0
}
if ($Only -ne "all") {
    Write-Host "diff vs baseline pulado (-Only $Only cobre so parte do conjunto)." -ForegroundColor DarkYellow
    exit 0
}

$base = @(Get-Content $baseFile | Where-Object { $_ -ne "" })
$novos      = @($now  | Where-Object { $base -notcontains $_ })
$consertados = @($base | Where-Object { $now  -notcontains $_ })

Write-Host "`n=== DIFF vs baseline.txt ===" -ForegroundColor Cyan
if ($consertados.Count -gt 0) {
    Write-Host ("  CONSERTADOS ({0}):" -f $consertados.Count) -ForegroundColor Green
    foreach ($c in $consertados) { Write-Host ("    + " + $c) -ForegroundColor Green }
}
if ($novos.Count -gt 0) {
    Write-Host ("  NOVOS -- possivel REGRESSAO ({0}):" -f $novos.Count) -ForegroundColor Red
    foreach ($n in $novos) { Write-Host ("    - " + $n) -ForegroundColor Red }
    exit 1
}
if ($consertados.Count -eq 0) { Write-Host "  identico ao baseline." -ForegroundColor Green }
exit 0
