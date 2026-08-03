# A/B PAREADO do fix de borda do M172 sobre sites reais.
#
# Compara DOIS binarios do MESMO commit que diferem SO no tokenizador de borda
# (browser.exe = com fix; browser_semfix.exe = com os 4 tokenizadores revertidos).
# Renderiza cada site com os dois EM SEQUENCIA (pareado: mesma janela de rede) e
# mede a diferenca com --imgdiff. diff alto = o fix mudou pixel naquele site.
#
# ⚠️ o par TEM de ser renderizado junto; comparar duas rodadas separadas mistura
# variacao de rede/conteudo com o efeito medido.
param(
    [string]$Lista = "",
    [int]$W = 1280,
    [int]$H = 900,
    [int]$Frames = 8,
    [int]$TimeoutSeg = 90
)
$ErrorActionPreference = "Continue"
$scr = "C:\Users\Adm\AppData\Local\Temp\claude\C--Users-Adm-Desktop-browser\4a364979-300e-4952-afd1-d7aaf255f6fd\scratchpad\ab"
if (-not (Test-Path $scr)) { New-Item -ItemType Directory -Path $scr | Out-Null }

if ($Lista -eq "") {
    $sites = @(
        # afetados pelo scan estatico (func c/ espaco > 0)
        "https://www.cloudflare.com", "https://tailwindcss.com", "https://react.dev",
        "https://astro.build", "https://getbootstrap.com", "https://nextjs.org",
        "https://www.theguardian.com", "https://www.w3.org",
        # CONTROLES: scan deu ZERO declaracao afetada -> diff tem de ficar no chao
        "https://github.com", "https://www.theverge.com", "https://apnews.com"
    )
} else {
    $sites = Get-Content $Lista | Where-Object { $_ -match "^https?://" }
}

function Render([string]$exe, [string]$url, [string]$png) {
    $args = @("--render", $url, $png, "$W", "$H", "-1", "-1", "$Frames")
    $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -NoNewWindow
    if (-not $p.WaitForExit($TimeoutSeg * 1000)) {
        try { $p.Kill() } catch {}
        return $false
    }
    return (Test-Path $png)
}

$res = @()
foreach ($u in $sites) {
    $slug = ($u -replace "https?://", "" -replace "[^a-zA-Z0-9]", "_")
    $a = Join-Path $scr "$slug`_semfix.png"
    $b = Join-Path $scr "$slug`_comfix.png"
    Remove-Item $a, $b -ErrorAction SilentlyContinue
    $okA = Render ".\browser_semfix.exe" $u $a
    $okB = Render ".\browser.exe"        $u $b
    if (-not ($okA -and $okB)) {
        Write-Host ("{0,-34} RENDER_FAIL (semfix={1} comfix={2})" -f $u, $okA, $okB)
        $res += [pscustomobject]@{ site = $u; diff = -1; nota = "RENDER_FAIL" }
        continue
    }
    $out = & .\browser.exe --imgdiff $a $b 2>&1 | Select-Object -Last 1
    $campos = ("$out").Trim() -split "\s+"
    $d = -1.0
    if ($campos.Count -ge 1) { [double]::TryParse(($campos[0] -replace ",", "."), [ref]$d) | Out-Null }
    Write-Host ("{0,-34} diff={1}" -f $u, $out)
    $res += [pscustomobject]@{ site = $u; diff = $d; nota = "$out" }
}

Write-Host ""
Write-Host "===== A/B do fix de borda (diff entre NOSSO com fix e NOSSO sem fix) ====="
$res | Sort-Object diff -Descending | Format-Table site, diff, nota -AutoSize
exit 0
