# Minerador de gaps: roda `browser.exe --diagnose <url> <json>` sobre um corpus
# de sites reais (tools\sites.txt) e AGREGA os relatorios num ranking do que
# mais quebra: propriedades CSS nao suportadas (por n. de sites), excecoes JS
# nao capturadas, APIs/globais faltando, sites em branco, timeouts e crashes.
# Transforma "o que falta no navegador?" em numeros: conserta primeiro o que
# desbloqueia mais sites.
#
# Uso:  .\gap-miner.ps1                     (minera tudo e agrega)
#       .\gap-miner.ps1 -Filter globo       (so URLs que contem o texto)
#       .\gap-miner.ps1 -Resume             (pula sites ja minerados)
#       .\gap-miner.ps1 -Aggregate          (nao roda nada; so re-agrega os JSONs)
#       .\gap-miner.ps1 -Sites minha.txt    (corpus alternativo)
#       .\gap-miner.ps1 -TimeoutSec 120 -Top 40
#
# Saidas: _local\gap-mine\*.json + _local\gap-mine\logs\*.log
#         _local\reports\gap-report.md (relatorio agregado)
#
# AVISO (ver memoria M73): o Defender pode quarentenar um browser.exe recem-
# buildado apos as primeiras conexoes HTTPS. O minerador detecta o sumico do
# exe e aborta com aviso; use -Resume p/ continuar de onde parou.

param(
    [string]$Sites = "",
    [string]$Filter = "",
    [int]$TimeoutSec = 90,
    [int]$Top = 30,
    [switch]$Aggregate,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

$root    = $PSScriptRoot
$browser = Join-Path $root "browser.exe"
$mineDir = Join-Path $root "_local\gap-mine"
$logDir  = Join-Path $mineDir "logs"
$report  = Join-Path $root "_local\reports\gap-report.md"
if (-not $Sites) { $Sites = Join-Path $root "tools\sites.txt" }

if (-not $Aggregate) {
    if (-not (Test-Path $browser)) {
        Write-Host "browser.exe nao encontrado. Rode build.bat primeiro." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $Sites)) {
        Write-Host "corpus nao encontrado: $Sites" -ForegroundColor Red
        exit 1
    }
}
New-Item -ItemType Directory -Force -Path $mineDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $report -Parent) | Out-Null

# URL -> nome de arquivo seguro e estavel (mesma URL = mesmo json; -Resume usa isso)
function Safe-Name($url) {
    $n = $url -replace '^https?://', '' -replace '[^A-Za-z0-9._-]', '_'
    if ($n.Length -gt 100) { $n = $n.Substring(0, 100) }
    return $n.TrimEnd('_', '.')
}

# Grava um json de falha (timeout/crash) no MESMO formato do browser.exe, assim
# a agregacao le tudo de gap-mine\*.json sem estado extra.
function Write-FailJson($path, $url, $reason) {
    @{ url = $url; ok = $false; error = $reason } | ConvertTo-Json -Compress |
        Out-File -FilePath $path -Encoding utf8
}

# ── Mineracao ─────────────────────────────────────────────────────────────────
if (-not $Aggregate) {
    $urls = Get-Content $Sites -Encoding UTF8 | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
    if ($Filter) { $urls = @($urls | Where-Object { $_ -like "*$Filter*" }) }

    Write-Host ("Minerando {0} site(s), timeout {1}s cada..." -f $urls.Count, $TimeoutSec) -ForegroundColor Cyan
    $idx = 0
    foreach ($url in $urls) {
        $idx++
        $name = Safe-Name $url
        $json = Join-Path $mineDir  "$name.json"
        $log  = Join-Path $logDir   "$name.log"
        $olog = Join-Path $logDir   "$name.out.log"

        if ($Resume -and (Test-Path $json)) {
            Write-Host ("  [{0,3}/{1}] SKIP     {2} (ja minerado)" -f $idx, $urls.Count, $url) -ForegroundColor DarkGray
            continue
        }
        if (-not (Test-Path $browser)) {
            Write-Host "`nbrowser.exe SUMIU no meio da mineracao — provavelmente o Defender quarentenou (ver memoria M73)." -ForegroundColor Red
            Write-Host "Restaure/exclua da quarentena, rebuilde se preciso, e continue com:  .\gap-miner.ps1 -Resume" -ForegroundColor Yellow
            exit 1
        }
        if (Test-Path $json) { Remove-Item $json -Force }

        $t0 = Get-Date
        $p = Start-Process -FilePath $browser -ArgumentList @("--diagnose", $url, $json) `
             -RedirectStandardError $log -RedirectStandardOutput $olog -NoNewWindow -PassThru
        $done = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $done) {
            try { $p.Kill() } catch {}
            Start-Sleep -Milliseconds 300   # solta os handles dos redirects
            Write-FailJson $json $url "TIMEOUT (${TimeoutSec}s)"
            Write-Host ("  [{0,3}/{1}] TIMEOUT  {2}" -f $idx, $urls.Count, $url) -ForegroundColor Magenta
            continue
        }
        $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

        if (-not (Test-Path $json)) {
            # saiu sem gravar json = crash do processo (o fetch-fail grava ok:false)
            Write-FailJson $json $url ("CRASH (exit={0})" -f $p.ExitCode)
            Write-Host ("  [{0,3}/{1}] CRASH    {2} (exit={3}, {4}s) — stderr: {5}" -f $idx, $urls.Count, $url, $p.ExitCode, $secs, $log) -ForegroundColor Red
            continue
        }
        try { $r = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $r = $null }
        if ($null -eq $r -or -not $r.ok) {
            $why = if ($r) { $r.error } else { "json ilegivel" }
            Write-Host ("  [{0,3}/{1}] FAIL     {2} ({3})" -f $idx, $urls.Count, $url, $why) -ForegroundColor Red
        } else {
            $blank = ($r.boxes -lt 12 -or $r.page_h -lt 100)
            if ($r.blocked)   { $tag = "BLOCKED"; $col = "DarkYellow" }
            elseif ($blank)   { $tag = "BLANK";   $col = "Yellow" }
            else              { $tag = "OK";      $col = "Green" }
            Write-Host ("  [{0,3}/{1}] {2,-8} {3} ({4} caixas, h={5}, {6} css?, {7} js!, {8}s)" -f `
                $idx, $urls.Count, $tag, $url, $r.boxes, $r.page_h, `
                @($r.css_unknown.PSObject.Properties).Count, $r.js_uncaught_total, $secs) -ForegroundColor $col
        }
    }
}

# ── Agregacao ─────────────────────────────────────────────────────────────────
$reports = @()
foreach ($f in (Get-ChildItem $mineDir -Filter *.json | Sort-Object Name)) {
    try { $reports += (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Host "  json ilegivel: $($f.Name)" -ForegroundColor Yellow }
}
if ($reports.Count -eq 0) {
    Write-Host "nenhum relatorio em $mineDir — rode sem -Aggregate primeiro." -ForegroundColor Red
    exit 1
}

function Status-Of($r) {
    # anti-bot / challenge de WAF: NAO e gap da engine (o servidor nunca manda o
    # site). Classificado no --diagnose (http 202/4xx/5xx, corpo minusculo).
    if ($r.blocked) { return "BLOCKED" }
    if (-not $r.ok) {
        if ($r.error -like "TIMEOUT*") { return "TIMEOUT" }
        if ($r.error -like "CRASH*")   { return "CRASH" }
        return "LOAD_FAIL"
    }
    # altura util = a MAIOR entre a em-fluxo (page_h) e a extensao real do conteudo
    # (content_h, que inclui caixas fixed/absolute). Usar so page_h dava BLANK
    # falso em bandcamp/cnn, que renderizam dentro de wrappers posicionados.
    $h = $r.page_h
    if ($null -ne $r.content_h -and $r.content_h -gt $h) { $h = $r.content_h }
    if ($r.boxes -lt 12 -or $h -lt 100) { return "BLANK" }
    return "OK"
}

$cssAgg   = @{}  # prop      -> @{Sites; Count}
$jsAgg    = @{}  # mensagem  -> @{Sites; Example}
$globAgg  = @{}  # global faltando  -> @{Sites; Example}
$propAgg  = @{}  # membro faltando  -> @{Sites; Example}
$parseAgg = @()  # sites com recuperacao de parse (lexer/parser engoliu algo)
$rows     = @()

foreach ($r in $reports) {
    $st  = Status-Of $r
    $u   = $r.url
    $row = [ordered]@{ Url = $u; Status = $st; Boxes = 0; PageH = 0; Overflow = 0; Collapsed = 0; ImgFail = 0; CssProps = 0; JsErrs = 0 }
    if ($r.ok) {
        $row.Boxes = $r.boxes; $row.PageH = $r.page_h
        $row.Overflow = $r.overflow; $row.Collapsed = $r.collapsed
        $row.ImgFail = $r.images.failed
        $row.CssProps = @($r.css_unknown.PSObject.Properties).Count
        $row.JsErrs = [int]$r.js_uncaught_total + [int]$r.js_rejected_total

      # sites BLOQUEADOS (anti-bot/WAF) NAO entram nos rankings de gap: os erros
      # que exibem sao do proprio challenge, nao gaps acionaveis da engine.
      if (-not $r.blocked) {
        foreach ($p in $r.css_unknown.PSObject.Properties) {
            if (-not $cssAgg.ContainsKey($p.Name)) { $cssAgg[$p.Name] = @{ Sites = 0; Count = 0 } }
            $cssAgg[$p.Name].Sites += 1
            $cssAgg[$p.Name].Count += [int]$p.Value
        }
        $seen = @{}
        # Rejeicoes NAO TRATADAS entram no mesmo ranking: desde o M130 (async virou
        # corrotina) um erro em corpo async some do js_uncaught. Sem isto o report
        # diz "JS limpo" para sites que estao quebrados.
        foreach ($m in (@($r.js_uncaught) + @($r.js_unhandled_rejections))) {
            $key = $m; if ($key.Length -gt 180) { $key = $key.Substring(0, 180) + "..." }
            if ($seen.ContainsKey($key)) { continue }   # dedup por site
            $seen[$key] = $true
            if (-not $jsAgg.ContainsKey($key)) { $jsAgg[$key] = @{ Sites = 0; Example = $u } }
            $jsAgg[$key].Sites += 1

            # sinais estruturados: global faltando / membro faltando
            if ($m -match '([A-Za-z_$][\w$]*) is not defined') {
                $g = $Matches[1]
                if (-not $globAgg.ContainsKey($g)) { $globAgg[$g] = @{ Sites = 0; Example = $u } }
                $globAgg[$g].Sites += 1
            }
            $member = $null
            if ($m -match "reading '([^']+)'")                { $member = $Matches[1] }
            elseif ($m -match '([\w$.]+) is not a function')  { $member = $Matches[1] }
            elseif ($m -match '([\w$.]+) is not a constructor') { $member = $Matches[1] }
            if ($member) {
                if (-not $propAgg.ContainsKey($member)) { $propAgg[$member] = @{ Sites = 0; Example = $u } }
                $propAgg[$member].Sites += 1
            }
        }
        if ($r.js_parse_recoveries -gt 0) {
            $notes = (@($r.js_parse_notes) | Select-Object -Unique) -join "; "
            $parseAgg += [pscustomobject]@{ Url = $u; N = $r.js_parse_recoveries; Notes = $notes }
        }
      } # -not $r.blocked
    }
    $rows += [pscustomobject]$row
}

$nOK    = @($rows | Where-Object { $_.Status -eq "OK" }).Count
$nBlank = @($rows | Where-Object { $_.Status -eq "BLANK" }).Count
$nFail  = @($rows | Where-Object { $_.Status -eq "LOAD_FAIL" }).Count
$nTime  = @($rows | Where-Object { $_.Status -eq "TIMEOUT" }).Count
$nCrash = @($rows | Where-Object { $_.Status -eq "CRASH" }).Count
$nBlock = @($rows | Where-Object { $_.Status -eq "BLOCKED" }).Count

# ── Relatorio (gap-report.md) ────────────────────────────────────────────────
function Md-Esc($s) { return ($s -replace '\|', '\|' -replace "`n", ' ') }

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Gap report — $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$md.AppendLine()
[void]$md.AppendLine("**$($reports.Count) sites** | OK $nOK | BLANK $nBlank | BLOCKED(anti-bot) $nBlock | LOAD_FAIL $nFail | TIMEOUT $nTime | CRASH $nCrash")
[void]$md.AppendLine()
[void]$md.AppendLine("Prioridade de leitura: CRASH e BLANK primeiro (site nem aparece), depois os rankings")
[void]$md.AppendLine("de CSS/JS por **n. de sites afetados** — cada item do topo e o gap que desbloqueia mais paginas.")

[void]$md.AppendLine()
[void]$md.AppendLine("## Sites que nao renderizam")
[void]$md.AppendLine()
[void]$md.AppendLine("| Site | Status | Detalhe |")
[void]$md.AppendLine("|---|---|---|")
foreach ($r in $reports) {
    $st = Status-Of $r
    if ($st -eq "OK") { continue }
    $why = ""
    if ($st -eq "BLOCKED")  { $why = "anti-bot: HTTP $($r.http_status) ($($r.block_reason)), $($r.body_bytes) bytes — servidor nao envia o site" }
    elseif (-not $r.ok)     { $why = Md-Esc $r.error }
    else                    { $why = "$($r.boxes) caixas, h=$($r.page_h) — pagina (quase) vazia" }
    [void]$md.AppendLine("| $($r.url) | $st | $why |")
}

[void]$md.AppendLine()
[void]$md.AppendLine("## CSS nao suportado (por n. de sites)")
[void]$md.AppendLine()
[void]$md.AppendLine("| Propriedade | Sites | Ocorrencias |")
[void]$md.AppendLine("|---|---:|---:|")
$cssTop = $cssAgg.GetEnumerator() | Sort-Object { $_.Value.Sites }, { $_.Value.Count } -Descending
$i = 0
foreach ($e in $cssTop) {
    [void]$md.AppendLine("| ``$($e.Key)`` | $($e.Value.Sites) | $($e.Value.Count) |")
    $i++; if ($i -ge $Top) { break }
}
[void]$md.AppendLine()
[void]$md.AppendLine("_$($cssAgg.Count) propriedades distintas no total._")

[void]$md.AppendLine()
[void]$md.AppendLine("## Globais/APIs faltando (ReferenceError)")
[void]$md.AppendLine()
[void]$md.AppendLine("| Global | Sites | Exemplo |")
[void]$md.AppendLine("|---|---:|---|")
foreach ($e in ($globAgg.GetEnumerator() | Sort-Object { $_.Value.Sites } -Descending)) {
    [void]$md.AppendLine("| ``$($e.Key)`` | $($e.Value.Sites) | $($e.Value.Example) |")
}

[void]$md.AppendLine()
[void]$md.AppendLine("## Membros/propriedades que quebraram (TypeError)")
[void]$md.AppendLine()
[void]$md.AppendLine("| Membro | Sites | Exemplo |")
[void]$md.AppendLine("|---|---:|---|")
$i = 0
foreach ($e in ($propAgg.GetEnumerator() | Sort-Object { $_.Value.Sites } -Descending)) {
    [void]$md.AppendLine("| ``$(Md-Esc $e.Key)`` | $($e.Value.Sites) | $($e.Value.Example) |")
    $i++; if ($i -ge $Top) { break }
}

[void]$md.AppendLine()
[void]$md.AppendLine("## Excecoes JS nao tratadas — uncaught + REJEICOES (por n. de sites)")
[void]$md.AppendLine()
[void]$md.AppendLine("| Mensagem | Sites | Exemplo |")
[void]$md.AppendLine("|---|---:|---|")
$i = 0
foreach ($e in ($jsAgg.GetEnumerator() | Sort-Object { $_.Value.Sites } -Descending)) {
    [void]$md.AppendLine("| $(Md-Esc $e.Key) | $($e.Value.Sites) | $($e.Value.Example) |")
    $i++; if ($i -ge $Top) { break }
}
[void]$md.AppendLine()
[void]$md.AppendLine("_$($jsAgg.Count) mensagens distintas no total._")

if ($parseAgg.Count -gt 0) {
    [void]$md.AppendLine()
    [void]$md.AppendLine("## Recuperacoes de parse JS (lexer/parser engoliu sintaxe)")
    [void]$md.AppendLine()
    [void]$md.AppendLine("| Site | Recuperacoes | Notas |")
    [void]$md.AppendLine("|---|---:|---|")
    foreach ($e in ($parseAgg | Sort-Object N -Descending)) {
        [void]$md.AppendLine("| $($e.Url) | $($e.N) | $(Md-Esc $e.Notes) |")
    }
}

[void]$md.AppendLine()
[void]$md.AppendLine("## Todos os sites")
[void]$md.AppendLine()
[void]$md.AppendLine("| Site | Status | Caixas | Altura | Overflow | Colapsos | Img falha | CSS ? | JS ! |")
[void]$md.AppendLine("|---|---|---:|---:|---:|---:|---:|---:|---:|")
foreach ($row in ($rows | Sort-Object Status, Url)) {
    [void]$md.AppendLine("| $($row.Url) | $($row.Status) | $($row.Boxes) | $($row.PageH) | $($row.Overflow) | $($row.Collapsed) | $($row.ImgFail) | $($row.CssProps) | $($row.JsErrs) |")
}

$md.ToString() | Out-File -FilePath $report -Encoding utf8

# ── Resumo no console ────────────────────────────────────────────────────────
Write-Host "`n=== Gap report ===" -ForegroundColor Cyan
Write-Host ("  {0} sites: {1} OK, {2} BLANK, {3} BLOCKED(anti-bot), {4} LOAD_FAIL, {5} TIMEOUT, {6} CRASH" -f `
    $reports.Count, $nOK, $nBlank, $nBlock, $nFail, $nTime, $nCrash)

Write-Host "`n  Top CSS nao suportado (sites x ocorrencias):" -ForegroundColor Cyan
$i = 0
foreach ($e in $cssTop) {
    Write-Host ("    {0,-32} {1,3} sites  x{2}" -f $e.Key, $e.Value.Sites, $e.Value.Count)
    $i++; if ($i -ge 12) { break }
}
Write-Host "`n  Top globais faltando:" -ForegroundColor Cyan
$i = 0
foreach ($e in ($globAgg.GetEnumerator() | Sort-Object { $_.Value.Sites } -Descending)) {
    Write-Host ("    {0,-32} {1,3} sites" -f $e.Key, $e.Value.Sites)
    $i++; if ($i -ge 12) { break }
}
Write-Host "`n  Top excecoes JS:" -ForegroundColor Cyan
$i = 0
foreach ($e in ($jsAgg.GetEnumerator() | Sort-Object { $_.Value.Sites } -Descending)) {
    $k = $e.Key; if ($k.Length -gt 100) { $k = $k.Substring(0, 100) + "..." }
    Write-Host ("    {0,3} sites  {1}" -f $e.Value.Sites, $k)
    $i++; if ($i -ge 12) { break }
}
Write-Host "`nRelatorio completo: $report" -ForegroundColor Green
