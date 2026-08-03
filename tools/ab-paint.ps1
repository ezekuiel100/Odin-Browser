# A/B PAREADO de PINTURA sobre sites reais, com teto de memoria e PISO DE RUIDO.
#
# Renderiza cada site com DOIS binarios em sequencia (pareado: mesma janela de
# rede) e mede a diferenca com --imgdiff. diff alto = o fix mudou pixel ali.
#
# Por que existe, tendo o ab-border-fix.ps1: duas travas que ele nao tem.
#   1. WATCHDOG de memoria (-MemCapMB) e piso de RAM LIVRE do sistema
#      (-FreeFloorMB), como o tools/mine-capped.ps1 -- um A/B de ~14 sites x 2
#      binarios ja travou a maquina inteira (ver memoria build-and-tooling).
#   2. PISO DE RUIDO: por padrao renderiza o site uma 3a vez com o MESMO binario
#      B. Site com conteudo dinamico (carrossel, anuncio, ordem aleatoria) da
#      diff entre duas rodadas IGUAIS; sem esse piso, variacao de rede seria lida
#      como efeito do fix. So conta como efeito quem tem diff > piso + margem.
#
# Uso:
#   .\tools\ab-paint.ps1 -A .\browser_nofix.exe -B .\browser_fix.exe
#   .\tools\ab-paint.ps1 -A x.exe -B y.exe -Sites tools\sites.txt -SemRuido
#
# ATENCAO: ASCII puro (PowerShell 5.1 le .ps1 sem BOM como ANSI) e sem ternario.

param(
    [Parameter(Mandatory=$true)][string]$A,
    [Parameter(Mandatory=$true)][string]$B,
    [string]$Sites       = "",
    [string]$Out         = "",
    [int]$W              = 1280,
    [int]$H              = 1600,
    [int]$Frames         = 8,
    [int]$TimeoutSec     = 90,
    [int]$MemCapMB       = 2000,
    [int]$FreeFloorMB    = 2500,
    [int]$PollMs         = 150,
    [double]$Margem      = 0.05,
    # Quantas rodadas EXTRA do binario B medem o piso de ruido. O piso e o MAIOR
    # desvio observado entre elas e a rodada B original.
    #
    # ⚠️ Era 1, e UMA repeticao NAO mede a dispersao: paginas com render BIMODAL
    # (banner/sticky/TOC que as vezes assenta e as vezes nao) dao 0,000 quando as
    # duas caem no mesmo modo, e o script declara "EFEITO SIM" para uma diferenca
    # que e so o modo alternativo. Foi medido em 2026-08-02: a wikipedia reportou
    # ruido=0,027 contra diff=1,931, e ao repetir, DUAS rodadas do MESMO binario
    # diferiam 1,852 -- ou seja, o piso real era ~70x o reportado, e o "efeito"
    # do fix sob teste era zero.
    [int]$RuidoRep       = 3,
    [switch]$SemRuido
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Sites) { $Sites = Join-Path $root "tools\sites-short.txt" }
if (-not $Out)   { $Out   = Join-Path $root "ab-paint" }
foreach ($exe in @($A, $B)) {
    if (-not (Test-Path $exe)) { Write-Host ("binario nao encontrado: " + $exe); exit 1 }
}
if (-not (Test-Path $Sites)) { Write-Host ("corpus nao encontrado: " + $Sites); exit 1 }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# ATENCAO: AVAILABLE, nao FreePhysicalMemory. O "free" do Win32_OperatingSystem
# exclui a lista de STANDBY (cache reaproveitavel), entao ele afunda numa rodada
# longa mesmo com a maquina folgada e o lote ABORTA sem motivo -- foi o que
# aconteceu na 1a tentativa deste A/B, no 8o site.
#
# E via WMI, nao Get-Counter: o nome do contador de performance e LOCALIZADO
# ("\Memoria\MBytes Disponiveis" em pt-BR), entao "\Memory\Available MBytes"
# levanta excecao e cairia justamente na metrica ruim. A classe
# Win32_PerfRawData_PerfOS_Memory tem nome de propriedade em ingles sempre.
function Free-MB {
    try {
        $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        return [int]$m.AvailableMBytes
    } catch {
        $os = Get-CimInstance Win32_OperatingSystem
        return [int]($os.FreePhysicalMemory / 1024)
    }
}

# ATENCAO: SEMPRE com InvariantCulture. Em locale pt-BR o "." de "5.946" que o --imgdiff
# imprime e separador de MILHAR: `[double]::TryParse` devolvia 5946 e o relatorio
# dizia "diff=5.946,000". Numero de ferramenta e sempre invariante.
$script:INV = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt3 { param([double]$v) return [string]::Format($script:INV, "{0,8:F3}", $v) }

# Renderiza com watchdog. Devolve: OK | TIMEOUT | MEMCAP | FAIL | ABORT
function Render-Watch {
    param([string]$exe, [string]$url, [string]$png)
    if ((Free-MB) -lt $FreeFloorMB) { return "ABORT" }
    $argv = @("--render", $url, $png, "$W", "$H", "-1", "-1", "$Frames")
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru -NoNewWindow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $veredito = "OK"
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds $PollMs
        try { $p.Refresh() } catch { break }
        if ($p.HasExited) { break }
        if (($p.WorkingSet64 / 1MB) -gt $MemCapMB) {
            try { $p.Kill() } catch {}
            $veredito = "MEMCAP"
            break
        }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try { $p.Kill() } catch {}
            $veredito = "TIMEOUT"
            break
        }
        if ((Free-MB) -lt $FreeFloorMB) {
            try { $p.Kill() } catch {}
            $veredito = "ABORT"
            break
        }
    }
    if ($veredito -eq "OK" -and -not (Test-Path $png)) { $veredito = "FAIL" }
    return $veredito
}

function Diff-Pct {
    param([string]$p1, [string]$p2)
    $out = & $B --imgdiff $p1 $p2 2>&1 | Select-Object -Last 1
    $campos = ("$out").Trim() -split "\s+"
    $d = -1.0
    if ($campos.Count -ge 1) {
        $txt = $campos[0] -replace ",", "."
        [double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, $script:INV, [ref]$d) | Out-Null
    }
    return $d
}

$urls = Get-Content $Sites | Where-Object { $_ -match "^https?://" }
Write-Host ("A/B de pintura: " + $urls.Count + " sites, " + $W + "x" + $H + ", " + $Frames + " frames")
Write-Host ("  A = " + $A)
Write-Host ("  B = " + $B)
Write-Host ""

$res = @()
$abortado = $false
foreach ($u in $urls) {
    if ($abortado) { break }
    $slug = ($u -replace "https?://", "" -replace "[^a-zA-Z0-9]", "_")
    $pa = Join-Path $Out ($slug + "_A.png")
    $pb = Join-Path $Out ($slug + "_B.png")
    $pn = Join-Path $Out ($slug + "_B2.png")
    Remove-Item $pa, $pb, $pn -ErrorAction SilentlyContinue

    $ra = Render-Watch $A $u $pa
    $rb = "SKIP"
    if ($ra -eq "OK") { $rb = Render-Watch $B $u $pb }

    # O piso de ruido so faz sentido quando HOUVE diferenca: se as duas imagens
    # sao identicas, nao ha o que atribuir. Poupa 1/3 dos renders do lote.
    $d = -1.0
    if ($ra -eq "OK" -and $rb -eq "OK") { $d = Diff-Pct $pa $pb }
    # Piso de ruido: RuidoRep rodadas extras de B, e fica com a MAIOR divergencia.
    # Uma so nao serve (ver a nota no parametro).
    $rn = "SKIP"
    $n  = -1.0
    if ($rb -eq "OK" -and $d -gt 0 -and -not $SemRuido) {
        for ($k = 1; $k -le $RuidoRep; $k++) {
            $rn = Render-Watch $B $u $pn
            if ($rn -ne "OK") { break }
            $nk = Diff-Pct $pb $pn
            if ($nk -gt $n) { $n = $nk }
        }
    }

    if ($ra -eq "ABORT" -or $rb -eq "ABORT" -or $rn -eq "ABORT") {
        Write-Host ("{0,-32} ABORTADO: RAM livre abaixo do piso" -f $u)
        $abortado = $true
        continue
    }
    if ($ra -ne "OK" -or $rb -ne "OK") {
        Write-Host ("{0,-32} {1}/{2}" -f $u, $ra, $rb)
        $res += [pscustomobject]@{ site = $u; diff = -1.0; diff_s = "-"; ruido_s = "-"; efeito = "-"; nota = ($ra + "/" + $rb) }
        continue
    }

    $efeito = "nao"
    if ($d -gt 0) {
        $efeito = "?"
        if ($n -ge 0) {
            $efeito = "nao"
            if ($d -gt ($n + $Margem)) { $efeito = "SIM" }
        }
    }
    Write-Host (("{0,-32}" -f $u) + " diff=" + (Fmt3 $d) + "  ruido=" + (Fmt3 $n) + "  efeito=" + $efeito)
    $res += [pscustomobject]@{ site = $u; diff = $d; diff_s = (Fmt3 $d).Trim(); ruido_s = (Fmt3 $n).Trim(); efeito = $efeito; nota = "" }
}

Write-Host ""
Write-Host "===== A/B de pintura (A x B), ordenado por diff ====="
$res | Sort-Object diff -Descending | Format-Table site, diff_s, ruido_s, efeito, nota -AutoSize
$comEfeito = @($res | Where-Object { $_.efeito -eq "SIM" })
Write-Host ("sites com EFEITO acima do ruido: " + $comEfeito.Count + " de " + $res.Count)
if ($abortado) { Write-Host "ATENCAO: lote ABORTADO no meio, o placar esta incompleto" }
exit 0
