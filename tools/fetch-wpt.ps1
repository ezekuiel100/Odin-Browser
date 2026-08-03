# Baixa um subconjunto CURADO de reftests do web-platform-tests (WPT).
# So pega testes AUTO-CONTIDOS: <style> inline, sem CSS externo, sem fonte
# Ahem, sem imagens/scripts. Isso e obrigatorio porque o nosso
# `browser.exe --render` de arquivo local NAO baixa recursos externos.
#
# Uso:  .\tools\fetch-wpt.ps1              (baixa o conjunto padrao)
#       .\tools\fetch-wpt.ps1 -PerDir 20   (mais testes por categoria)
#
# Saida: tests\wpt\<categoria>\*.html  (teste + referencia)

param(
    [int]$PerDir = 12,
    [string[]]$Only = @()   # se dado, baixa SÓ estas categorias (economiza chamadas de API)
)

$ErrorActionPreference = "Stop"
$root    = Split-Path $PSScriptRoot -Parent
$outRoot = Join-Path $root "tests\wpt"
$rawBase = "https://raw.githubusercontent.com/web-platform-tests/wpt/master"
$apiBase = "https://api.github.com/repos/web-platform-tests/wpt/contents"
$UA      = @{ "User-Agent" = "odin-browser-wpt-fetch" }

# Categorias do WPT que exercitam o que o engine diz suportar.
# (nome curto local  =>  caminho no repo WPT)
$categories = [ordered]@{
    "flexbox"       = "css/css-flexbox"
    "sizing"        = "css/css-sizing"
    "backgrounds"   = "css/css-backgrounds"
    "values-calc"   = "css/css-values"
    "position"      = "css/css-position"
    "margin"        = "css/CSS2/margin-padding-clear"
    # --- areas adicionais (placar por area = suporte por propriedade/feature) ---
    "transforms"    = "css/css-transforms"
    "text"          = "css/css-text"
    "fonts"         = "css/css-fonts"
    "overflow"      = "css/css-overflow"
    "ui"            = "css/css-ui"
    "color"         = "css/css-color"
    "display"       = "css/css-display"
    "align"         = "css/css-align"
    "grid"          = "css/css-grid"
    "writing-modes" = "css/css-writing-modes"
    "multicol"      = "css/css-multicol"
    "borders"       = "css/css-borders"
    # --- efeitos de pintura (exercitam mix-blend-mode / filter / opacity) ---
    "compositing"   = "css/compositing"      # mix-blend-mode, isolation
    "filter-effects"= "css/filter-effects"   # filter (blur, grayscale, drop-shadow, ...)
    # --- lote 2026-07-14: todas as areas do WPT css/ menos as "fora de escopo"
    # (APIs JS: paint/layout/typed-om/cssom/parser/props-values/highlight, font-loading,
    #  anchor-position, view-transitions, nesting/syntax, mixins, speech, device-adapt,
    #  geometry, fill-stroke, fetching, WOFF2, reference, support). key = nome do dir.
    "CSS1"                  = "css/CSS1"
    "css-animations"        = "css/css-animations"
    "css-box"               = "css/css-box"
    "css-break"             = "css/css-break"
    "css-cascade"           = "css/css-cascade"
    "css-color-adjust"      = "css/css-color-adjust"
    "css-color-hdr"         = "css/css-color-hdr"
    "css-conditional"       = "css/css-conditional"
    "css-contain"           = "css/css-contain"
    "css-content"           = "css/css-content"
    "css-counter-styles"    = "css/css-counter-styles"
    "css-easing"            = "css/css-easing"
    "css-env"               = "css/css-env"
    "css-exclusions"        = "css/css-exclusions"
    "css-forced-color-adjust" = "css/css-forced-color-adjust"
    "css-forms"             = "css/css-forms"
    "css-gaps"              = "css/css-gaps"
    "css-gcpm"              = "css/css-gcpm"
    "css-image-animation"   = "css/css-image-animation"
    "css-images"            = "css/css-images"
    "css-inline"            = "css/css-inline"
    "css-link-params"       = "css/css-link-params"
    "css-lists"             = "css/css-lists"
    "css-logical"           = "css/css-logical"
    "css-masking"           = "css/css-masking"
    "css-motion-path"       = "css/css-motion-path"
    "css-namespaces"        = "css/css-namespaces"
    "css-overscroll-behavior" = "css/css-overscroll-behavior"
    "css-page"              = "css/css-page"
    "css-pseudo"            = "css/css-pseudo"
    "css-rhythm"            = "css/css-rhythm"
    "css-round-display"     = "css/css-round-display"
    "css-ruby"              = "css/css-ruby"
    "css-scroll-anchoring"  = "css/css-scroll-anchoring"
    "css-scrollbars"        = "css/css-scrollbars"
    "css-scroll-snap"       = "css/css-scroll-snap"
    "css-shadow"            = "css/css-shadow"
    "css-shapes"            = "css/css-shapes"
    "css-size-adjust"       = "css/css-size-adjust"
    "css-style-attr"        = "css/css-style-attr"
    "css-tables"            = "css/css-tables"
    "css-text-decor"        = "css/css-text-decor"
    "css-transitions"       = "css/css-transitions"
    "css-variables"         = "css/css-variables"
    "css-viewport"          = "css/css-viewport"
    "css-will-change"       = "css/css-will-change"
    "css-zoom"              = "css/css-zoom"
    "mediaqueries"          = "css/mediaqueries"
    "motion"                = "css/motion"
    "printing"              = "css/printing"
    "selectors"             = "css/selectors"
}

# Rejeita testes que dependem de recursos externos (nao renderizaveis por nos).
$disqualify = @(
    'href\s*=\s*["'']/',            # /css/support/... , /fonts/...
    'rel\s*=\s*["'']?stylesheet',   # <link rel=stylesheet> externo
    '<script',                      # testharness ou afins
    'src\s*=',                      # imagens/iframes/scripts
    '@font-face',
    '\bAhem\b', 'font-family\s*:\s*ahem',
    'url\s*\(',                     # background-image, mask, etc.
    '\.png', '\.jpg', '\.jpeg', '\.gif', '\.svg', '\.woff', '\.ttf',
    'testharness'
)

function Is-SelfContained($html) {
    foreach ($rx in $disqualify) {
        if ($html -match $rx) { return $false }
    }
    return $true
}

# Extrai os href de <link rel="match"|"mismatch"> (ordem/aspas variam).
function Get-Refs($html) {
    $out = @()
    $rx = [regex]'<link\s+[^>]*rel\s*=\s*["'']?(match|mismatch)["'']?[^>]*>'
    foreach ($m in $rx.Matches($html)) {
        $tag = $m.Value
        $h = [regex]::Match($tag, 'href\s*=\s*["'']([^"'']+)["'']')
        if ($h.Success) { $out += $h.Groups[1].Value }
    }
    return $out
}

function Download-Raw($repoPath) {
    try {
        return (Invoke-WebRequest -Uri "$rawBase/$repoPath" -Headers $UA -UseBasicParsing -TimeoutSec 30).Content
    } catch { return $null }
}

# Resolve um href relativo a um caminho-base do repo (trata ../ e ./).
function Resolve-RepoPath($baseDir, $href) {
    $parts = ($baseDir -split '/') + ($href -split '/')
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if ($p -eq '' -or $p -eq '.') { continue }
        elseif ($p -eq '..') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) } }
        else { $stack.Add($p) }
    }
    return ($stack -join '/')
}

New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
$totalKept = 0

$catKeys = @($categories.Keys)
if ($Only.Count -gt 0) { $catKeys = $catKeys | Where-Object { $_ -in $Only } }

foreach ($short in $catKeys) {
    $repoDir = $categories[$short]
    $localDir = Join-Path $outRoot $short
    Write-Host "`n=== $short  ($repoDir) ===" -ForegroundColor Cyan

    try {
        $listing = Invoke-RestMethod -Uri "$apiBase/$repoDir" -Headers $UA -TimeoutSec 30
    } catch {
        Write-Host "  listagem falhou: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    # backdrop-filter é um recurso DISTINTO (não implementado) — pular p/ não
    # encher a categoria filter-effects de FAILs sem relação com o nosso `filter`.
    $candidates = $listing |
        Where-Object { $_.type -eq 'file' -and $_.name -match '\.html$' -and $_.name -notmatch '-ref\.html$' -and $_.name -notmatch 'manual' -and $_.name -notmatch 'backdrop-filter' }

    $kept = 0
    foreach ($c in $candidates) {
        if ($kept -ge $PerDir) { break }
        $html = Download-Raw "$repoDir/$($c.name)"
        if (-not $html) { continue }
        $refs = Get-Refs $html
        if ($refs.Count -eq 0) { continue }          # nao e reftest
        if (-not (Is-SelfContained $html)) { continue }

        # baixa e valida todas as referencias antes de gravar o teste
        $refFiles = @{}     # repoPath -> conteudo
        $ok = $true
        $queue = New-Object System.Collections.Generic.Queue[string]
        foreach ($r in $refs) { $queue.Enqueue((Resolve-RepoPath $repoDir $r)) }
        $seen = @{}
        while ($queue.Count -gt 0) {
            $rp = $queue.Dequeue()
            if ($seen.ContainsKey($rp)) { continue }
            $seen[$rp] = $true
            $rhtml = Download-Raw $rp
            if (-not $rhtml -or -not (Is-SelfContained $rhtml)) { $ok = $false; break }
            $refFiles[$rp] = $rhtml
            $rdir = Split-Path $rp -Parent
            foreach ($rr in (Get-Refs $rhtml)) { $queue.Enqueue((Resolve-RepoPath ($rdir -replace '\\','/') $rr)) }
        }
        if (-not $ok) { continue }

        # grava ESPELHANDO o caminho do repo sob tests\wpt, para que os href
        # relativos (../reference/...) resolvam naturalmente no disco.
        $testDest = Join-Path $outRoot ("$repoDir/$($c.name)" -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path $testDest -Parent) | Out-Null
        [System.IO.File]::WriteAllText($testDest, $html)
        foreach ($rp in $refFiles.Keys) {
            $dest = Join-Path $outRoot ($rp -replace '/','\')
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            [System.IO.File]::WriteAllText($dest, $refFiles[$rp])
        }
        Write-Host ("  + {0}  (+{1} ref)" -f $c.name, $refFiles.Count) -ForegroundColor Green
        $kept++; $totalKept++
    }
    if ($kept -eq 0) { Write-Host "  (nenhum reftest auto-contido encontrado)" -ForegroundColor DarkGray }
}

Write-Host ("`nTotal: {0} testes auto-contidos baixados em {1}" -f $totalKept, $outRoot) -ForegroundColor Cyan
