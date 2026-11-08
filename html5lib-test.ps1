# Runner do html5lib-tests (tree-construction) contra o nosso browser.exe.
#
# Para cada caso de cada tests\html5lib\*.dat:
#   1. extrai o #data (HTML de entrada) e o #document (arvore esperada)
#   2. roda  browser.exe --parsetree <data>  COM TIMEOUT (pega loop infinito)
#   3. compara a serializacao com o #document esperado
# Classifica:
#   PASS  - serializacao identica ao esperado
#   DIFF  - o parser concluiu, mas a arvore serializada difere da esperada
#   CRASH - o processo morreu ou TRAVOU no input (o ganho principal: robustez)
#   SKIP  - caso scripted (#script-on), ou fragmento quando -Legacy esta ativo;
#           o modo padrao executa fragmentos via --parsefragment
#
# Uso:  .\html5lib-test.ps1                    (roda tudo)
#       .\html5lib-test.ps1 -Filter tests1     (so .dat cujo nome casa)
#       .\html5lib-test.ps1 -ShowCrash         (imprime o #data de cada CRASH)
#       .\html5lib-test.ps1 -ShowDiff          (imprime esperado vs obtido nos DIFF)
#       .\html5lib-test.ps1 -TimeoutMs 3000

param(
    [string]$Filter  = "",
    [switch]$ShowCrash,
    [switch]$ShowDiff,
    [switch]$Legacy,
    [switch]$Strict,
    [int]$TimeoutMs  = 5000
)

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$browser = Join-Path $root "browser.exe"
$datDir  = Join-Path $root "tests\html5lib"
$tmpIn   = Join-Path $env:TEMP "h5l_in.html"
# -Legacy mede htmlp.parse, o parser simplificado legado; a renderizacao normal
# usa parse_render, baseado no tree builder de spec.
$parseFlag = if ($Legacy) { "--parsetree-legacy" } else { "--parsetree" }
if ($Legacy) { Write-Host "MODO LEGADO: medindo htmlp.parse (parser simplificado legado)" -ForegroundColor Yellow }

if (-not (Test-Path $browser)) {
    Write-Host "browser.exe nao encontrado. Rode build.bat primeiro." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $datDir)) {
    Write-Host "tests\html5lib nao existe. Rode tools\fetch-html5lib.ps1 primeiro." -ForegroundColor Red; exit 1
}

# Remove as duas diferencas de SCAFFOLD do parser legado (usada so em -Legacy):
#   1. a linha do DOCTYPE (o legado descarta o <!DOCTYPE>);
#   2. um <head> VAZIO (o legado so materializa o head quando ha conteudo de head).
# Head vazio = a linha "<head>" seguida de uma linha que NAO e mais indentada.
# Tudo o mais (inclusive head COM filhos) e comparado normalmente.
function Normalize-Scaffold($txt) {
    $lines = $txt -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^\| <!DOCTYPE') { continue }
        if ($ln -match '^\|(\s+)<head>\s*$') {
            $indent = $matches[1].Length
            $nxt = if ($i + 1 -lt $lines.Count) { $lines[$i+1] } else { $null }
            $nxtIndent = if ($nxt -ne $null -and $nxt -match '^\|(\s+)') { $matches[1].Length } else { -1 }
            if ($nxtIndent -le $indent) { continue }  # head sem filhos
        }
        $out.Add($ln)
    }
    return ($out -join "`n")
}

# Remove o PREFIXO DE NAMESPACE da serializacao ("<svg rect>" -> "<rect>") e a
# forma ajustada de atributo estrangeiro ("xlink href=" -> "xlink:href="). Usada
# so p/ CLASSIFICAR um DIFF: se depois disto os dois lados batem, a arvore tem a
# FORMA certa e o que falta e so o campo `ns` (o legado nao marca namespace).
# NAO conta como PASS -- e uma categoria propria no relatorio.
function Strip-Ns($txt) {
    $lines = $txt -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        $l = $ln -replace '^(\|\s*)<(svg|math) ([a-zA-Z0-9_-]+)>$', '$1<$3>'
        $l = $l -replace '^(\|\s*)(xlink|xml|xmlns) ([a-zA-Z0-9_-]+)=', '$1$2:$3='
        # nome de tag SVG e case-adjusted so na serializacao do parser de spec
        $out.Add($l.ToLower())
    }
    return ($out -join "`n")
}

# Roda o browser com timeout. Devolve @{ TimedOut; ExitCode; Stdout }.
# Usa System.Diagnostics.Process (NAO Start-Process): o -PassThru do Start-Process
# nao popula .ExitCode de forma confiavel (fica vazio, virava CRASH falso). Le os
# pipes de forma assincrona p/ nao travar num stdout grande.
function Invoke-Parse($dataText, $ctx) {
    [System.IO.File]::WriteAllText($tmpIn, $dataText, (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $browser
    $psi.Arguments              = if ($ctx) { "--parsefragment `"$tmpIn`" `"$ctx`"" } else { "$parseFlag `"$tmpIn`"" }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    [void]$p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(2000) | Out-Null } catch {}
        return @{ TimedOut = $true; ExitCode = -1; Stdout = "" }
    }
    return @{ TimedOut = $false; ExitCode = $p.ExitCode; Stdout = $outTask.Result }
}

# Divide o texto de um .dat em casos. Cada caso comeca em "#data" no inicio de
# linha. Devolve uma lista de @{ Data; Expected; Skip }.
function Parse-Dat($text) {
    $text = $text -replace "`r`n", "`n"
    # prefixa \n p/ o 1o #data tambem virar delimitador; descarta o [0] vazio
    $chunks = ("`n" + $text) -split "`n#data`n"
    $cases = @()
    for ($i = 1; $i -lt $chunks.Count; $i++) {
        $body  = $chunks[$i]
        $lines = $body -split "`n"
        $dataLines = New-Object System.Collections.Generic.List[string]
        $expLines  = New-Object System.Collections.Generic.List[string]
        $skip = $false
        $ctx  = ""       # elemento de contexto do #document-fragment ("" = documento)
        $wantCtx = $false
        $mode = "data"   # data -> (skip sections) -> document
        foreach ($ln in $lines) {
            switch ($mode) {
                "data" {
                    if ($ln -eq "#errors" -or $ln -eq "#new-errors") { $mode = "mid"; break }
                    $dataLines.Add($ln)
                }
                "mid" {
                    # o elemento de contexto vem na linha SEGUINTE ao marcador
                    if ($wantCtx) { $ctx = $ln.Trim(); $wantCtx = $false }
                    if ($ln -eq "#document-fragment") { $wantCtx = $true }
                    if ($ln -eq "#script-on") { $skip = $true }
                    if ($ln -eq "#document") { $mode = "doc" }
                }
                "doc" { $expLines.Add($ln) }
            }
        }
        # data: junta sem newline final; expected: junta e apara so as pontas em branco
        $data = ($dataLines -join "`n")
        $exp  = ($expLines -join "`n").TrimEnd("`n", " ")
        # o parser LEGADO nao tem entry-point de fragmento: em -Legacy segue SKIP
        if ($ctx -and $Legacy) { $skip = $true }
        $cases += @{ Data = $data; Expected = $exp; Skip = $skip; Ctx = $ctx }
    }
    return $cases
}

$dats = Get-ChildItem -File -Path $datDir -Filter *.dat
if ($Filter) { $dats = $dats | Where-Object { $_.Name -like "*$Filter*" } }

Write-Host ("Rodando html5lib tree-construction de {0} arquivos (timeout {1}ms)..." -f $dats.Count, $TimeoutMs) -ForegroundColor Cyan

$results = @()
foreach ($dat in $dats) {
    $text  = [System.IO.File]::ReadAllText($dat.FullName)
    $cases = Parse-Dat $text
    $idx = 0
    foreach ($case in $cases) {
        $idx++
        if ($case.Skip) {
            $results += @{ File = $dat.Name; Idx = $idx; Status = "SKIP"; Data = $case.Data }
            continue
        }
        $r = Invoke-Parse $case.Data $case.Ctx
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $results += @{ File = $dat.Name; Idx = $idx; Status = "CRASH"; Data = $case.Data;
                           Reason = if ($r.TimedOut) { "TIMEOUT (loop?)" } else { "exit $($r.ExitCode)" } }
            if ($ShowCrash) {
                Write-Host ("  CRASH {0}#{1}  [{2}]" -f $dat.Name, $idx, $results[-1].Reason) -ForegroundColor Magenta
                Write-Host ("        data: {0}" -f ($case.Data -replace "`n","\n")) -ForegroundColor DarkGray
            }
            continue
        }
        $got = ($r.Stdout -replace "`r`n","`n").TrimEnd("`n", " ")
        $exp = $case.Expected
        if ($Legacy -and -not $Strict) {
            # O parser legado nao guarda DOCTYPE e nao sintetiza <head> VAZIO.
            # Sao duas diferencas de SCAFFOLD, sistematicas, que sozinhas fariam
            # ~todo caso dar DIFF e esconderiam o que interessa: a forma da ARVORE.
            # -Strict desliga esta normalizacao e mede o placar cru.
            $got = Normalize-Scaffold $got
            $exp = Normalize-Scaffold $exp
        }
        if ($got -eq $exp) {
            $results += @{ File = $dat.Name; Idx = $idx; Status = "PASS" }
        } else {
            $st = "DIFF"
            if ($Legacy -and -not $Strict -and ((Strip-Ns $got) -eq (Strip-Ns $exp))) { $st = "NSONLY" }
            # assinatura da causa = PRIMEIRA linha em que as duas arvores divergem
            # (texto entre aspas colapsado, p/ agrupar casos irmaos). Serve p/
            # ranquear CAUSAS em vez de contar sintomas.
            $el = $exp -split "`n"; $gl = $got -split "`n"; $sig = ""
            for ($k = 0; $k -lt [Math]::Max($el.Count, $gl.Count); $k++) {
                $a = if ($k -lt $el.Count) { $el[$k] } else { "(fim)" }
                $b = if ($k -lt $gl.Count) { $gl[$k] } else { "(fim)" }
                if ($a -ne $b) {
                    $a = ($a -replace '^\|\s*','' -replace '"[^"]*"','"..."')
                    $b = ($b -replace '^\|\s*','' -replace '"[^"]*"','"..."')
                    $sig = "esperava $a / veio $b"; break
                }
            }
            $results += @{ File = $dat.Name; Idx = $idx; Status = $st; Data = $case.Data; Sig = $sig }
            if ($ShowDiff) {
                Write-Host ("  DIFF {0}#{1}" -f $dat.Name, $idx) -ForegroundColor Yellow
                Write-Host ("    data:     {0}" -f ($case.Data -replace "`n","\n")) -ForegroundColor DarkGray
                Write-Host  "    esperado:" -ForegroundColor DarkGray; Write-Host $exp -ForegroundColor DarkGray
                Write-Host  "    obtido:"   -ForegroundColor DarkGray; Write-Host $got -ForegroundColor DarkGray
            }
        }
    }
}

# limpeza dos temporarios
Remove-Item -Force $tmpIn -ErrorAction SilentlyContinue

# --- resumo por arquivo ---
Write-Host "`n=== Resumo por arquivo ===" -ForegroundColor Cyan
foreach ($g in ($results | Group-Object { $_.File } | Sort-Object Name)) {
    $p = ($g.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $d = ($g.Group | Where-Object { $_.Status -eq "DIFF" }).Count
    $c = ($g.Group | Where-Object { $_.Status -eq "CRASH" }).Count
    $s = ($g.Group | Where-Object { $_.Status -eq "SKIP" }).Count
    $tot = $p + $d + $c + $s
    $col = if ($c -gt 0) { "Magenta" } elseif ($p -eq ($tot - $s)) { "Green" } elseif ($p -eq 0) { "Red" } else { "Yellow" }
    Write-Host ("  {0,-34} {1,3}/{2,-3} PASS   ({3} diff, {4} CRASH, {5} skip)" -f $g.Name, $p, $tot, $d, $c, $s) -ForegroundColor $col
}

$P = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$D = ($results | Where-Object { $_.Status -eq "DIFF" }).Count
$C = ($results | Where-Object { $_.Status -eq "CRASH" }).Count
$S = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
$N = ($results | Where-Object { $_.Status -eq "NSONLY" }).Count
Write-Host ("`nTOTAL: {0} PASS / {1} DIFF / {2} CRASH / {3} SKIP  (de {4})" -f $P, $D, $C, $S, $results.Count) -ForegroundColor Cyan
if ($N -gt 0) {
    Write-Host ("       + {0} NSONLY (arvore com a FORMA certa; falta so o namespace svg/math)" -f $N) -ForegroundColor DarkYellow
    Write-Host ("       forma correta = {0} de {1} rodaveis" -f ($P + $N), ($results.Count - $S)) -ForegroundColor DarkYellow
}
if ($D -gt 0) {
    Write-Host "`n=== Causas mais frequentes (1a linha divergente) ===" -ForegroundColor Cyan
    $results | Where-Object { $_.Status -eq "DIFF" -and $_.Sig } |
        Group-Object { $_.Sig } | Sort-Object Count -Descending | Select-Object -First 20 |
        ForEach-Object { Write-Host ("  {0,4}x  {1}" -f $_.Count, $_.Name) }
}
if ($C -gt 0) {
    Write-Host "==> Ha CRASH/TIMEOUT: rode com -ShowCrash para ver os inputs (bugs de robustez)." -ForegroundColor Magenta
    exit 1
}
exit 0
