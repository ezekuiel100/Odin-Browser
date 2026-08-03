# Re-mede os sites que a mineracao classificou como BLANK, com A/B entre dois
# binarios, e com o oraculo BARATO de pagina-em-branco: contar CORES DISTINTAS do
# PNG. Distingue os dois motivos, que a contagem de caixas NAO distingue:
#   - poucas cores + poucas caixas  = nada foi construido (JS/rede morreu antes)
#   - poucas cores + MUITAS caixas  = layout inteiro pronto e COBERTO (o M175)
#
# Teto de RAM por processo e piso de RAM livre do sistema, iguais ao mine-capped:
# render de site pesado ja travou a maquina (ver memoria).
param(
    [string]$ExeA = ".\browser_semfix.exe",   # ANTES do M175
    [string]$ExeB = ".\browser.exe",          # DEPOIS
    [int]$W = 1280,
    [int]$H = 900,
    [int]$Frames = 150,
    [int]$TimeoutSec = 120,
    [int]$MemCapMB = 2500,
    [int]$FreeFloorMB = 1500
)
$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Drawing
$scr = "C:\Users\Adm\AppData\Local\Temp\claude\C--Users-Adm-Desktop-browser\4a364979-300e-4952-afd1-d7aaf255f6fd\scratchpad\blank"
if (-not (Test-Path $scr)) { New-Item -ItemType Directory -Path $scr | Out-Null }

$sites = @(
    "https://edition.cnn.com", "https://www.npmjs.com", "https://crates.io",
    "https://codepen.io", "https://search.brave.com", "https://www.openstreetmap.org",
    "https://open.spotify.com", "https://soundcloud.com", "https://bandcamp.com",
    "https://www.reddit.com", "https://nextjs.org", "https://astro.build"
)

function FreeMB {
    try { return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024) } catch { return 99999 }
}

function Cores([string]$png) {
    if (-not (Test-Path $png)) { return -1 }
    try { $b = [System.Drawing.Bitmap]::FromFile($png) } catch { return -1 }
    $c = @{}
    for ($y = 0; $y -lt $b.Height; $y += 4) {
        for ($x = 0; $x -lt $b.Width; $x += 4) {
            $k = $b.GetPixel($x, $y).ToArgb()
            if ($c.ContainsKey($k)) { $c[$k]++ } else { $c[$k] = 1 }
        }
    }
    $b.Dispose()
    return $c.Count
}

# roda um render com watchdog de memoria; devolve o n de cores (-2 = MEMCAP, -3 = TIMEOUT)
function RenderCap([string]$exe, [string]$url, [string]$png) {
    Remove-Item $png -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -ArgumentList @("--render", $url, $png, "$W", "$H", "-1", "-1", "$Frames") -PassThru -NoNewWindow
    $t0 = Get-Date
    $verdict = "OK"
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 400
        try { $p.Refresh(); if ($p.WorkingSet64 -gt ($MemCapMB * 1MB)) { $verdict = "MEMCAP"; break } } catch { break }
        if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) { $verdict = "TIMEOUT"; break }
        if ((FreeMB) -lt $FreeFloorMB) { $verdict = "ABORT_RAM"; break }
    }
    # ⚠️ [void]: WaitForExit(int) DEVOLVE bool, e em PowerShell um valor solto vai
    # p/ a saida da funcao -- sem isto RenderCap devolvia um ARRAY [True, cores] e
    # o chamador quebrava (foi o que comeu 4 sites da 1a rodada).
    if (-not $p.HasExited) { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch {} }
    if ($verdict -eq "MEMCAP")    { return -2 }
    if ($verdict -eq "TIMEOUT")   { return -3 }
    if ($verdict -eq "ABORT_RAM") { return -4 }
    return (Cores $png)
}

function Rotulo([int]$c) {
    if ($c -eq -1) { return "SEM_PNG" }
    if ($c -eq -2) { return "MEMCAP" }
    if ($c -eq -3) { return "TIMEOUT" }
    if ($c -eq -4) { return "ABORT_RAM" }
    if ($c -le 2)  { return "BLANK" }
    if ($c -le 30) { return "QUASE_VAZIO" }
    return "RENDERIZA"
}

Write-Host ("RAM livre inicial: {0} MB | teto {1} MB/proc | piso {2} MB" -f (FreeMB), $MemCapMB, $FreeFloorMB)
$res = @()
foreach ($u in $sites) {
    $slug = ($u -replace "https?://", "" -replace "[^a-zA-Z0-9]", "_")
    $ca = RenderCap $ExeA $u (Join-Path $scr "$slug`_antes.png")
    $cb = RenderCap $ExeB $u (Join-Path $scr "$slug`_depois.png")
    $res += [pscustomobject]@{ site = $u; antes = (Rotulo $ca); cores_antes = $ca; depois = (Rotulo $cb); cores_depois = $cb }
    Write-Host ("{0,-34} antes={1,-11}({2,5})  depois={3,-11}({4,5})" -f $u, (Rotulo $ca), $ca, (Rotulo $cb), $cb)
    if ($ca -eq -4 -or $cb -eq -4) { Write-Host "RAM abaixo do piso -- ABORTANDO o lote" -ForegroundColor Red; break }
}
Write-Host ""
Write-Host "===== RESUMO (antes = sem M175, depois = com M175) ====="
$res | Format-Table site, antes, cores_antes, depois, cores_depois -AutoSize
$mudou = $res | Where-Object { $_.antes -ne $_.depois }
Write-Host ("sites que MUDARAM de classificacao: {0}" -f $mudou.Count)
exit 0
