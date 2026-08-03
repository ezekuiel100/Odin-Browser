# oracle-diff.ps1 - Diff visual do NOSSO motor vs Chrome (oraculo).
#
# Para cada URL do corpus: renderiza no Chrome headless (referencia) e no nosso
# browser.exe --render, na MESMA largura, e mede a diferenca via --imgdiff.
# Ranqueia as piores paginas por dano visual -> oracle-report.md.
#
# Uso:  .\oracle-diff.ps1 [-Corpus sites.txt] [-Width 1440] [-Height 900] [-Limit 0]
#
# Colunas do relatorio:
#   diff%  = diferenca media de cor no topo comum (0=identico, 100=oposto)
#   alt%   = diferenca de ALTURA (Chrome full-page vs nosso viewport). alt% alto
#            + diff% alto => provavel conteudo faltando (JS/SPA nao rodou), nao CSS.
# ASCII puro / sem ternario / -Encoding UTF8 (PS 5.1).

param(
    [string]$Corpus = "oracle-corpus.txt",
    [int]$Width = 1440,
    [int]$Height = 900,
    [int]$Limit = 0,
    [switch]$KeepPngs,
    # -Browser: mede a DIRECAO da mudanca. O tools\ab-paint.ps1 diz que dois
    # binarios diferem naquele site, mas nao diz qual esta mais perto do Chrome;
    # rodar este script com cada binario e comparar os diff% responde isso.
    [string]$Browser = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ($Browser -ne "") {
    if ([System.IO.Path]::IsPathRooted($Browser)) { $browser = $Browser } else { $browser = Join-Path $root $Browser }
} else {
    $browser = Join-Path $root "browser.exe"
}
if (-not (Test-Path $browser)) { Write-Error "$browser nao encontrado (buildar primeiro)"; exit 1 }

# localiza o Chrome
$chromeCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe"),
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)
$chrome = $null
foreach ($c in $chromeCandidates) { if (Test-Path $c) { $chrome = $c; break } }
if ($null -eq $chrome) { Write-Error "Chrome nao encontrado"; exit 1 }
Write-Host "Chrome: $chrome"

if ([System.IO.Path]::IsPathRooted($Corpus)) { $corpusPath = $Corpus } else { $corpusPath = Join-Path $root $Corpus }
if (-not (Test-Path $corpusPath)) { Write-Error "corpus nao encontrado: $corpusPath"; exit 1 }
$urls = Get-Content $corpusPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
if ($Limit -gt 0) { $urls = $urls | Select-Object -First $Limit }

$outDir = Join-Path $root "oracle-shots"
$ourDir = Join-Path $outDir "ours"
$logDir = Join-Path $outDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$chrDir = Join-Path $outDir "chrome"
New-Item -ItemType Directory -Force -Path $ourDir | Out-Null
New-Item -ItemType Directory -Force -Path $chrDir | Out-Null

$results = @()
$i = 0
foreach ($url in $urls) {
    $i++
    $name = ($url -replace "https?://","" -replace "[^a-zA-Z0-9]","_")
    if ($name.Length -gt 60) { $name = $name.Substring(0,60) }
    $ourPng = Join-Path $ourDir "$name.png"
    $chrPng = Join-Path $chrDir "$name.png"
    Write-Host ("[{0}/{1}] {2}" -f $i, $urls.Count, $url)

    # Chrome (referencia)
    try {
        & $chrome --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
            --window-size=$Width,$Height "--screenshot=$chrPng" --virtual-time-budget=12000 `
            --no-sandbox $url 2>$null | Out-Null
    } catch {}

    # Nosso motor
    # ATENCAO a ordem dos argumentos: --render <url> <png> <w> <h> <mx> <my> <frames>
    # Antes passava-se "60" na posicao de MOUSE-X (era ignorado) e o render rodava
    # com frames=1 -> imagens/JS assincronos nao terminavam. Agora frames vai no lugar.
    # O stderr do NOSSO motor vai p/ arquivo (antes ia p/ $null e a evidencia de
    # falha era destruida - 5 sites apareciam como OURS_FAIL sem nenhum log).
    $ourLog = Join-Path $logDir "$name.log"
    try {
        $pr = Start-Process -FilePath $browser -ArgumentList @("--render", $url, $ourPng, "$Width", "$Height", "-1", "-1", "60") `
              -RedirectStandardError $ourLog -RedirectStandardOutput "$ourLog.out" -NoNewWindow -PassThru
        if (-not $pr.WaitForExit(120000)) { try { $pr.Kill() } catch {} }
    } catch {}

    $diff = -1.0; $alt = -1.0; $blank = -1.0; $status = "OK"
    if (-not (Test-Path $chrPng)) { $status = "CHROME_FAIL" }
    elseif (-not (Test-Path $ourPng)) { $status = "OURS_FAIL" }
    else {
        $out = & $browser --imgdiff $ourPng $chrPng 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $parts = (([string]$out).Trim() -replace ",",".") -split "\s+"
            if ($parts.Count -ge 3) { $diff = [double]$parts[0]; $alt = [double]$parts[1]; $blank = [double]$parts[2] }
            elseif ($parts.Count -ge 2) { $diff = [double]$parts[0]; $alt = [double]$parts[1] }
            # Chrome quase-branco = pagina de erro/bloqueio (429/anti-bot): ref invalida
            if ($blank -ge 95.0) { $status = "CHROME_BLOCKED" }
        } else { $status = "DIFF_FAIL" }
    }
    $results += [pscustomobject]@{ url = $url; diff = $diff; alt = $alt; blank = $blank; status = $status }
    Write-Host ("    diff={0:N1}%  alt={1:N1}%  blank={2:N0}%  {3}" -f $diff, $alt, $blank, $status)
}

# separa: OK (comparacao valida) ranqueado por diff; invalidos (Chrome bloqueado /
# nosso render falhou) numa secao a parte (nao poluem o ranking de fidelidade).
$valid = $results | Where-Object { $_.status -eq "OK" } | Sort-Object -Property @{Expression={$_.diff}; Descending=$true}
$invalid = $results | Where-Object { $_.status -ne "OK" }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Oracle diff - nosso motor vs Chrome")
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("Corpus: {0} sites | viewport {1}x{2} | validos: {3} | invalidos: {4}" -f $urls.Count, $Width, $Height, $valid.Count, $invalid.Count))
[void]$sb.AppendLine("")
[void]$sb.AppendLine("diff% = diferenca de cor no topo comum (maior = pior). alt% = dif. de altura. blank% = brancura do Chrome (ref).")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Ranking de fidelidade (comparacao valida, pior primeiro)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| # | diff% | alt% | site |")
[void]$sb.AppendLine("|---|------:|-----:|------|")
$n = 0
foreach ($r in $valid) {
    $n++
    [void]$sb.AppendLine(("| {0} | {1:N1} | {2:N1} | {3} |" -f $n, $r.diff, $r.alt, $r.url))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Invalidos (fora do ranking)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("CHROME_BLOCKED = Chrome pegou pagina de erro/anti-bot (ref inutil). OURS_FAIL = nosso --render nao produziu PNG (crash/timeout/blank - dominio JS).")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| status | blank% | site |")
[void]$sb.AppendLine("|--------|-------:|------|")
foreach ($r in $invalid) {
    [void]$sb.AppendLine(("| {0} | {1:N0} | {2} |" -f $r.status, $r.blank, $r.url))
}
$reportPath = Join-Path $root "oracle-report.md"
$sb.ToString() | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ""
Write-Host "Relatorio: $reportPath"
Write-Host "(PNGs em $outDir)"
exit 0  # sucesso mesmo quando algum site individual falhou (registrado como *_FAIL)
