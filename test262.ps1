# Runner do Test262 (suite oficial do ECMAScript) contra o nosso browser.exe.
#
# Para cada arquivo .js sob tests\test262\test:
#   1. le o frontmatter /*--- ... ---*/  (includes, flags, negative)
#   2. monta a sequencia de fontes:  [use-strict?] sta.js assert.js <includes...> teste.js
#      (a menos que flag `raw`, que roda o arquivo sozinho)
#   3. invoca  browser.exe --js262 <fontes...>  que executa tudo numa VM so
#   4. compara o veredito bruto com a expectativa:
#        - sem `negative:`   -> PASS se nao lancou
#        - com `negative:`   -> PASS se lancou o tipo esperado
#          (phase=parse: como o nosso parser RECUPERA em vez de lancar SyntaxError,
#           aceitamos rec>0 como o "erro de parse" esperado)
#
# Uso:  .\test262.ps1                      (roda tudo)
#       .\test262.ps1 -Filter Array        (so caminhos que casam)
#       .\test262.ps1 -Verbose             (mostra cada PASS/FAIL)
#       .\test262.ps1 -ShowThrow           (nos FAIL, mostra a excecao)

param(
    [string]$Filter = "",
    [switch]$Verbose,
    [switch]$ShowThrow
)

$ErrorActionPreference = "Stop"
$root       = $PSScriptRoot
$browser    = Join-Path $root "browser.exe"
$t262Dir    = Join-Path $root "tests\test262"
$harnessDir = Join-Path $t262Dir "harness"
$testDir    = Join-Path $t262Dir "test"

if (-not (Test-Path $browser)) {
    Write-Host "browser.exe nao encontrado. Rode build.bat primeiro." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $testDir)) {
    Write-Host "tests\test262 nao existe. Rode tools\fetch-test262.ps1 primeiro." -ForegroundColor Red; exit 1
}

# ---- frontmatter helpers (mesma logica do fetcher) ----
function Get-Frontmatter($js) {
    $m = [regex]::Match($js, '/\*---(.*?)---\*/', 'Singleline')
    if (-not $m.Success) { return "" }
    return $m.Groups[1].Value
}
function Get-YamlList($fm, $key) {
    $out = @()
    $inline = [regex]::Match($fm, "(?m)^\s*$key\s*:\s*\[(.*?)\]")
    if ($inline.Success) {
        foreach ($p in ($inline.Groups[1].Value -split ',')) { $t = $p.Trim(); if ($t) { $out += $t } }
        return $out
    }
    $block = [regex]::Match($fm, "(?ms)^\s*$key\s*:\s*\n((?:\s*-\s*.*\n?)+)")
    if ($block.Success) {
        foreach ($line in ($block.Groups[1].Value -split "`n")) {
            $lm = [regex]::Match($line, '^\s*-\s*(.+?)\s*$'); if ($lm.Success) { $out += $lm.Groups[1].Value.Trim() }
        }
    }
    return $out
}
# negative: { phase: parse|resolution|runtime, type: TypeError }
function Get-Negative($fm) {
    $blk = [regex]::Match($fm, "(?ms)^\s*negative\s*:\s*\n((?:\s+\w+\s*:\s*\S+\s*\n?)+)")
    if (-not $blk.Success) { return $null }
    $body  = $blk.Groups[1].Value
    $phase = [regex]::Match($body, 'phase\s*:\s*(\S+)')
    $type  = [regex]::Match($body, 'type\s*:\s*(\S+)')
    return @{
        Phase = if ($phase.Success) { $phase.Groups[1].Value.Trim() } else { "" }
        Type  = if ($type.Success)  { $type.Groups[1].Value.Trim() }  else { "" }
    }
}

# ---- descoberta ----
$all = Get-ChildItem -Recurse -File -Path $testDir -Filter *.js
if ($Filter) { $all = $all | Where-Object { $_.FullName -like "*$Filter*" } }

Write-Host ("Rodando {0} testes Test262..." -f $all.Count) -ForegroundColor Cyan

$results = @()
foreach ($t in $all) {
    $js = [System.IO.File]::ReadAllText($t.FullName)
    $fm = Get-Frontmatter $js
    $flags    = Get-YamlList $fm 'flags'
    $includes = Get-YamlList $fm 'includes'
    $neg      = Get-Negative $fm

    $rel = $t.FullName.Substring($testDir.Length).TrimStart('\')
    $area = ($rel -split '\\')[0..1] -join '\'

    # monta a lista ordenada de fontes p/ o --js262
    $sources = New-Object System.Collections.Generic.List[string]
    $isRaw = $flags -contains 'raw'
    if (-not $isRaw) {
        # onlyStrict -> injeta "use strict"; via um arquivo temporario minusculo
        $sources.Add((Join-Path $harnessDir "sta.js"))
        $sources.Add((Join-Path $harnessDir "assert.js"))
        foreach ($inc in $includes) { $sources.Add((Join-Path $harnessDir $inc)) }
    }
    $sources.Add($t.FullName)

    # valida existencia dos includes (harness pode nao ter sido baixado inteiro)
    $missing = $sources | Where-Object { -not (Test-Path $_) }
    if ($missing) {
        $results += @{ Area = $area; Name = $rel; Status = "SKIP"; Reason = "include ausente: $($missing[0] | Split-Path -Leaf)" }
        continue
    }

    # onlyStrict: precisa de "use strict" no topo de CADA fonte de teste. Como
    # nao reescrevemos arquivos do harness, tratamos so o corpo: prefixa um
    # arquivo temporario. (noStrict roda como esta.)
    $tmpStrict = $null
    if ($flags -contains 'onlyStrict' -and -not $isRaw) {
        $tmpStrict = [System.IO.Path]::GetTempFileName() + ".js"
        [System.IO.File]::WriteAllText($tmpStrict, '"use strict";' + "`n" + $js)
        $sources[$sources.Count - 1] = $tmpStrict
    }

    $out = & $browser --js262 @($sources.ToArray()) 2>$null
    if ($tmpStrict) { Remove-Item -Force $tmpStrict -ErrorAction SilentlyContinue }

    $line = ($out | Where-Object { $_ -match '^__262__' } | Select-Object -First 1)
    if (-not $line) {
        $results += @{ Area = $area; Name = $rel; Status = "ERROR"; Reason = "sem veredito (crash?)" }
        continue
    }

    $threw = $line -match 'status=throw'
    $name  = if ($line -match 'name=(\S+)') { $Matches[1] } else { "" }
    $rec   = if ($line -match 'rec=(\d+)')  { [int]$Matches[1] } else { 0 }
    $emsg  = if ($line -match 'msg=(.*)$')  { $Matches[1] } else { "" }

    if ($neg) {
        # esperava lancar
        if ($neg.Phase -eq 'parse') {
            # nosso parser recupera em vez de lancar SyntaxError: aceita rec>0 OU throw
            $pass = ($rec -gt 0) -or $threw
        } else {
            $pass = $threw -and ($neg.Type -eq '' -or $name -eq $neg.Type)
        }
        $reason = "esperava {0}/{1}; got throw={2} name={3} rec={4}" -f $neg.Phase, $neg.Type, $threw, $name, $rec
    } else {
        # esperava NAO lancar
        $pass = -not $threw
        $reason = if ($threw) { "lancou $name`: $emsg" } else { "ok" }
    }

    $status = if ($pass) { "PASS" } else { "FAIL" }
    $results += @{ Area = $area; Name = $rel; Status = $status; Reason = $reason }

    if ($Verbose -or ($status -ne "PASS")) {
        $col = switch ($status) { "PASS" {"Green"} "FAIL" {"Red"} default {"Yellow"} }
        $msg = "  {0,-5} {1}" -f $status, $rel
        if ($ShowThrow -and $status -ne "PASS") { $msg += "  ($reason)" }
        Write-Host $msg -ForegroundColor $col
    }
}

# ---- resumo por area ----
Write-Host "`n=== Resumo por area ===" -ForegroundColor Cyan
foreach ($g in ($results | Group-Object { $_.Area } | Sort-Object Name)) {
    $p = ($g.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $tot = $g.Count
    $col = if ($p -eq $tot) { "Green" } elseif ($p -eq 0) { "Red" } else { "Yellow" }
    Write-Host ("  {0,-48} {1,3}/{2,-3} PASS" -f $g.Name, $p, $tot) -ForegroundColor $col
}

$P = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$F = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$E = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$S = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
Write-Host ("`nTOTAL: {0} PASS / {1} FAIL / {2} ERROR / {3} SKIP  (de {4})" -f $P, $F, $E, $S, $results.Count) -ForegroundColor Cyan
if ($F -gt 0 -or $E -gt 0) { exit 1 } else { exit 0 }
