# Runner de reftests do web-platform-tests (WPT) contra o nosso browser.exe.
#
# Descobre todo arquivo .html/.xht sob tests\wpt que tenha
# <link rel="match"|"mismatch"> , renderiza teste + referencia para PNG
# (browser.exe --render) e compara pixel a pixel, honrando:
#   - viewport 800x600 (padrao do WPT)
#   - <meta name="fuzzy" content="maxDifference=a-b; totalPixels=c-d">
#   - rel="mismatch" (o par TEM de diferir para passar)
#   - cadeia de referencias (o -ref pode apontar para outro -ref)
#
# Uso:  .\wpt-reftest.ps1                 (roda tudo)
#       .\wpt-reftest.ps1 -Filter flexbox (so testes cujo caminho casa)
#       .\wpt-reftest.ps1 -Keep           (mantem os PNGs em tests\wpt\_out)
#       .\wpt-reftest.ps1 -Verbose        (mostra o motivo de cada FAIL)
#       .\wpt-reftest.ps1 -Browser browser_ctl.exe   (A/B contra outro binario)
#
# -Browser existe para o A/B: rodar a MESMA suite em dois binarios e diffar as
# duas listas NOMEADAS entre si isola a mudanca sob teste. Comparar contra o
# wpt-baseline-fails.txt gravado so atribui corretamente quando nada MAIS mudou
# na arvore desde que ele foi gravado.

param(
    [string]$Filter = "",
    [switch]$Keep,
    [switch]$Verbose,
    [int]$Width  = 800,
    [int]$Height = 600,
    [string]$Browser = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$root    = $PSScriptRoot
$browser = if ($Browser -ne "") {
    if ([System.IO.Path]::IsPathRooted($Browser)) { $Browser } else { Join-Path $root $Browser }
} else { Join-Path $root "browser.exe" }
$wptDir  = Join-Path $root "tests\wpt"
$outDir  = Join-Path $wptDir "_out"

if (-not (Test-Path $browser)) {
    Write-Host "browser.exe nao encontrado. Rode build.bat primeiro." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $wptDir)) {
    Write-Host "tests\wpt nao existe. Rode tools\fetch-wpt.ps1 primeiro." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$reMatch = [regex]'<link\s+[^>]*rel\s*=\s*["'']?(match|mismatch)["'']?[^>]*>'
$reHref  = [regex]'href\s*=\s*["'']([^"'']+)["'']'
$reFuzzy = [regex]'name\s*=\s*["'']fuzzy["''][^>]*content\s*=\s*["'']([^"'']+)["'']'

# Le o intervalo superior de "a-b" ou "b" -> b.
function Upper($s) {
    $s = $s.Trim()
    if ($s -match '^\d+\s*-\s*(\d+)$') { return [int]$Matches[1] }
    if ($s -match '^(\d+)$')           { return [int]$Matches[1] }
    return 0
}

# fuzzy -> @{ Tol = maxDifference superior ; Budget = totalPixels superior }
function Parse-Fuzzy($html) {
    $m = $reFuzzy.Match($html)
    if (-not $m.Success) { return $null }
    $c = $m.Groups[1].Value
    $tol = 0; $budget = 0; $pos = 0
    foreach ($part in ($c -split ';')) {
        if ($part -match 'maxDifference\s*=\s*([\d\s-]+)') { $tol    = Upper $Matches[1] }
        elseif ($part -match 'totalPixels\s*=\s*([\d\s-]+)') { $budget = Upper $Matches[1] }
        elseif ($part -match '^\s*[\d\s-]+\s*$') {
            # forma curta POSICIONAL "maxDifference;totalPixels" (1o=tol, 2o=budget)
            if ($pos -eq 0) { $tol = Upper $part } else { $budget = Upper $part }
            $pos++
        }
    }
    return @{ Tol = $tol; Budget = $budget }
}

# Resolve href relativo ao arquivo de teste no disco.
function Resolve-Local($testPath, $href) {
    $href = ($href -split '#')[0]              # descarta ancora
    $dir  = Split-Path $testPath -Parent
    return [System.IO.Path]::GetFullPath((Join-Path $dir ($href -replace '/','\')))
}

# Segue a cadeia de <link rel=match> ate o arquivo de referencia final.
# (a maioria tem so 1 salto; protege contra ciclos)
function Final-Ref($testPath) {
    $cur = $testPath; $type = "match"
    for ($i = 0; $i -lt 10; $i++) {
        $html = [System.IO.File]::ReadAllText($cur)
        $m = $reMatch.Match($html)
        if (-not $m.Success) { break }
        if ($m.Groups[1].Value -eq 'mismatch') { $type = 'mismatch' }
        $h = $reHref.Match($m.Value)
        if (-not $h.Success) { break }
        $next = Resolve-Local $cur $h.Groups[1].Value
        if (-not (Test-Path $next)) { return @{ Ref = $next; Type = $type; Missing = $true } }
        # se o proprio ref for outro reftest, continua; senao para
        $nhtml = [System.IO.File]::ReadAllText($next)
        if (-not $reMatch.IsMatch($nhtml)) { return @{ Ref = $next; Type = $type; Missing = $false } }
        $cur = $next
    }
    return @{ Ref = $cur; Type = $type; Missing = $false }
}

# Compara dois PNGs via LockBits (rapido). Devolve @{ Diff; Total } onde Diff =
# num. de pixels cuja diferenca em qualquer canal RGB excede $tol.
function Compare-Fast($a, $b, $tol) {
    $ba = [System.Drawing.Bitmap]::FromFile($a)
    $bb = [System.Drawing.Bitmap]::FromFile($b)
    try {
        if ($ba.Width -ne $bb.Width -or $ba.Height -ne $bb.Height) {
            return @{ Diff = [int]::MaxValue; Total = 1 }
        }
        $w = $ba.Width; $h = $ba.Height
        $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
        $fmt  = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        $la = $ba.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
        $lb = $bb.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
        try {
            $n = $w * $h * 4
            $pa = New-Object byte[] $n
            $pb = New-Object byte[] $n
            [System.Runtime.InteropServices.Marshal]::Copy($la.Scan0, $pa, 0, $n)
            [System.Runtime.InteropServices.Marshal]::Copy($lb.Scan0, $pb, 0, $n)
            $diff = 0
            for ($i = 0; $i -lt $n; $i += 4) {
                # bytes em ordem B,G,R,A
                $db = [Math]::Abs($pa[$i]   - $pb[$i])
                $dg = [Math]::Abs($pa[$i+1] - $pb[$i+1])
                $dr = [Math]::Abs($pa[$i+2] - $pb[$i+2])
                if ($db -gt $tol -or $dg -gt $tol -or $dr -gt $tol) { $diff++ }
            }
            return @{ Diff = $diff; Total = ($w * $h) }
        } finally { $ba.UnlockBits($la); $bb.UnlockBits($lb) }
    } finally { $ba.Dispose(); $bb.Dispose() }
}

# --- descoberta dos testes ---
$all = Get-ChildItem -Recurse -File -Path $wptDir -Include *.html, *.xht |
    Where-Object { $_.FullName -notlike "*\_out\*" }
if ($Filter) { $all = $all | Where-Object { $_.FullName -like "*$Filter*" } }

$tests = @()
foreach ($f in $all) {
    $html = [System.IO.File]::ReadAllText($f.FullName)
    if ($reMatch.IsMatch($html)) { $tests += $f }   # so quem tem rel=match e um teste
}

Write-Host ("Rodando {0} reftests WPT ({1}x{2})..." -f $tests.Count, $Width, $Height) -ForegroundColor Cyan

$results = @()
$idx = 0
foreach ($t in $tests) {
    $idx++
    $rel = $t.FullName.Substring($wptDir.Length).TrimStart('\')
    $cat = ($rel -split '\\')[1]   # css\<categoria>\...
    if (-not $cat) { $cat = "outros" }

    $html = [System.IO.File]::ReadAllText($t.FullName)   # p/ Parse-Fuzzy (era stale)
    $info = Final-Ref $t.FullName
    $name = [System.IO.Path]::GetFileNameWithoutExtension($t.Name)
    $testPng = Join-Path $outDir ("{0:D3}_{1}.png"     -f $idx, $name)
    $refPng  = Join-Path $outDir ("{0:D3}_{1}-ref.png" -f $idx, $name)

    if ($info.Missing) {
        $results += @{ Cat = $cat; Name = $rel; Status = "ERROR"; Reason = "ref ausente: $($info.Ref)" }
        continue
    }

    # stderr de EXE NATIVO vira NativeCommandError e, com ErrorActionPreference
    # "Stop", ABORTA a suite no meio -- perdendo a rodada inteira por um aviso
    # transiente de um unico teste. Ja aconteceu: a lista saiu com 26 FAILs em
    # vez de 132 e parecia "106 testes consertados". Aqui o stderr e IRRELEVANTE
    # (o veredito vem do PNG, e a ausencia dele ja cai no ERROR logo abaixo),
    # entao suspende a preferencia so em volta da chamada nativa.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $browser --render $t.FullName $testPng $Width $Height 2>$null | Out-Null
    & $browser --render $info.Ref  $refPng  $Width $Height 2>$null | Out-Null
    $ErrorActionPreference = $prevEAP

    if (-not (Test-Path $testPng) -or -not (Test-Path $refPng)) {
        $results += @{ Cat = $cat; Name = $rel; Status = "ERROR"; Reason = "render falhou" }
        continue
    }

    $fz  = Parse-Fuzzy $html
    $tol = if ($fz) { $fz.Tol } else { 8 }
    $cmp = Compare-Fast $testPng $refPng $tol
    $budget = if ($fz) { $fz.Budget } else { [Math]::Ceiling($cmp.Total * 0.001) }  # 0.1%

    $isMismatch = ($info.Type -eq 'mismatch')
    if ($isMismatch) {
        $pass = $cmp.Diff -gt $budget      # mismatch: TEM de diferir
    } else {
        $pass = $cmp.Diff -le $budget      # match: quase identico
    }

    $status = if ($pass) { "PASS" } else { "FAIL" }
    $reason = "diff={0}px budget={1} tol={2}{3}" -f $cmp.Diff, $budget, $tol, $(if ($isMismatch) {" [mismatch]"} else {""})
    $results += @{ Cat = $cat; Name = $rel; Status = $status; Reason = $reason }

    $color = switch ($status) { "PASS" {"Green"} "FAIL" {"Red"} default {"Yellow"} }
    if ($Verbose -or $status -ne "PASS") {
        Write-Host ("  {0,-5} {1}  ({2})" -f $status, $rel, $reason) -ForegroundColor $color
    }
}

if (-not $Keep) { Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue }

# --- resumo por categoria ---
Write-Host "`n=== Resumo por categoria ===" -ForegroundColor Cyan
$cats = $results | Group-Object { $_.Cat } | Sort-Object Name
foreach ($g in $cats) {
    $p = ($g.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $f = ($g.Group | Where-Object { $_.Status -eq "FAIL" }).Count
    $e = ($g.Group | Where-Object { $_.Status -eq "ERROR" }).Count
    $tot = $g.Count
    $col = if ($p -eq $tot) { "Green" } elseif ($p -eq 0) { "Red" } else { "Yellow" }
    Write-Host ("  {0,-16} {1,2}/{2,-2} PASS   ({3} fail, {4} error)" -f $g.Name, $p, $tot, $f, $e) -ForegroundColor $col
}

$P = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$F = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$E = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
Write-Host ("`nTOTAL: {0} PASS / {1} FAIL / {2} ERROR  (de {3})" -f $P, $F, $E, $results.Count) -ForegroundColor Cyan
if ($F -gt 0 -or $E -gt 0) { exit 1 } else { exit 0 }
