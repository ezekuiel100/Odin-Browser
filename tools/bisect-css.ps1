# Bissecao mecanica: acha a MENOR fatia de um arquivo CSS que ainda reproduz o
# sintoma (pagina em branco = 1 cor). Sem chute: corta o CSS em regras de nivel
# superior e faz busca binaria, renderizando a cada passo.
#
# Uso: .\tools\bisect-css.ps1 -Html <snapshot.html> -StyleIndex 1
#   Html       = snapshot com o CSS ja inline (varios blocos <style>)
#   StyleIndex = qual bloco <style> bissecar (0-based)
param(
    [Parameter(Mandatory=$true)][string]$Html,
    [int]$StyleIndex = 1,
    [int]$W = 1280,
    [int]$H = 900
)
$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Drawing
$scr = Split-Path $Html -Parent
$exe = "C:\Users\Adm\Desktop\browser\browser.exe"

function Cores([string]$png) {
    if (-not (Test-Path $png)) { return -1 }
    $b = [System.Drawing.Bitmap]::FromFile($png); $c = @{}
    for ($y = 0; $y -lt $b.Height; $y += 4) {
        for ($x = 0; $x -lt $b.Width; $x += 4) {
            $k = $b.GetPixel($x, $y).ToArgb()
            if ($c.ContainsKey($k)) { $c[$k]++ } else { $c[$k] = 1 }
        }
    }
    $b.Dispose()
    return $c.Count
}

# corta o CSS em regras de nivel superior (respeita chaves aninhadas de @media)
function Split-Regras([string]$css) {
    $out = New-Object System.Collections.ArrayList
    $d = 0; $ini = 0
    for ($i = 0; $i -lt $css.Length; $i++) {
        $ch = $css[$i]
        if ($ch -eq '{') { $d++ }
        elseif ($ch -eq '}') {
            $d--
            if ($d -eq 0) { [void]$out.Add($css.Substring($ini, $i - $ini + 1)); $ini = $i + 1 }
        }
    }
    if ($ini -lt $css.Length) { [void]$out.Add($css.Substring($ini)) }
    return $out
}

$doc = [System.IO.File]::ReadAllText($Html)
$blocos = [regex]::Matches($doc, '(?is)<style[^>]*>(.*?)</style>')
if ($blocos.Count -le $StyleIndex) { Write-Host "sem bloco $StyleIndex"; exit 1 }
$alvo = $blocos[$StyleIndex]
$css = $alvo.Groups[1].Value
$regras = Split-Regras $css
Write-Host "bloco $StyleIndex : $($css.Length) bytes, $($regras.Count) regras de topo"

$n = 0
function Testa([object]$sub) {
    $script:n++
    $novo = "<style>" + ($sub -join "") + "</style>"
    $d2 = $doc.Remove($alvo.Index, $alvo.Length).Insert($alvo.Index, $novo)
    $f = Join-Path $scr "bisect_$($script:n).html"
    $p = Join-Path $scr "bisect_$($script:n).png"
    [System.IO.File]::WriteAllText($f, $d2, (New-Object System.Text.UTF8Encoding $false))
    & $exe --render $f $p "$W" "$H" "-1" "-1" "3" 2>&1 | Out-Null
    $c = Cores $p
    Remove-Item $f, $p -ErrorAction SilentlyContinue
    return $c
}

$atual = $regras
Write-Host ("baseline (todas as regras): cores={0}" -f (Testa $atual))
while ($atual.Count -gt 1) {
    $meio = [int]($atual.Count / 2)
    $a = $atual[0..($meio-1)]
    $b = $atual[$meio..($atual.Count-1)]
    $ca = Testa $a
    if ($ca -le 1) { $atual = $a; Write-Host ("  -> primeira metade reproduz ({0} regras, cores={1})" -f $a.Count, $ca); continue }
    $cb = Testa $b
    if ($cb -le 1) { $atual = $b; Write-Host ("  -> segunda metade reproduz ({0} regras, cores={1})" -f $b.Count, $cb); continue }
    Write-Host ("  !! nenhuma metade sozinha reproduz (a={0} b={1}) -- INTERACAO entre regras; parando com {2} regras" -f $ca, $cb, $atual.Count)
    break
}
Write-Host ""
Write-Host "===== MENOR FATIA QUE REPRODUZ ($($atual.Count) regra(s), $($n) renders) ====="
foreach ($r in $atual) { $t = $r.Trim(); if ($t.Length -gt 400) { $t = $t.Substring(0,400) + " [...]" }; Write-Host $t }
exit 0
