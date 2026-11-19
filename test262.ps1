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
#          exige tipo, fase e origem; recovery nunca aprova
#
# Uso:  .\test262.ps1                      (roda tudo)
#       .\test262.ps1 -Filter Array        (so caminhos que casam)
#       .\test262.ps1 -Verbose             (mostra cada PASS/FAIL)
#       .\test262.ps1 -ShowThrow           (nos FAIL, mostra a excecao)

#       .\test262.ps1 -Browser X.exe       (A/B sem trocar o browser.exe)
#       .\test262.ps1 -TimeoutSec 30       (prazo por execucao; estourou = ERROR timeout)

param(
    [string]$Filter = "",
    [switch]$Verbose,
    [switch]$ShowThrow,
    [string]$Browser = "",
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "tools/test262-verdict.ps1")
$root       = $PSScriptRoot
$browser    = if ($Browser) { (Resolve-Path $Browser).Path } else { Join-Path $root "browser.exe" }

# Roda o --js262 com PRAZO. Sem ele, um unico teste que nao termina (ex.: laco de
# 2^53 iteracoes sobre um Proxy) trava a suite inteira em silencio.
function Invoke-Js262($exe, $srcs, $timeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '--js262 ' + (($srcs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) {
        try { $p.Kill() } catch {}
        $p.WaitForExit()
        return @{ Out = @(); Exit = -1; TimedOut = $true }
    }
    $p.WaitForExit()
    return @{ Out = @($so.Result -split "`r?`n"); Exit = $p.ExitCode; TimedOut = $false }
}

function Write-Result($status, $rel, $variant, $reason) {
    if ($Verbose -or ($status -ne "PASS")) {
        $col = switch ($status) { "PASS" {"Green"} "FAIL" {"Red"} default {"Yellow"} }
        $msg = "  {0,-5} {1} [{2}]" -f $status, $rel, $variant
        if (($ShowThrow -and $status -ne "PASS") -or $status -eq "ERROR") { $msg += "  ($reason)" }
        Write-Host $msg -ForegroundColor $col
    }
}
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
$all = @(Get-ChildItem -Recurse -File -Path $testDir -Filter *.js | Where-Object { $_.Name -notlike '*_FIXTURE.js' } | Sort-Object FullName)
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
    if ($fm -match '(?m)^negative\s*:' -and
        (-not $neg -or $neg.Phase -notin @('parse', 'resolution', 'runtime') -or -not $neg.Type)) {
        $results += @{ Area = $area; Name = $rel; Status = "ERROR"; Reason = "negative invalido" }
        continue
    }

    if (@($flags | Where-Object { $_ -in @('module', 'async', 'CanBlockIsFalse', 'CanBlockIsTrue') }).Count) {
        $results += @{ Area = $area; Name = $rel; Status = "SKIP"; Reason = "modo nao suportado" }
        continue
    }
    $variants = if ($flags -contains 'raw' -or $flags -contains 'noStrict') { @('normal') }
                elseif ($flags -contains 'onlyStrict') { @('strict') }
                else { @('normal', 'strict') }
    foreach ($variant in $variants) {

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
    if ($variant -eq 'strict' -and -not $isRaw) {
        $tmpStrict = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tmpStrict, '"use strict";' + "`n" + $js)
        $sources[$sources.Count - 1] = $tmpStrict
    }

    try {
        $run = Invoke-Js262 $browser $sources.ToArray() ($TimeoutSec * 1000)
        $out = $run.Out
        $processExit = $run.Exit
    } finally {
        if ($tmpStrict) { Remove-Item -Force $tmpStrict -ErrorAction SilentlyContinue }
    }

    $verdicts = @($out | Where-Object { $_ -match '^__262__' })
    $line = $verdicts | Select-Object -First 1
    if ($run.TimedOut -or $verdicts.Count -ne 1 -or $processExit -ne 0) {
        $why = if ($run.TimedOut) { "timeout ${TimeoutSec}s" } else { "sem veredito (crash? exit=$processExit)" }
        $results += @{ Area = $area; Name = "$rel [$variant]"; Status = "ERROR"; Reason = $why }
        Write-Result "ERROR" $rel $variant $why
        continue
    }

    $threw = $line -match 'status=throw'
    $name  = if ($line -match 'name=(\S+)') { $Matches[1] } else { "" }
    $rec   = if ($line -match 'rec=(\d+)')  { [int]$Matches[1] } else { 0 }
    $emsg  = if ($line -match 'msg=(.*)$')  { $Matches[1] } else { "" }
    $phase = if ($line -match 'phase=(\S+)') { $Matches[1] } else { "" }
    $sourceIndex = if ($line -match 'source=(-?\d+)') { [int]$Matches[1] } else { -1 }

    if ($neg) {
        $pass = Test-NegativeVerdict $neg $threw $name $phase $sourceIndex ($sources.Count - 1) $rec
        $reason = "esperava $($neg.Phase)/$($neg.Type); got phase=$phase name=$name source=$sourceIndex rec=$rec"
    } else {
        # esperava NAO lancar
        $pass = ($line -match '^__262__ status=pass rec=0$')
        $reason = if ($threw) { "lancou $name`: $emsg" } else { "rec=$rec; veredito=$line" }
    }

    $status = if ($pass) { "PASS" } else { "FAIL" }
    $results += @{ Area = $area; Name = "$rel [$variant]"; Status = $status; Reason = $reason }
    Write-Result $status $rel $variant $reason
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
