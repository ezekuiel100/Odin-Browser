# Runner do html5lib tokenizer-tests contra o nosso browser.exe --tokenize.
#
# Para cada teste de cada tests\html5lib-tokenizer\*.test:
#   1. (skip se initialStates != ["Data state"] — so cobrimos o estado Data)
#   2. desfaz doubleEscaped (\uXXXX -> char) no input e no output esperado
#   3. roda  browser.exe --tokenize <input>  COM TIMEOUT
#   4. compara os tokens emitidos com o "output" esperado, FILTRANDO "ParseError"
#      (nao emitimos erros de parse), via forma canonica (atributos ordenados)
# Classifica: PASS / DIFF / CRASH / SKIP
#
# Uso:  .\html5lib-tokenizer.ps1
#       .\html5lib-tokenizer.ps1 -Filter test1
#       .\html5lib-tokenizer.ps1 -ShowDiff
#       .\html5lib-tokenizer.ps1 -ShowCrash

param(
    [string]$Filter  = "",
    [switch]$ShowDiff,
    [switch]$ShowCrash,
    [int]$TimeoutMs  = 5000
)

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$browser = Join-Path $root "browser.exe"
$dir     = Join-Path $root "tests\html5lib-tokenizer"
$tmpIn   = Join-Path $env:TEMP "h5tok_in.html"

if (-not (Test-Path $browser)) { Write-Host "browser.exe nao encontrado. Rode build.bat." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $dir))     { Write-Host "tests\html5lib-tokenizer nao existe. Rode tools\fetch-html5lib-tokenizer.ps1." -ForegroundColor Red; exit 1 }

$U8 = New-Object System.Text.UTF8Encoding($false)
$U8strict = New-Object System.Text.UTF8Encoding($false, $true) # throwOnInvalidChars

# \uXXXX -> char (para os testes doubleEscaped)
function Unescape-Double($s) {
    if ($null -eq $s) { return $s }
    return [regex]::Replace($s, '\\u([0-9A-Fa-f]{4})', { param($m) [char][int]::Parse($m.Groups[1].Value, 'HexNumber') })
}

# Forma canonica de um token (array vindo do ConvertFrom-Json). Atributos de
# StartTag saem ordenados por nome. Delimitador  evita colisao com dados.
function Canon($tok) {
    $D = [char]1
    $type = [string]$tok[0]
    switch ($type) {
        "StartTag" {
            $name  = [string]$tok[1]
            $pairs = @()
            if ($tok.Count -ge 3 -and $tok[2]) {
                foreach ($p in ($tok[2].PSObject.Properties | Sort-Object Name)) {
                    $pairs += "$($p.Name)$D=$D$($p.Value)"
                }
            }
            $sc = if ($tok.Count -ge 4 -and $tok[3] -eq $true) { "${D}SC" } else { "" }
            return "StartTag$D$name$D{$($pairs -join ',')}$sc"
        }
        "EndTag"    { return "EndTag$D$([string]$tok[1])" }
        "Character" { return "Character$D$([string]$tok[1])" }
        "Comment"   { return "Comment$D$([string]$tok[1])" }
        "DOCTYPE"   {
            $nm = if ($null -eq $tok[1]) { "<null>" } else { [string]$tok[1] }
            $pb = if ($null -eq $tok[2]) { "<null>" } else { [string]$tok[2] }
            $sy = if ($null -eq $tok[3]) { "<null>" } else { [string]$tok[3] }
            return "DOCTYPE$D$nm$D$pb$D$sy$D$($tok[4])"
        }
        default { return "?$D$type" }
    }
}

# Nome de estado do html5lib -> arg curto do browser.exe
$StateArg = @{
    'Data state'        = 'data'
    'PLAINTEXT state'   = 'plaintext'
    'RCDATA state'      = 'rcdata'
    'RAWTEXT state'     = 'rawtext'
    'Script data state' = 'script'
    'CDATA section state' = 'cdata'
}

# Roda o browser com timeout. Devolve @{ TimedOut; ExitCode; Lines }.
function Invoke-Tokenize($inputText, $state = 'data', $last = '') {
    [System.IO.File]::WriteAllText($tmpIn, $inputText, $U8)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $browser
    $psi.Arguments              = "--tokenize `"$tmpIn`" $state `"$last`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $U8
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    [void]$p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(2000) | Out-Null } catch {}
        return @{ TimedOut = $true; ExitCode = -1; Lines = @() }
    }
    $out = $outTask.Result -replace "`r`n", "`n"
    $lines = $out -split "`n" | Where-Object { $_.Trim() -ne "" }
    return @{ TimedOut = $false; ExitCode = $p.ExitCode; Lines = $lines }
}

$files = Get-ChildItem -File -Path $dir -Filter *.test
if ($Filter) { $files = $files | Where-Object { $_.Name -like "*$Filter*" } }

Write-Host ("Rodando html5lib tokenizer de {0} arquivos (timeout {1}ms)..." -f $files.Count, $TimeoutMs) -ForegroundColor Cyan

$results = @()
foreach ($file in $files) {
    $raw = [System.IO.File]::ReadAllText($file.FullName)
    try { $json = $raw | ConvertFrom-Json } catch { Write-Host "  JSON invalido: $($file.Name)" -ForegroundColor Red; continue }
    # xmlViolationTests = modo de compat XML (FF->espaco, '--'->'- -'): NAO e
    # tokenizacao HTML padrao -> pula o arquivo inteiro.
    if (-not $json.tests -and $json.xmlViolationTests) {
        $j = 0; foreach ($x in $json.xmlViolationTests) { $j++; $results += @{ File = $file.Name; Idx = $j; Status = "SKIP" } }
        continue
    }
    $tests = if ($json.tests) { $json.tests } else { @() }

    $idx = 0
    foreach ($test in $tests) {
        $idx++
        $dbl   = $test.doubleEscaped -eq $true
        $input = if ($dbl) { Unescape-Double $test.input } else { $test.input }
        $last  = if ($test.PSObject.Properties.Name -contains 'lastStartTag') { [string]$test.lastStartTag } else { '' }
        # surrogate SOLITARIO no input: NAO representavel num arquivo UTF-8 (o
        # --tokenize le de arquivo) -> intestavel. So o solto (nao os pares = astral).
        $lone = $false
        try { [void]$U8strict.GetBytes($input) } catch { $lone = $true }

        # esperado (mesmo p/ todos os estados do teste): filtra "ParseError"
        $expTokens = @()
        foreach ($el in @($test.output)) {
            if ($el -is [System.Object[]]) {
                $c = Canon $el
                if ($dbl) { $c = Unescape-Double $c }
                $expTokens += $c
            }
        }

        # roda uma vez por estado inicial (default: Data state)
        $states = if ($test.PSObject.Properties.Name -contains 'initialStates') { @($test.initialStates) } else { @('Data state') }
        foreach ($stName in $states) {
            $lbl = if ($states.Count -gt 1) { "$idx($($StateArg[$stName]))" } else { "$idx" }
            if ($lone) { $results += @{ File = $file.Name; Idx = $lbl; Status = "SKIP" }; continue }
            $sarg = $StateArg[$stName]
            if (-not $sarg) { $results += @{ File = $file.Name; Idx = $lbl; Status = "SKIP" }; continue } # estado nao suportado

            $r = Invoke-Tokenize $input $sarg $last
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                $results += @{ File = $file.Name; Idx = $lbl; Status = "CRASH"; Desc = $test.description;
                               Input = $input; Reason = if ($r.TimedOut) { "TIMEOUT" } else { "exit $($r.ExitCode)" } }
                if ($ShowCrash) { Write-Host ("  CRASH {0}#{1} [{2}] input={3}" -f $file.Name,$lbl,$results[-1].Reason,($input -replace "`n","\n")) -ForegroundColor Magenta }
                continue
            }

            $gotTokens = @()
            foreach ($ln in $r.Lines) {
                try { $tk = $ln | ConvertFrom-Json; $gotTokens += (Canon $tk) } catch { $gotTokens += "PARSEFAIL$ln" }
            }

            $ok = ($expTokens.Count -eq $gotTokens.Count)
            if ($ok) { for ($k=0; $k -lt $expTokens.Count; $k++) { if ($expTokens[$k] -ne $gotTokens[$k]) { $ok = $false; break } } }

            if ($ok) {
                $results += @{ File = $file.Name; Idx = $lbl; Status = "PASS" }
            } else {
                $results += @{ File = $file.Name; Idx = $lbl; Status = "DIFF"; Desc = $test.description }
                if ($ShowDiff) {
                    Write-Host ("  DIFF {0}#{1} [{2}]  {3}" -f $file.Name,$lbl,$stName,$test.description) -ForegroundColor Yellow
                    Write-Host ("    input:    {0}" -f ($input -replace "`n","\n")) -ForegroundColor DarkGray
                    Write-Host ("    esperado: {0}" -f (($expTokens -join ' | ') -replace [char]1,'~')) -ForegroundColor DarkGray
                    Write-Host ("    obtido:   {0}" -f (($gotTokens -join ' | ') -replace [char]1,'~')) -ForegroundColor DarkGray
                }
            }
        }
    }
}

Remove-Item -Force $tmpIn -ErrorAction SilentlyContinue

Write-Host "`n=== Resumo por arquivo ===" -ForegroundColor Cyan
foreach ($g in ($results | Group-Object { $_.File } | Sort-Object Name)) {
    $p = ($g.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $d = ($g.Group | Where-Object { $_.Status -eq "DIFF" }).Count
    $c = ($g.Group | Where-Object { $_.Status -eq "CRASH" }).Count
    $s = ($g.Group | Where-Object { $_.Status -eq "SKIP" }).Count
    $tot = $p + $d + $c + $s
    $col = if ($c -gt 0) { "Magenta" } elseif ($p -eq ($tot - $s) -and $p -gt 0) { "Green" } elseif ($p -eq 0) { "Red" } else { "Yellow" }
    Write-Host ("  {0,-26} {1,3}/{2,-3} PASS   ({3} diff, {4} CRASH, {5} skip)" -f $g.Name,$p,$tot,$d,$c,$s) -ForegroundColor $col
}

$P = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$Dn= ($results | Where-Object { $_.Status -eq "DIFF" }).Count
$C = ($results | Where-Object { $_.Status -eq "CRASH" }).Count
$S = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
Write-Host ("`nTOTAL: {0} PASS / {1} DIFF / {2} CRASH / {3} SKIP  (de {4})" -f $P,$Dn,$C,$S,$results.Count) -ForegroundColor Cyan
if ($C -gt 0) { Write-Host "==> Ha CRASH/TIMEOUT: rode com -ShowCrash (bugs de robustez)." -ForegroundColor Magenta; exit 1 }
exit 0
