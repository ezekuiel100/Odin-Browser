# Mede o ALCANCE do bug do M172 (cor funcional em borda descartada pelo split por
# espaco) sobre um corpus de sites REAIS -- estatico, sem renderizar.
#
# Para cada site: baixa o HTML, junta o CSS (inline + <link>) e conta as
# declaracoes de borda cujo valor e uma FUNCAO COM ESPACO DENTRO dos parenteses,
# que era exatamente o que o tokenizador antigo picava:
#     border-color: oklch(0.968 0.007 247.896)   <- Tailwind v4
#     border: 1px solid rgba(0, 0, 0, 0.1)       <- forma classica, espaco pos-virgula
# `var(--x)` entra numa coluna PROPRIA: quebra tambem quando a variavel guarda uma
# cor funcional, mas isso so da p/ afirmar resolvendo a cadeia (nao feito aqui).
#
# Uso: .\tools\scan-border-colors.ps1 [-Corpus tools\sites-short.txt]
param(
    [string]$Corpus = "tools\sites-short.txt",
    [int]$MaxCss = 5
)
$ErrorActionPreference = "Continue"
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"

function Get-Url([string]$u) {
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 25 -Headers @{ "User-Agent" = $ua }
        return $r.Content
    } catch {
        return $null
    }
}

$urls = Get-Content $Corpus | Where-Object { $_ -match "^https?://" }
$linhas = @()

foreach ($u in $urls) {
    $html = Get-Url $u
    if ($null -eq $html) {
        $linhas += [pscustomobject]@{ site = $u; status = "LOAD_FAIL"; bordas = 0; funcEspaco = 0; oklch = 0; viaVar = 0 }
        Write-Host ("{0,-52} LOAD_FAIL" -f $u)
        continue
    }
    $css = ""
    foreach ($m in [regex]::Matches($html, '(?is)<style[^>]*>(.*?)</style>')) { $css += $m.Groups[1].Value + "`n" }
    $hrefs = @()
    foreach ($m in [regex]::Matches($html, '(?is)<link[^>]+>')) {
        if ($m.Value -match '(?i)rel\s*=\s*["'']?stylesheet') {
            if ($m.Value -match '(?i)href\s*=\s*["'']([^"'']+)["'']') { $hrefs += $matches[1] }
        }
    }
    $n = 0
    foreach ($h in $hrefs) {
        if ($n -ge $MaxCss) { break }
        try { $abs = [uri]::new([uri]$u, $h).AbsoluteUri } catch { continue }
        $c = Get-Url $abs
        if ($null -ne $c) { $css += $c + "`n"; $n++ }
    }

    # declaracoes de borda que carregam COR: longhands *-color e os shorthands
    $decls = @()
    foreach ($m in [regex]::Matches($css, '(?i)border[a-z-]*color\s*:\s*([^;}]{1,300})'))      { $decls += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($css, '(?i)border(-(top|right|bottom|left))?\s*:\s*([^;}]{1,300})')) { $decls += $m.Groups[3].Value }

    $func = 0; $okl = 0; $vr = 0
    foreach ($d in $decls) {
        # funcao com ESPACO dentro dos parenteses = o que o split antigo picava
        if ($d -match '[a-z-]+\([^)]*\s[^)]*\)') { $func++ }
        if ($d -match '(?i)oklch\(|oklab\(|lab\(|lch\(|color-mix\(') { $okl++ }
        if ($d -match '(?i)var\(--') { $vr++ }
    }
    $linhas += [pscustomobject]@{ site = $u; status = "OK"; bordas = $decls.Count; funcEspaco = $func; oklch = $okl; viaVar = $vr }
    Write-Host ("{0,-52} bordas={1,-5} func_c_espaco={2,-5} oklch={3,-4} var={4}" -f $u, $decls.Count, $func, $okl, $vr)
}

Write-Host ""
Write-Host "===== RESUMO ====="
$ok = $linhas | Where-Object { $_.status -eq "OK" }
$afetados = $ok | Where-Object { $_.funcEspaco -gt 0 }
Write-Host ("sites lidos            : {0} de {1}" -f $ok.Count, $urls.Count)
Write-Host ("sites AFETADOS         : {0}" -f $afetados.Count)
Write-Host ("declaracoes afetadas   : {0}" -f (($ok | Measure-Object -Property funcEspaco -Sum).Sum))
Write-Host ("dessas, em oklch/lab   : {0}" -f (($ok | Measure-Object -Property oklch -Sum).Sum))
Write-Host ""
$afetados | Sort-Object funcEspaco -Descending | Format-Table site, bordas, funcEspaco, oklch, viaVar -AutoSize
exit 0
