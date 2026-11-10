# paint-check.ps1 - portao de PINTURA (o layout-golden.ps1 nao pega isto).
#
# O golden de layout serializa a arvore de caixas: uma caixa pode estar no lugar
# certo e NAO SER PINTADA. Foi exatamente o caso do strip de logos do github.com
# (mask-image + overflow:hidden), que o dump de layout dava como correto.
#
# Cada caso afirma REGIOES por estrutura (visivel / esmaecido / recortado), nunca
# pixel exato: nada aqui depende de fonte, de driver ou de antialiasing.
#
# Uso:  .\paint-check.ps1 [-Browser .\browser.exe] [-Keep]
# Sai 1 se qualquer afirmacao falhar.

param(
    [string]$Browser = ".\browser.exe",
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot "tests\paint\_out"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

$fails = 0
$checks = 0

# Media de cor + numero de cores distintas de uma regiao (x0,y0 inclusivos; x1,y1 exclusivos).
function Get-Region {
    param([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1)
    $r = 0; $g = 0; $b = 0; $n = 0
    $cores = @{}
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) {
            $p = $bmp.GetPixel($x, $y)
            $r += $p.R; $g += $p.G; $b += $p.B; $n++
            $cores[[string]($p.R.ToString() + "," + $p.G.ToString() + "," + $p.B.ToString())] = 1
        }
    }
    return @{ r = [int]($r / $n); g = [int]($g / $n); b = [int]($b / $n); cores = $cores.Count }
}

# Menor e mediana do canal R dos pixels PINTADOS de uma regiao. A media NAO serve
# aqui: uma mancha de alfa dobrado e localizada e some na media (o defeito do
# lote 38 tinha media 168 com minimo 108).
function Get-MinMed {
    param([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1)
    $vals = New-Object System.Collections.ArrayList
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) {
            $p = $bmp.GetPixel($x, $y)
            if ($p.R -lt 250 -or $p.G -lt 250 -or $p.B -lt 250) { [void]$vals.Add([int]$p.R) }
        }
    }
    if ($vals.Count -eq 0) { return @{ min = 255; med = 255; n = 0 } }
    $sorted = $vals.ToArray(); [Array]::Sort($sorted)
    return @{ min = $sorted[0]; med = $sorted[[int]($sorted.Count/2)]; n = $sorted.Count }
}

function Assert {
    param([string]$nome, [bool]$ok, [string]$detalhe)
    $script:checks++
    if ($ok) {
        Write-Host ("  PASS  " + $nome)
    } else {
        Write-Host ("  FAIL  " + $nome + "   " + $detalhe)
        $script:fails++
    }
}

# ---------------------------------------------------------------- caso 1
$fixture = Join-Path $PSScriptRoot "tests\paint\mask-overflow-clip.html"
$png = Join-Path $outDir "mask-overflow-clip.png"
if (Test-Path $png) { Remove-Item $png -Force }
& $Browser --render $fixture $png 600 560 0 0 3 | Out-Null
if (-not (Test-Path $png)) {
    Write-Host "  FAIL  mask-overflow-clip: o render nao produziu PNG"
    exit 1
}

Write-Host "mask-overflow-clip (mask-image + overflow:hidden na mesma caixa)"
$bmp = New-Object System.Drawing.Bitmap $png
try {
    # A caixa mascarada fica em x 50..250, y 400..500. O filho tem 600px de largura.
    $centro   = Get-Region $bmp 140 430 170 470   # meio do mask: opaco
    $esquerda = Get-Region $bmp  52 430  70 470   # ponta esquerda: esmaecida pelo mask
    $foraDir  = Get-Region $bmp 255 430 295 470   # depois da caixa: o clip tem de cortar
    $ctl      = Get-Region $bmp 390 430 420 470   # controle sem mask

    # 1. O QUE O BUG APAGAVA: o conteudo mascarado tem de aparecer.
    Assert "conteudo da layer mascarada aparece" `
        ($centro.r -gt 120 -and $centro.g -lt 90 -and $centro.b -lt 90) `
        ("media do centro = " + $centro.r + "," + $centro.g + "," + $centro.b + " (esperava vermelho)")

    # 2. O mask continua sendo um mask (a ponta esquerda desaparece no fundo branco).
    Assert "mask esmaece a ponta esquerda" `
        ($esquerda.g -gt ($centro.g + 40)) `
        ("verde esquerda = " + $esquerda.g + ", centro = " + $centro.g)

    # 3. O overflow:hidden continua recortando (o filho de 600px nao vaza).
    Assert "overflow:hidden recorta o filho largo" `
        ($foraDir.r -gt 240 -and $foraDir.g -gt 240 -and $foraDir.b -gt 240) `
        ("media fora da caixa = " + $foraDir.r + "," + $foraDir.g + "," + $foraDir.b + " (esperava fundo branco)")

    # 4. Controle declarado: mesmo recorte SEM mask sempre funcionou. Se este cair,
    #    o defeito nao e o do fix - e algo mais basico (clip ou pintura de fundo).
    Assert "CONTROLE clip sem mask" `
        ($ctl.b -gt 120 -and $ctl.r -lt 90) `
        ("media do controle = " + $ctl.r + "," + $ctl.g + "," + $ctl.b + " (esperava azul)")
} finally {
    $bmp.Dispose()
}

# ---------------------------------------------------------------- caso 2
# resize: a alca do canto inferior direito. O ponto cego que este portao cobre:
# o <textarea> tinha resize=.Both computado (o teste de unidade passava) e mesmo
# assim NADA era pintado -- o ramo de CONTROLE do paint_box retorna antes.
# Cada afirmacao e PAREADA (a x b): nada aqui depende de fonte nem de cor exata.
$fixture2 = Join-Path $PSScriptRoot "tests\paint\resize-grip.html"
$png2 = Join-Path $outDir "resize-grip.png"
if (Test-Path $png2) { Remove-Item $png2 -Force }
& $Browser --render $fixture2 $png2 500 320 0 0 3 | Out-Null
if (-not (Test-Path $png2)) {
    Write-Host "  FAIL  resize-grip: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "resize-grip (a alca e pintada, e so onde a prop se aplica)"
$bmp2 = New-Object System.Drawing.Bitmap $png2
try {
    # quadradinho INTERNO do canto inferior direito de cada caixa de 200x100
    $ta_on  = Get-Region $bmp2 206 106 218 118   # A: textarea default da UA
    $ta_off = Get-Region $bmp2 426 106 438 118   # B: textarea resize:none
    $dv_on  = Get-Region $bmp2 206 246 218 258   # C: div overflow:auto
    $dv_vis = Get-Region $bmp2 426 246 438 258   # D: div overflow:visible

    # 1. O QUE O BUG APAGAVA: o <textarea> e resizable por padrao -> tem alca.
    Assert "textarea desenha a alca (caminho de CONTROLE)" `
        ($ta_on.cores -gt $ta_off.cores) `
        ("cores no canto: com alca = " + $ta_on.cores + ", resize:none = " + $ta_off.cores)

    # 2. Controle pareado: `resize:none` do autor vence a UA -> canto limpo.
    Assert "resize:none deixa o canto limpo" `
        ($ta_off.cores -eq 1) `
        ("cores no canto do textarea resize:none = " + $ta_off.cores)

    # 3. Caixa comum com overflow:auto tambem ganha alca.
    Assert "div com overflow:auto desenha a alca" `
        ($dv_on.cores -gt $dv_vis.cores) `
        ("cores no canto: overflow:auto = " + $dv_on.cores + ", overflow:visible = " + $dv_vis.cores)

    # 4. APLICABILIDADE (css-ui): overflow:visible NAO ganha alca, mesmo com
    #    `resize:both` declarado. Se este cair, a guarda do apply_box sumiu.
    Assert "overflow:visible ignora resize" `
        ($dv_vis.cores -eq 1) `
        ("cores no canto da div overflow:visible = " + $dv_vis.cores)
} finally {
    $bmp2.Dispose()
}

# ---------------------------------------------------------------- caso 3
# resize em item de FLEX e de GRID. O caso 2 mede a alca no fluxo; aqui quem
# dimensiona o item e o CONTAINER -- e o item do grid ainda e ESTICADO pela
# trilha, entao a alca tem de ir para o canto do tamanho FINAL, nao do medido
# antes. Mesmas regioes do caso 2, de proposito (mesma geometria).
$fixture3 = Join-Path $PSScriptRoot "tests\paint\resize-flexgrid.html"
$png3 = Join-Path $outDir "resize-flexgrid.png"
if (Test-Path $png3) { Remove-Item $png3 -Force }
& $Browser --render $fixture3 $png3 500 320 0 0 3 | Out-Null
if (-not (Test-Path $png3)) {
    Write-Host "  FAIL  resize-flexgrid: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "resize-flexgrid (a alca sobrevive ao item de flex e de grid)"
$bmp3 = New-Object System.Drawing.Bitmap $png3
try {
    $fx_on  = Get-Region $bmp3 206 106 218 118   # A: textarea em flex row
    $fx_off = Get-Region $bmp3 426 106 438 118   # B: idem, resize:none
    $gr_on  = Get-Region $bmp3 206 246 218 258   # C: textarea em grid (esticado)
    $gr_off = Get-Region $bmp3 426 246 438 258   # D: idem, resize:none

    Assert "item de flex desenha a alca" `
        ($fx_on.cores -gt $fx_off.cores) `
        ("cores no canto: flex = " + $fx_on.cores + ", resize:none = " + $fx_off.cores)

    Assert "resize:none em flex deixa o canto limpo" `
        ($fx_off.cores -eq 1) `
        ("cores no canto do item flex resize:none = " + $fx_off.cores)

    Assert "item de grid ESTICADO desenha a alca no canto certo" `
        ($gr_on.cores -gt $gr_off.cores) `
        ("cores no canto: grid = " + $gr_on.cores + ", resize:none = " + $gr_off.cores)

    Assert "resize:none em grid deixa o canto limpo" `
        ($gr_off.cores -eq 1) `
        ("cores no canto do item grid resize:none = " + $gr_off.cores)
} finally {
    $bmp3.Dispose()
}

# ---------------------------------------------------------------- caso 4
# stroke-dasharray. Os testes de unidade afirmam a GEOMETRIA das peças (funcao
# pura), mas passariam intactos se alguem desligasse a chamada dentro de
# svg_emit/svg_emit_multi -- e a linha voltaria a sair SOLIDA em silencio.
# Aqui a afirmacao e sobre TINTA: faixa tracejada tem de ser mais clara que a
# solida, e o `none` tem de emendar de volta.
$fixture4 = Join-Path $PSScriptRoot "tests\paint\svg-dash.html"
$png4 = Join-Path $outDir "svg-dash.png"
if (Test-Path $png4) { Remove-Item $png4 -Force }
& $Browser --render $fixture4 $png4 400 200 0 0 3 | Out-Null
if (-not (Test-Path $png4)) {
    Write-Host "  FAIL  svg-dash: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "svg-dash (stroke-dasharray fatia o traco; none volta a emendar)"
$bmp4 = New-Object System.Drawing.Bitmap $png4
try {
    # faixa central de cada linha (traco de 6px centrado em y = 10 + 20*i)
    $solido  = Get-Region $bmp4 25 8 295 13   # linha 1: controle
    $attr    = Get-Region $bmp4 25 28 295 33  # linha 2: dasharray por ATRIBUTO
    $regra   = Get-Region $bmp4 25 48 295 53  # linha 3: dasharray por REGRA CSS
    $nenhum  = Get-Region $bmp4 25 68 295 73  # linha 4: herdado do <g> + none

    Assert "a linha de controle e SOLIDA (escura)" `
        ($solido.r -lt 60) `
        ("media do controle = " + $solido.r)

    Assert "dasharray por ATRIBUTO clareia a faixa" `
        ($attr.r -gt ($solido.r + 60)) `
        ("media solida = " + $solido.r + ", tracejada = " + $attr.r)

    Assert "dasharray NAO apaga o traco (sobra tinta)" `
        ($attr.r -lt 200) `
        ("media da faixa tracejada = " + $attr.r + " (perto de 255 = linha sumiu)")

    Assert "dasharray por REGRA CSS pinta igual ao ATRIBUTO" `
        ([Math]::Abs($regra.r - $attr.r) -lt 25) `
        ("regra = " + $regra.r + ", atributo = " + $attr.r)

    Assert "stroke-dasharray:none CANCELA o herdado do <g>" `
        ([Math]::Abs($nenhum.r - $solido.r) -lt 25) `
        ("com none = " + $nenhum.r + ", solido = " + $solido.r)
} finally {
    $bmp4.Dispose()
}

# ---------------------------------------------------------------- caso 5
# stroke-miterlimit. Mesmo furo do caso 4: a geometria da junta e funcao pura e
# os testes dela passariam intactos se ninguem a chamasse -- e o AddPolyline do
# ImGui voltaria a cuspir um bico ILIMITADO, que era o bug. Dois "L" identicos,
# so o limite muda: com o default (4) a razao 5.96 estoura e o bico e cortado;
# com 20 ele sobrevive. A regiao ACIMA do apice separa os dois casos.
$fixture5 = Join-Path $PSScriptRoot "tests\paint\svg-miter.html"
$png5 = Join-Path $outDir "svg-miter.png"
if (Test-Path $png5) { Remove-Item $png5 -Force }
& $Browser --render $fixture5 $png5 200 220 0 0 3 | Out-Null
if (-not (Test-Path $png5)) {
    Write-Host "  FAIL  svg-miter: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "svg-miter (o bico e cortado no miterlimit, e so nele)"
$bmp5 = New-Object System.Drawing.Bitmap $png5
try {
    $cortado = Get-Region $bmp5 60 15 80 35    # acima do apice, limite default
    $bico    = Get-Region $bmp5 60 115 80 135  # idem, com miterlimit 20
    $corpoA  = Get-Region $bmp5 62 70 78 88    # corpo do traco (controle)
    $corpoB  = Get-Region $bmp5 62 170 78 188

    Assert "miterlimit default CORTA o bico (nada acima do apice)" `
        ($cortado.r -gt 250 -and $cortado.cores -eq 1) `
        ("media acima do apice = " + $cortado.r + ", cores = " + $cortado.cores)

    Assert "miterlimit alto DEIXA o bico passar" `
        ($bico.r -lt 230) `
        ("media acima do apice com limite 20 = " + $bico.r)

    Assert "CONTROLE: o corpo do traco e o mesmo nos dois" `
        ([Math]::Abs($corpoA.r - $corpoB.r) -lt 12 -and $corpoA.r -lt 60) `
        ("corpo default = " + $corpoA.r + ", corpo limite 20 = " + $corpoB.r)
} finally {
    $bmp5.Dispose()
}

# ---------------------------------------------------------------- caso 6
# border-image. A moldura de teste tem uma COR por regiao (cantos verdes, bordas
# listradas azul/vermelho, miolo amarelo), entao da p/ afirmar POR COR que cada
# fatia foi parar no lugar certo -- um 9-slice trocado (canto esticado por toda a
# borda, por exemplo) muda a cor da regiao e cai aqui. A 3a caixa e o par que
# pega o fallback: sem ela, um border-image que nunca pintasse passaria como
# "borda normal, esta tudo bem".
$fixture6 = Join-Path $PSScriptRoot "tests\paint\border-image.html"
$png6 = Join-Path $outDir "border-image.png"
if (Test-Path $png6) { Remove-Item $png6 -Force }
& $Browser --render $fixture6 $png6 260 470 0 0 3 | Out-Null
if (-not (Test-Path $png6)) {
    Write-Host "  FAIL  border-image: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "border-image (cada fatia no seu lugar, e o fallback quando a fonte falha)"
$bmp6 = New-Object System.Drawing.Bitmap $png6
try {
    $c1canto = Get-Region $bmp6  5   5  25  25   # caixa 1: canto sup-esq
    $c1borda = Get-Region $bmp6 70   5 140  25   # caixa 1: meio da borda de cima
    $c1miolo = Get-Region $bmp6 60  60 150 120   # caixa 1: miolo (sem fill)
    $c2miolo = Get-Region $bmp6 60 210 150 270   # caixa 2: miolo (com fill)
    $c3canto = Get-Region $bmp6  5 305  25 325   # caixa 3: url invalida

    Assert "o CANTO recebe a fatia de canto (verde)" `
        ($c1canto.g -gt ($c1canto.r + 80) -and $c1canto.g -gt ($c1canto.b + 80)) `
        ("canto = " + $c1canto.r + "," + $c1canto.g + "," + $c1canto.b)

    Assert "a BORDA recebe a fatia de borda (listrada, nao verde)" `
        ($c1borda.g -lt ($c1borda.r + 40)) `
        ("borda = " + $c1borda.r + "," + $c1borda.g + "," + $c1borda.b)

    Assert "sem border-image-slice fill o miolo NAO e pintado" `
        ($c1miolo.r -gt 240 -and $c1miolo.g -gt 240 -and $c1miolo.b -gt 240) `
        ("miolo = " + $c1miolo.r + "," + $c1miolo.g + "," + $c1miolo.b)

    Assert "com border-image-slice fill o miolo VIRA a fatia central (amarelo)" `
        ($c2miolo.r -gt 200 -and $c2miolo.g -gt 200 -and $c2miolo.b -lt 80) `
        ("miolo com fill = " + $c2miolo.r + "," + $c2miolo.g + "," + $c2miolo.b)

    Assert "fonte que falha cai na BORDA normal (vermelha)" `
        ($c3canto.r -gt ($c3canto.g + 80)) `
        ("canto da caixa com url invalida = " + $c3canto.r + "," + $c3canto.g + "," + $c3canto.b)
} finally {
    $bmp6.Dispose()
}

# ---------------------------------------------------------------- caso 7
# stroke-opacity: a geometria EXTRA da ponta/junta (que existe porque o
# AddPolyline do ImGui so faz ponta reta) nao pode se SOBREPOR ao proprio traco.
# Se sobrepuser, o trecho comum compoe o alfa duas ou tres vezes e sai mancha
# escura -- que com traco OPACO e invisivel, e foi por isso que o defeito
# sobreviveu a tres lotes. A afirmacao e de UNIFORMIDADE, nunca de cor exata.
$fixture7 = Join-Path $PSScriptRoot "tests\paint\svg-stroke-opacity.html"
$png7 = Join-Path $outDir "svg-stroke-opacity.png"
if (Test-Path $png7) { Remove-Item $png7 -Force }
& $Browser --render $fixture7 $png7 300 220 0 0 3 | Out-Null
if (-not (Test-Path $png7)) {
    Write-Host "  FAIL  svg-stroke-opacity: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "svg-stroke-opacity (ponta/junta nao dobram o alfa do traco)"
$bmp7 = New-Object System.Drawing.Bitmap $png7
try {
    $linha = Get-MinMed $bmp7 25  20 235  42   # traco translucido, cap redondo
    $junta = Get-MinMed $bmp7 35  10 225  75   # "L" translucido, junta redonda
    $opaco = Get-MinMed $bmp7 25 150 235 172   # o MESMO traco, opaco (controle)

    Assert "ponta redonda nao escurece o traco translucido" `
        ($linha.min -ge ($linha.med - 4)) `
        ("minimo = " + $linha.min + ", mediana = " + $linha.med)

    Assert "junta redonda nao vira mancha (o disco inteiro dava ~70)" `
        ($junta.min -ge 130) `
        ("minimo na quina = " + $junta.min + ", mediana = " + $junta.med)

    Assert "CONTROLE: o mesmo traco OPACO pinta cheio" `
        ($opaco.med -lt 30 -and $opaco.n -gt 500) `
        ("mediana do opaco = " + $opaco.med + ", pixels = " + $opaco.n)
} finally {
    $bmp7.Dispose()
}

# ---------------------------------------------------------------- caso 8
# IntersectionObserver (M232). O ponto cego que este caso cobre: o observador
# pode estar perfeito na MATEMATICA (os unitarios de src/js medem isso com um
# rect falso) e mesmo assim nao mudar nada na tela, porque a cadeia real tem
# quatro elos -- io_step do hospedeiro -> callback -> classList -> re-estilizar
# antes de pintar. So a pintura afirma os quatro juntos.
$fixture8 = Join-Path $PSScriptRoot "tests\paint\intersection-observer.html"
$png8 = Join-Path $outDir "intersection-observer.png"
if (Test-Path $png8) { Remove-Item $png8 -Force }
& $Browser --render $fixture8 $png8 400 300 0 0 3 | Out-Null
if (-not (Test-Path $png8)) {
    Write-Host "  FAIL  intersection-observer: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "intersection-observer (o callback revela o alvo, e SO o que esta na tela)"
$bmp8 = New-Object System.Drawing.Bitmap $png8
try {
    $alvo = Get-Region $bmp8  60  40 140  90   # nasce vermelho; o observador deixa verde
    $ind  = Get-Region $bmp8 240  40 320  90   # azul; vira amarelo se o alvo de fora disparar
    $ctl  = Get-Region $bmp8  60 140 140 190   # verde estatico, sem JS

    # 1. O QUE O STUB APAGAVA: o alvo dentro da viewport tem de ficar verde.
    Assert "observador revela o alvo visivel (vermelho -> verde)" `
        ($alvo.g -gt ($alvo.r + 40)) `
        ("media do alvo = " + $alvo.r + "," + $alvo.g + "," + $alvo.b + " (esperava verde)")

    # 2. O outro lado do erro: alvo a 2000px NAO pode contar como visivel.
    Assert "alvo fora da viewport nao dispara (indicador segue azul)" `
        ($ind.b -gt ($ind.r + 60)) `
        ("media do indicador = " + $ind.r + "," + $ind.g + "," + $ind.b + " (esperava azul)")

    # 3. Controle declarado: verde ESTATICO, sem JS. Se este cair, o defeito e de
    #    CSS/pintura e as duas afirmacoes acima nao dizem nada sobre o observador.
    Assert "CONTROLE verde estatico (sem JS)" `
        ($ctl.g -gt ($ctl.r + 40)) `
        ("media do controle = " + $ctl.r + "," + $ctl.g + "," + $ctl.b + " (esperava verde)")
} finally {
    $bmp8.Dispose()
}

# ---------------------------------------------------------------- caso 9
# window.innerWidth/innerHeight (M232). Eram props FIXAS em 800x600, e o ponto
# cego e o mesmo do observador: nenhum teste de unidade que rode fora de um
# render pega a diferenca entre "o numero certo" e "o numero que o hospedeiro
# empurrou". Aqui o JS DIMENSIONA caixas a partir deles, e a borda das caixas
# denuncia o valor usado.
$fixture9 = Join-Path $PSScriptRoot "tests\paint\viewport-metrics.html"
$png9 = Join-Path $outDir "viewport-metrics.png"
if (Test-Path $png9) { Remove-Item $png9 -Force }
& $Browser --render $fixture9 $png9 400 300 0 0 3 | Out-Null
if (-not (Test-Path $png9)) {
    Write-Host "  FAIL  viewport-metrics: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "viewport-metrics (o JS dimensiona pela janela: 400x300, nao 800x600)"
$bmp9 = New-Object System.Drawing.Bitmap $png9
try {
    $meiaDentro = Get-Region $bmp9  20  20 180  60   # dentro da metade: azul
    $meiaFora   = Get-Region $bmp9 220  20 380  60   # depois de 200px: fundo branco
    $ctl        = Get-Region $bmp9  20 120 180 160   # 200px ESTATICOS, sem JS
    $altFora    = Get-Region $bmp9 310 265 350 295   # depois de 160+100: fundo branco

    # 1. innerWidth/2 = 200 -> a caixa existe...
    Assert "caixa dimensionada por innerWidth aparece" `
        ($meiaDentro.b -gt ($meiaDentro.r + 60)) `
        ("media dentro = " + $meiaDentro.r + "," + $meiaDentro.g + "," + $meiaDentro.b + " (esperava azul)")

    # 2. ...e TERMINA em 200. Com os 800 fixos ela iria ate 400 e esta regiao seria azul.
    Assert "innerWidth e o viewport REAL (a caixa para em 200px)" `
        ($meiaFora.r -gt 240 -and $meiaFora.g -gt 240 -and $meiaFora.b -gt 240) `
        ("media apos 200px = " + $meiaFora.r + "," + $meiaFora.g + "," + $meiaFora.b + " (esperava branco)")

    # 3. innerHeight/3 = 100: a caixa vermelha termina em y=260.
    Assert "innerHeight e o viewport REAL (a caixa para em y=260)" `
        ($altFora.r -gt 240 -and $altFora.g -gt 240 -and $altFora.b -gt 240) `
        ("media apos y=260 = " + $altFora.r + "," + $altFora.g + "," + $altFora.b + " (esperava branco)")

    # 4. Controle declarado: 200px vindos do CSS, sem JS nenhum. Se este cair, o
    #    problema e de layout/pintura e as tres afirmacoes acima nada dizem.
    Assert "CONTROLE 200px estaticos (sem JS)" `
        ($ctl.g -gt ($ctl.r + 40)) `
        ("media do controle = " + $ctl.r + "," + $ctl.g + "," + $ctl.b + " (esperava verde)")

    # 5/6. matchMedia contra o MESMO viewport: (min-width:300px) casa, (900px) nao.
    #      Com o stub antigo (matches sempre false) as duas caixas ficavam como
    #      nasceram -- e a 2a passava por acidente, dai ela vir PAREADA com a 1a.
    $mqsim = Get-Region $bmp9  20 220 100 260
    $mqnao = Get-Region $bmp9 160 220 240 260
    Assert "matchMedia casa a query verdadeira (vermelho -> verde)" `
        ($mqsim.g -gt ($mqsim.r + 40)) `
        ("media do sim = " + $mqsim.r + "," + $mqsim.g + "," + $mqsim.b + " (esperava verde)")
    Assert "matchMedia NAO casa a query falsa (segue azul)" `
        ($mqnao.b -gt ($mqnao.r + 60)) `
        ("media do nao = " + $mqnao.r + "," + $mqnao.g + "," + $mqnao.b + " (esperava azul)")
} finally {
    $bmp9.Dispose()
}

# ---------------------------------------------------------------- caso 10
# ResizeObserver (M232). O eco copia a largura MEDIDA: a borda direita dele
# denuncia o NUMERO que chegou na entry, entao o caso nao passa so por "algum
# callback rodou" -- que e o buraco de um gate escrito com cor unica.
$fixture10 = Join-Path $PSScriptRoot "tests\paint\resize-observer.html"
$png10 = Join-Path $outDir "resize-observer.png"
if (Test-Path $png10) { Remove-Item $png10 -Force }
& $Browser --render $fixture10 $png10 400 300 0 0 3 | Out-Null
if (-not (Test-Path $png10)) {
    Write-Host "  FAIL  resize-observer: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "resize-observer (o eco copia a largura MEDIDA do alvo)"
$bmp10 = New-Object System.Drawing.Bitmap $png10
try {
    $eco     = Get-Region $bmp10  40 130 140 170   # dentro dos 160px medidos
    $ecoFora = Get-Region $bmp10 200 130 380 170   # depois deles: fundo branco
    $ctl     = Get-Region $bmp10  40 220 140 260   # 160px ESTATICOS, sem JS

    # 1. O QUE O STUB APAGAVA: sem callback, o eco fica com width:0 e some.
    Assert "observador de tamanho entrega a medida (eco aparece)" `
        ($eco.g -gt ($eco.r + 40)) `
        ("media do eco = " + $eco.r + "," + $eco.g + "," + $eco.b + " (esperava verde)")

    # 2. E a medida e a CERTA: o eco termina onde o alvo termina (160px).
    Assert "a largura medida e a do alvo (o eco para em 160px)" `
        ($ecoFora.r -gt 240 -and $ecoFora.g -gt 240 -and $ecoFora.b -gt 240) `
        ("media apos 180px = " + $ecoFora.r + "," + $ecoFora.g + "," + $ecoFora.b + " (esperava branco)")

    # 3. Controle declarado: a MESMA caixa de 160px vinda do CSS, sem JS.
    Assert "CONTROLE 160px estaticos (sem JS)" `
        ($ctl.g -gt ($ctl.r + 40)) `
        ("media do controle = " + $ctl.r + "," + $ctl.g + "," + $ctl.b + " (esperava verde)")
} finally {
    $bmp10.Dispose()
}

# ---------------------------------------------------------------- caso 11
# canvas.getContext('2d') (M232). O canvas e o unico elemento cujo conteudo NAO
# vem do HTML nem do CSS: se a ponte js->painter quebrar, a caixa fica no lugar
# certo e vazia -- exatamente o ponto cego que este gate existe para cobrir.
$fixture11 = Join-Path $PSScriptRoot "tests\paint\canvas2d.html"
$png11 = Join-Path $outDir "canvas2d.png"
if (Test-Path $png11) { Remove-Item $png11 -Force }
# ⚠️ ErrorActionPreference relaxado SO nesta chamada: um binario SEM canvas lanca
# TypeError na fixture, o stderr de um exe nativo vira NativeCommandError e com
# "Stop" isso ABORTA o gate no meio -- foi o que aconteceu ao rodar a sabotagem
# com o binario antigo, e o placar inteiro sumiu. Aqui a excecao da pagina e um
# RESULTADO esperado, nao um erro do gate. (Redirecionar com 2>$null NAO resolve:
# no PS 5.1 e a propria redirecao que embrulha o stderr em ErrorRecord.)
$prevEA = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $Browser --render $fixture11 $png11 400 300 0 0 3 | Out-Null
$ErrorActionPreference = $prevEA
if (-not (Test-Path $png11)) {
    Write-Host "  FAIL  canvas2d: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "canvas2d (retangulo, arco e traco desenhados pelo JS)"
$bmp11 = New-Object System.Drawing.Bitmap $png11
try {
    $ret   = Get-Region $bmp11  50  45  90  75   # fillRect vermelho
    $circ  = Get-Region $bmp11 205  70 235  90   # arc+fill verde
    $linha = Get-Region $bmp11 100 166 200 174   # stroke azul (lineWidth 10)
    $vazio = Get-Region $bmp11 150 120 200 140   # dentro do canvas, sem desenho
    $ctl   = Get-Region $bmp11  30 255  90 275   # o MESMO vermelho, so por CSS

    Assert "fillRect pinta o retangulo" `
        ($ret.r -gt 150 -and $ret.g -lt 60 -and $ret.b -lt 60) `
        ("media do retangulo = " + $ret.r + "," + $ret.g + "," + $ret.b)

    Assert "arc+fill pinta o circulo" `
        ($circ.g -gt 120 -and $circ.r -lt 80) `
        ("media do circulo = " + $circ.r + "," + $circ.g + "," + $circ.b)

    Assert "stroke pinta a linha com a espessura pedida" `
        ($linha.b -gt 150 -and $linha.r -lt 60) `
        ("media da linha = " + $linha.r + "," + $linha.g + "," + $linha.b)

    Assert "o que NAO foi desenhado fica em branco" `
        ($vazio.r -gt 245 -and $vazio.g -gt 245 -and $vazio.b -gt 245) `
        ("media do vazio = " + $vazio.r + "," + $vazio.g + "," + $vazio.b)

    Assert "CONTROLE: o mesmo vermelho vindo do CSS" `
        ($ctl.r -gt 150 -and $ctl.g -lt 60) `
        ("media do controle = " + $ctl.r + "," + $ctl.g + "," + $ctl.b)
} finally {
    $bmp11.Dispose()
}

# ---------------------------------------------------------------- caso 12
# M234: `height:%` num ABSOLUTO (a caixa saia com altura ZERO), e o placeholder
# cinza que a altura nova revelou. Os dois moram no mesmo caso de proposito: foi
# exatamente essa combinacao que quebrou o hero da cloudflare -- o poster AVIF
# (h-full w-full, sem decoder aqui) so virou mancha DEPOIS que a caixa ganhou
# altura. Um gate que cobrisse so a altura declararia sucesso com a pagina pior.
$fixture12 = Join-Path $PSScriptRoot "tests\paint\abspos-height-img-fail.html"
$png12 = Join-Path $outDir "abspos-height-img-fail.png"
if (Test-Path $png12) { Remove-Item $png12 -Force }
& $Browser --render $fixture12 $png12 400 520 0 0 3 | Out-Null
if (-not (Test-Path $png12)) {
    Write-Host "  FAIL  abspos-height-img-fail: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "abspos-height + imagem que falha (M234)"
$bmp12 = New-Object System.Drawing.Bitmap $png12
try {
    $baixo   = Get-Region $bmp12  20 100  85 118   # PE da caixa A: so e verde se h=100% resolveu
    $direita = Get-Region $bmp12 100  40 175  90   # metade direita de A: cinza do pai (controle)
    $falha   = Get-Region $bmp12  20 150 175 245   # B: falhou e e DECORATIVA (alt="")
    $ok      = Get-Region $bmp12  20 280 175 375   # C: imagem que CARREGA (azul)
    $comAlt  = Get-Region $bmp12  20 410 175 505   # D: falhou mas tem alt de CONTEUDO

    # 1. O DEFEITO: com fh=-1 a caixa tinha h=0 e o pe ficava com o cinza do pai.
    Assert "abspos com height:100% pinta ate o PE da caixa" `
        ($baixo.g -gt ($baixo.r + 40)) `
        ("media do pe = " + $baixo.r + "," + $baixo.g + "," + $baixo.b + " (esperava verde)")

    # 2. CONTROLE de largura: a metade direita continua sendo o pai.
    Assert "CONTROLE a metade direita segue com o fundo do pai" `
        ([Math]::Abs($direita.r - $direita.g) -lt 12 -and $direita.r -gt 200 -and $direita.r -lt 245) `
        ("media da direita = " + $direita.r + "," + $direita.g + "," + $direita.b + " (esperava cinza claro)")

    # 3. A REGRESSAO que a altura revelou: o esqueleto #e8e8ec cobria o laranja.
    Assert "imagem DECORATIVA que falha nao vira mancha (o fundo aparece)" `
        ($falha.r -gt 200 -and $falha.g -lt 170 -and $falha.b -lt 110) `
        ("media sobre a imagem quebrada = " + $falha.r + "," + $falha.g + "," + $falha.b + " (esperava laranja)")

    # 4. CONTROLE que impede o "conserto" preguicoso: se eu tivesse apagado o
    #    desenho de imagem por inteiro, o item 3 passaria igual.
    Assert "CONTROLE imagem que CARREGA continua pintando" `
        ($ok.b -gt 120 -and $ok.r -lt 120) `
        ("media da imagem boa = " + $ok.r + "," + $ok.g + "," + $ok.b + " (esperava azul)")

    # 5. CONTROLE DO RECORTE: com alt de CONTEUDO o esqueleto FICA. Sem este, a
    #    regra teria virado "apagar toda imagem quebrada" -- que e o que piorou o
    #    theguardian quando eu tentei (50,8 -> 52,7).
    Assert "CONTROLE imagem com alt de conteudo MANTEM o esqueleto" `
        ($comAlt.r -gt 200 -and $comAlt.g -gt 200 -and $comAlt.b -gt 200) `
        ("media do esqueleto = " + $comAlt.r + "," + $comAlt.g + "," + $comAlt.b + " (esperava cinza claro)")
} finally {
    $bmp12.Dispose()
}

# ---------------------------------------------------------------- caso 13
# M235: `filter: blur(<len>)` e um Gaussiano cujo comprimento e o DESVIO-PADRAO,
# nao um raio de janela. Com UMA passada de box o borrao acabava em 1x sigma em vez
# de ~3x -- forte o bastante para "ter blur" em qualquer teste de existencia, e
# fraco o bastante para o brilho difuso da cloudflare virar mancha de borda dura.
# Por isso o gate mede o ALCANCE (ha tinta LONGE da caixa?), nao a presenca.
$fixture13 = Join-Path $PSScriptRoot "tests\paint\filter-blur-grafia.html"
$png13 = Join-Path $outDir "filter-blur-grafia.png"
if (Test-Path $png13) { Remove-Item $png13 -Force }
& $Browser --render $fixture13 $png13 400 500 0 0 3 | Out-Null
if (-not (Test-Path $png13)) {
    Write-Host "  FAIL  filter-blur-grafia: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "filter-blur (alcance do Gaussiano, e as 4 grafias que chegam nele)"
$bmp13 = New-Object System.Drawing.Bitmap $png13
try {
    # As caixas sao 120x60 em x=60..179; centro vertical da i-esima = 60 + i*90.
    # A faixa x=14..34 fica a ~30px da borda ESQUERDA: dentro do alcance certo
    # (~3sigma = 72px), fora do que uma passada so alcancava (24px).
    $semFiltro = Get-Region $bmp13 14  45  34  75   # A: sem filter
    $literal   = Get-Region $bmp13 14 135  34 165   # B: blur(24px)
    $varAninh  = Get-Region $bmp13 14 315  34 345   # D: blur(var(--raio))
    $tailwind  = Get-Region $bmp13 14 405  34 435   # E: lista com fallback VAZIO
    $miolo     = Get-Region $bmp13 90 135 150 165   # B por dentro: ainda vermelho

    # 1. CONTROLE: sem filter nada vaza da caixa. Se esta regiao tiver tinta, o
    #    teste inteiro esta medindo outra coisa (fixture ou coordenada erradas).
    Assert "CONTROLE sem filter a regiao fora da caixa fica limpa" `
        ($semFiltro.r -gt 253 -and $semFiltro.g -gt 253 -and $semFiltro.b -gt 253) `
        ("media fora da caixa A = " + $semFiltro.r + "," + $semFiltro.g + "," + $semFiltro.b)

    # 2. O DEFEITO: a 30px da borda o borrao antigo ja tinha acabado (255,255,255).
    Assert "blur(24px) alcanca ~3 sigma (ha tinta a 30px da borda)" `
        ($literal.g -lt 250 -and $literal.b -lt 250) `
        ("media a 30px da borda = " + $literal.r + "," + $literal.g + "," + $literal.b + " (branco = alcance curto)")

    # 3/4. As grafias modernas tem de chegar no MESMO lugar. Nao sao decorativas:
    #      foi por suspeitar da grafia (e nao da forca) que eu quase fui consertar
    #      o parser em vez do Gaussiano.
    Assert "var() ANINHADA borra igual" `
        ($varAninh.g -lt 250 -and $varAninh.b -lt 250) `
        ("media = " + $varAninh.r + "," + $varAninh.g + "," + $varAninh.b)

    Assert "grafia do Tailwind v4 (fallback VAZIO na lista) borra igual" `
        ($tailwind.g -lt 250 -and $tailwind.b -lt 250) `
        ("media = " + $tailwind.r + "," + $tailwind.g + "," + $tailwind.b)

    # 5. CONTROLE do outro lado: borrar nao pode APAGAR a caixa. ⚠️ o limiar aqui e
    #    MEDIDO, nao suposto: numa caixa de 60px com sigma=24 o miolo amacia MESMO
    #    (216,63,63 nosso contra 216,62,62 do Chrome). Meu palpite era "segue
    #    vermelho solido" e ele reprovava o resultado CERTO -- suspeita n.1 quando um
    #    teste meu falha e a minha expectativa. Fica o que distingue de verdade: o
    #    miolo continua fortemente vermelho (r-g grande), e isso vale nos dois
    #    binarios, entao e controle e nao deteccao.
    Assert "CONTROLE o miolo da caixa nao e apagado pelo borrao" `
        (($miolo.r - $miolo.g) -gt 120 -and $miolo.r -gt 190) `
        ("media do miolo = " + $miolo.r + "," + $miolo.g + "," + $miolo.b + " (r-g = " + ($miolo.r - $miolo.g) + ")")
} finally {
    $bmp13.Dispose()
}

# ---------------------------------------------------------------- caso 14
# overflow:hidden + border-radius + BORDA: a faixa de fundo que contorna o canto.
# Ponto cego que este caso cobre: o clip de overflow do ImGui e RETANGULAR, entao
# um filho que preenche a padding-box mantem o canto QUADRADO e pinta por cima da
# faixa entre a curva INTERNA (raio - largura da borda) e a EXTERNA. O entalhe que
# ja existia so limpava o que passa da curva EXTERNA, entao a moldura AFINAVA ate
# sumir nos 4 cantos -- e nenhum reftest pegava, porque so aparece quando ha
# filho, borda E raio na MESMA caixa. Medido no famososbr.com: 5px na reta, 0px no
# canto (o Chrome mantem os 5px).
$fixture14 = Join-Path $PSScriptRoot "tests\paint\radius-inner-band.html"
$png14 = Join-Path $outDir "radius-inner-band.png"
if (Test-Path $png14) { Remove-Item $png14 -Force }
& $Browser --render $fixture14 $png14 400 220 0 0 3 | Out-Null
if (-not (Test-Path $png14)) {
    Write-Host "  FAIL  radius-inner-band: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "radius-inner-band (overflow:hidden + raio + borda: a faixa do canto)"
$bmp14 = New-Object System.Drawing.Bitmap $png14
try {
    # Caixa A em x 20..160, y 20..160; raio 30, borda 10 => centro da curva do
    # canto sup-esq = (50,50), faixa entre os raios 20 e 30.
    $cantoA   = Get-Region $bmp14  30  30  36  36   # meio da faixa na diagonal (raio ~25)
    $retaA    = Get-Region $bmp14  22  80  28 100   # mesma faixa no trecho RETO
    $mioloA   = Get-Region $bmp14  70  70 110 110   # conteudo do filho
    $foraA    = Get-Region $bmp14  22  22  26  26   # alem da curva EXTERNA (raio ~37)
    # Caixa B (sem borda) em x 200..340, y 20..160; centro da curva = (230,50).
    $foraB    = Get-Region $bmp14 202  22 206  26   # alem da curva externa
    $mioloB   = Get-Region $bmp14 250  70 290 110   # conteudo do filho

    # 1. O QUE O BUG APAGAVA: no canto, a faixa e o FUNDO do elemento (verde),
    #    nao o filho (azul).
    Assert "a faixa de fundo contorna o canto arredondado" `
        ($cantoA.g -gt 100 -and $cantoA.b -lt 100) `
        ("media no canto = " + $cantoA.r + "," + $cantoA.g + "," + $cantoA.b + " (azul = o filho comeu a faixa)")

    # 2. CONTROLE PAREADO: o mesmo trecho de faixa na RETA sempre funcionou. Se
    #    este cair junto, o defeito nao e o do canto -- e a pintura do fundo.
    Assert "CONTROLE a mesma faixa no trecho reto" `
        ($retaA.g -gt 100 -and $retaA.b -lt 100) `
        ("media na reta = " + $retaA.r + "," + $retaA.g + "," + $retaA.b)

    # 3. CONTROLE do outro lado: restaurar a faixa nao pode COMER o conteudo.
    Assert "CONTROLE o filho continua pintando o miolo" `
        ($mioloA.b -gt 150 -and $mioloA.g -lt 100) `
        ("media do miolo = " + $mioloA.r + "," + $mioloA.g + "," + $mioloA.b)

    # 4. CONTROLE do entalhe EXTERNO: alem da curva externa continua sendo o fundo
    #    da pagina. Sem isto, "pintar a faixa" poderia virar "pintar o canto todo".
    Assert "CONTROLE alem da curva externa fica o fundo da pagina" `
        ($foraA.r -gt 240 -and $foraA.g -gt 240 -and $foraA.b -gt 240) `
        ("media fora da curva = " + $foraA.r + "," + $foraA.g + "," + $foraA.b)

    # 5/6. CONTROLE do caminho SEM borda (as duas curvas coincidem): tem de seguir
    #      igual ao que ja era. Este par e o que prova nao-regressao por construcao.
    Assert "CONTROLE sem borda o canto segue recortado" `
        ($foraB.r -gt 240 -and $foraB.g -gt 240 -and $foraB.b -gt 240) `
        ("media fora da curva (B) = " + $foraB.r + "," + $foraB.g + "," + $foraB.b)

    Assert "CONTROLE sem borda o filho segue pintando" `
        ($mioloB.b -gt 150 -and $mioloB.g -lt 100) `
        ("media do miolo (B) = " + $mioloB.r + "," + $mioloB.g + "," + $mioloB.b)
} finally {
    $bmp14.Dispose()
}

# ---------------------------------------------------------------- caso 15
# A borda e desenhada POR DENTRO da border-box (css-backgrounds-3 §4). O traco do
# AddRect do ImGui e CENTRADO no caminho, entao a borda uniforme vazava METADE da
# largura para FORA do elemento -- e so metade dos pixels de dentro ficava com a
# cor. Medido contra o Chrome numa borda de 5px: x=38,39 tinham tinta onde o Chrome
# deixa o fundo, e so 3 dos 5px internos eram da cor da borda. Vale p/ TODA caixa
# com borda uniforme, com raio ou sem.
$fixture15 = Join-Path $PSScriptRoot "tests\paint\border-inside.html"
$png15 = Join-Path $outDir "border-inside.png"
if (Test-Path $png15) { Remove-Item $png15 -Force }
& $Browser --render $fixture15 $png15 300 300 0 0 3 | Out-Null
if (-not (Test-Path $png15)) {
    Write-Host "  FAIL  border-inside: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "border-inside (a borda fica DENTRO da caixa, nao a cavalo na aresta)"
$bmp15 = New-Object System.Drawing.Bitmap $png15
try {
    # C (sem raio): border-box x 20..112, y 170..262; borda de 16px.
    $foraC   = Get-Region $bmp15   6 210  19 230   # ANTES da caixa: o defeito pintava daqui
    $mioloC  = Get-Region $bmp15  50 210  80 230   # padding-box: sem tinta de borda
    # ⚠️ as regioes de CONTROLE ficam na INTERSECAO do desenho velho com o novo
    # (traco centrado cobria x 12..28; por dentro cobre 20..36 => interseccao 20..28).
    # Escolher a faixa "certa" inteira faz o controle FALHAR no binario velho -- e ai
    # ele nao separa mais nada, so duplica a deteccao. Verificado nos DOIS binarios.
    $faixaC  = Get-Region $bmp15  22 210  27 230   # dentro dos 16px: a cor da borda
    # D (raio 24): border-box x 140..232; centro da curva do canto = (164,194).
    # Radialmente: velho cobria [16,32], novo cobre [8,24] => controle no raio ~20.
    $foraD   = Get-Region $bmp15 140 170 145 175   # alem da curva externa (raio ~31 > 24)
    $cantoD  = Get-Region $bmp15 148 178 153 183   # dentro da faixa do canto (raio ~20)

    # 1. O DEFEITO: nada da borda pode aparecer FORA da border-box.
    Assert "a borda nao vaza para fora da caixa" `
        ($foraC.r -gt 240 -and $foraC.g -gt 240 -and $foraC.b -gt 240) `
        ("media antes da caixa = " + $foraC.r + "," + $foraC.g + "," + $foraC.b + " (vermelho = traco a cavalo na aresta)")

    # 2. CONTROLE PAREADO: recuar o traco nao pode APAGAR a borda.
    Assert "CONTROLE a borda pinta a faixa de dentro" `
        ($faixaC.r -gt 150 -and $faixaC.g -lt 80) `
        ("media da faixa = " + $faixaC.r + "," + $faixaC.g + "," + $faixaC.b)

    # 3. CONTROLE do outro lado: a borda nao pode invadir a padding-box.
    Assert "CONTROLE a borda nao invade o miolo" `
        ($mioloC.r -gt 240 -and $mioloC.g -gt 240) `
        ("media do miolo = " + $mioloC.r + "," + $mioloC.g + "," + $mioloC.b)

    # 4. O raio tem de baixar junto com o recuo, senao a curva EXTERNA vai parar no
    #    raio+w/2 e o canto INCHA. Este ponto esta a ~30px do centro da curva de 24.
    Assert "com raio, a curva externa fica no raio pedido" `
        ($foraD.r -gt 240 -and $foraD.g -gt 240 -and $foraD.b -gt 240) `
        ("media fora do canto = " + $foraD.r + "," + $foraD.g + "," + $foraD.b + " (vermelho = canto inchado)")

    # 5. CONTROLE: e o canto continua sendo PINTADO.
    Assert "CONTROLE o canto arredondado tem tinta" `
        ($cantoD.r -gt 150 -and $cantoD.g -lt 80) `
        ("media do canto = " + $cantoD.r + "," + $cantoD.g + "," + $cantoD.b)
} finally {
    $bmp15.Dispose()
}

# ---------------------------------------------------------------- caso 16
# A decoracao de texto e do elemento DECORADOR, nao da palavra: o sublinhado de
# um link de varias palavras e UMA linha, continua por cima do espaco. O motor
# emitia um traco por item de palavra e o link saia PICOTADO -- visivel em todo
# link de mais de uma palavra, em qualquer site.
#
# A afirmacao e por numero de CORRIDAS de tinta na fileira do sublinhado, nao por
# coordenada: nao depende de fonte nem de onde cai o espaco.
function Get-Corridas {
    param([System.Drawing.Bitmap]$bmp, [int]$y, [int]$x0, [int]$x1)
    $corridas = 0; $tinta = 0; $dentro = $false; $vazios = 0
    for ($x = $x0; $x -lt $x1; $x++) {
        $p = $bmp.GetPixel($x, $y)
        if ($p.B -gt 120 -and $p.R -lt 120) {
            $tinta++; $vazios = 0
            if (-not $dentro) { $corridas++; $dentro = $true }
        } else {
            $vazios++
            # so corta a corrida com 3px limpos: 1px de antialias no meio de uma
            # linha continua nao pode contar como buraco (e o espaco tem ~10px).
            if ($vazios -ge 3) { $dentro = $false }
        }
    }
    return @{ corridas = $corridas; tinta = $tinta }
}
function Get-FileiraDeBaixo {
    param([System.Drawing.Bitmap]$bmp, [int]$y0, [int]$y1, [int]$x0, [int]$x1)
    for ($y = $y1 - 1; $y -ge $y0; $y--) {
        if ((Get-Corridas $bmp $y $x0 $x1).tinta -gt 0) { return $y }
    }
    return -1
}

$fixture16 = Join-Path $PSScriptRoot "tests\paint\deco-atravessa-espaco.html"
$png16 = Join-Path $outDir "deco-atravessa-espaco.png"
if (Test-Path $png16) { Remove-Item $png16 -Force }
& $Browser --render $fixture16 $png16 500 260 0 0 3 | Out-Null
if (-not (Test-Path $png16)) {
    Write-Host "  FAIL  deco-atravessa-espaco: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "deco-atravessa-espaco (o sublinhado do link e UMA linha, nao um traco por palavra)"
$bmp16 = New-Object System.Drawing.Bitmap $png16
try {
    $y1 = Get-FileiraDeBaixo $bmp16   0 120 0 500   # banda do link unico
    $y2 = Get-FileiraDeBaixo $bmp16 120 240 0 500   # banda dos dois links
    $um   = if ($y1 -ge 0) { Get-Corridas $bmp16 $y1 0 500 } else { @{ corridas = -1; tinta = 0 } }
    $dois = if ($y2 -ge 0) { Get-Corridas $bmp16 $y2 0 500 } else { @{ corridas = -1; tinta = 0 } }

    # 1. O DEFEITO: duas palavras do MESMO link = uma corrida so.
    Assert "o sublinhado atravessa o espaco entre as palavras do link" `
        ($um.corridas -eq 1) `
        ("corridas na fileira y=" + $y1 + ": " + $um.corridas + " (2 = picotado no espaco)")

    # 2. CONTROLE PAREADO: dois links VIZINHOS nao podem emendar a linha.
    Assert "CONTROLE dois links vizinhos nao emendam o sublinhado" `
        ($dois.corridas -eq 2) `
        ("corridas na fileira y=" + $y2 + ": " + $dois.corridas)

    # 3. CONTROLE do outro lado: a linha contida cobre MAIS pixels que as duas
    #    soltas (a diferenca e exatamente o espaco). Pega um "conserto" que so
    #    tivesse apagado um dos tracos em vez de emendar os dois.
    Assert "CONTROLE a linha emendada cobre o espaco (mais tinta que as soltas)" `
        ($um.tinta -gt $dois.tinta -and $dois.tinta -gt 0) `
        ("tinta: link unico = " + $um.tinta + ", dois links = " + $dois.tinta)
} finally {
    $bmp16.Dispose()
}

# ---------------------------------------------------------------- caso 17
# METRICAS DE FONTE POR FACE (M244). O motor usava UMA constante de em-square
# (1.36, medida na Segoe UI) para toda face, e UMA fracao fixa (0.28em) como
# avanco do espaco. Georgia saia ~19% e Consolas ~22% maiores que no Chrome, e o
# espaco de uma monoespacada ficava com metade da largura -- uma linha de codigo
# com 9 espacos encolhia 40px.
#
# Os alvos abaixo sao ARITMETICA da propria fonte, conferida contra o Chrome:
#   20 'M' Consolas = 20 x 0.5498em x 16px = 175.9   (Chrome: 175)
#   20 'M' Georgia  = 20 x 0.9272em x 16px = 296.7   (Chrome: 296)
#   10 'M' + 9 espacos Consolas = 19 x 8.797 = 167.1 (Chrome: 166)
# A tinta comeca em x=20 (padding), entao o fim esperado = 20 + alvo.
$fixture17 = Join-Path $PSScriptRoot "tests\paint\font-metrics.html"
$png17 = Join-Path $outDir "font-metrics.png"
if (Test-Path $png17) { Remove-Item $png17 -Force }
& $Browser --render $fixture17 $png17 600 140 0 0 3 | Out-Null
if (-not (Test-Path $png17)) {
    Write-Host "  FAIL  font-metrics: o render nao produziu PNG"
    exit 1
}

Write-Host ""
Write-Host "font-metrics (o em-square e o espaco sao DE CADA FACE, nao constantes)"
$bmp17 = New-Object System.Drawing.Bitmap $png17
try {
    # ponta direita da tinta na faixa y0..y1
    function FimDaTinta($bmp, $y0, $y1) {
        $mx = -1
        for ($y = $y0; $y -le $y1; $y++) {
            for ($x = $bmp.Width - 1; $x -gt $mx; $x--) {
                $p = $bmp.GetPixel($x, $y)
                if ($p.R -lt 160) { if ($x -gt $mx) { $mx = $x }; break }
            }
        }
        return $mx
    }
    # as quatro faixas tem 24px de altura, na ordem do fixture
    $mono  = FimDaTinta $bmp17 2 23
    $serif = FimDaTinta $bmp17 26 47
    $esp   = FimDaTinta $bmp17 50 71
    $junto = FimDaTinta $bmp17 74 95

    # ⚠️ tolerancia dos DOIS lados: so "chegou perto" nao pega texto grande
    # demais, e so "nao passou" nao pega texto pequeno demais.
    Assert "Consolas: 20 'M' acabam no avanco da PROPRIA face" `
        ($mono -ge 185 -and $mono -le 205) `
        ("fim=" + $mono + ", esperado ~196 (20+176); com a constante velha dava ~240")
    Assert "Georgia: 20 'M' acabam no avanco da PROPRIA face" `
        ($serif -ge 306 -and $serif -le 326) `
        ("fim=" + $serif + ", esperado ~317 (20+297); com a constante velha dava ~380")
    # ⚠️ afirma a DIFERENCA, nao a ponta: as duas faixas tem os mesmos 10 'M', so
    # que uma tem 9 espacos entre eles. Assim o teste isola o avanco do ESPACO e
    # nao se deixa enganar pelo em-square (com as constantes velhas o em grande e
    # o espaco pequeno se cancelavam parcialmente, e uma asserção de ponta passava
    # nos DOIS binarios -- medido: 177, bem na borda da faixa que eu tinha posto).
    $porEspaco = ($esp - $junto) / 9.0
    Assert "espaco de monoespacada vale um avanco INTEIRO" `
        ($porEspaco -ge 7.5 -and $porEspaco -le 10.0) `
        ("por espaco=" + [math]::Round($porEspaco,2) + "px, esperado ~8.8 (0.5498em x 16); com a fracao 0.28em dava ~4.4")
    Assert "CONTROLE sem espacos a mesma faixa acaba MUITO antes" `
        ($junto -lt $esp - 50) `
        ("junto=" + $junto + " x com espacos=" + $esp + " (a diferenca E' o avanco do espaco)")
} finally {
    $bmp17.Dispose()
}

# ---------------------------------------------------------------- caso 18
# A leitura de kerning precisa atravessar GPOS ExtensionPos das fontes Windows.
# Compara tanto a tinta quanto o fundo dimensionado por width:max-content:
# corrigir so a MEDIDA ou so a PINTURA faz as diferencas divergirem.
$fixture18 = Join-Path $PSScriptRoot "tests\paint\kerning.html"
$png18 = Join-Path $outDir "kerning.png"
if (Test-Path $png18) { Remove-Item -LiteralPath $png18 -Force }
& $Browser --render $fixture18 $png18 600 280 0 0 3 | Out-Null
if (-not (Test-Path $png18)) { Write-Host "FAIL kerning: sem PNG"; exit 1 }
$bmp18 = New-Object System.Drawing.Bitmap $png18
try {
    function FimDoFundo($bmp, $y) {
        for ($x = $bmp.Width-1; $x -ge 0; $x--) {
            $p = $bmp.GetPixel($x, $y)
            if ($p.R -eq 219 -and $p.G -eq 234 -and $p.B -eq 254) { return $x }
        }
        return -1
    }
    Write-Host ""
    Write-Host "kerning (GPOS ExtensionPos, medida e pintura)"
    foreach ($row in @(0,2)) {
        $normalInk = FimDaTinta $bmp18 ($row*64) ($row*64+63)
        $noneInk = FimDaTinta $bmp18 (($row+1)*64) (($row+1)*64+63)
        $normalBg = FimDoFundo $bmp18 ($row*64+2)
        $noneBg = FimDoFundo $bmp18 (($row+1)*64+2)
        $family = if ($row -eq 0) { "Segoe UI" } else { "Segoe UI + letter-spacing" }
        Assert "$family normal reduz o avanco visivel vs none" `
            ($normalInk -gt 100 -and $noneInk -gt $normalInk+4) `
            ("normal="+$normalInk+", none="+$noneInk)
        Assert "$family medida e pintura aplicam o mesmo ajuste" `
            ($normalBg -gt 100 -and $noneBg -gt $normalBg+4 -and [math]::Abs(($noneBg-$normalBg)-($noneInk-$normalInk)) -le 1) `
            ("delta fundo="+($noneBg-$normalBg)+", delta tinta="+($noneInk-$normalInk))
    }
} finally { $bmp18.Dispose() }

# Acabamento: cantos sem alpha duplicado, interior arredondado e sombras CSS.
$finishPng = Join-Path $outDir "paint-finish.png"
if (Test-Path $finishPng) { Remove-Item -LiteralPath $finishPng -Force }
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\paint-finish.html") $finishPng 400 280 0 0 3 | Out-Null
if (-not (Test-Path $finishPng)) { throw "paint-finish: sem PNG" }
$finish = New-Object System.Drawing.Bitmap $finishPng
try {
    $corner = $finish.GetPixel(24,24)
    Assert "borda translucida: canto nao acumula alpha" ($corner.R -gt 245 -and $corner.G -ge 120 -and $corner.G -le 135) ("pixel="+$corner)
    $inside = $finish.GetPixel(184,42)
    Assert "borda desigual arredondada preserva interior" ($inside.R -gt 245 -and $inside.G -gt 245 -and $inside.B -gt 245) ("pixel="+$inside)
    $black = $finish.GetPixel(90,210)
    Assert "sombra preta opaca permanece opaca" ($black.R -lt 5 -and $black.G -lt 5 -and $black.B -lt 5) ("pixel="+$black)
    $red = $finish.GetPixel(210,210)
    Assert "primeira sombra fica por cima" ($red.R -gt 245 -and $red.B -lt 5) ("pixel="+$red)
    $green = $finish.GetPixel(330,210)
    Assert "sombra sem cor usa currentColor" ($green.G -ge 120 -and $green.G -le 135 -and $green.R -lt 5) ("pixel="+$green)
} finally { $finish.Dispose() }

# Pausa + delay negativo tornam a amostra de animacao deterministica.
$animPng = Join-Path $outDir "animation-forms.png"
if (Test-Path $animPng) { Remove-Item -LiteralPath $animPng -Force }
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\animation-forms.html") $animPng 500 240 0 0 3 | Out-Null
if (-not (Test-Path $animPng)) { throw "animation-forms: sem PNG" }
$animBmp = New-Object System.Drawing.Bitmap $animPng
try {
    $linear = $animBmp.GetPixel(40,40)
    $reverse = $animBmp.GetPixel(120,40)
    $steps = $animBmp.GetPixel(200,40)
    $delay = $animBmp.GetPixel(280,40)
    Assert "animation linear pausada preserva progresso de 25%" ($linear.R -ge 60 -and $linear.R -le 68) ("pixel="+$linear)
    Assert "animation reverse inverte progresso" ($reverse.R -ge 187 -and $reverse.R -le 195) ("pixel="+$reverse)
    Assert "animation steps preserva salto discreto" ($steps.R -lt 5) ("pixel="+$steps)
    Assert "animation sem backwards preserva fundo durante delay" ($delay.R -gt 245 -and $delay.G -lt 5) ("pixel="+$delay)
} finally { $animBmp.Dispose() }

# Transforms 3D achatados + backface-visibility. O mouse fica em (550,50): so o
# cartao #h esta em :hover. A segunda rodada, com o mouse fora, e o controle dele.
function Px3d($bmp, $x, $y, $r, $g, $b) {
    $p = $bmp.GetPixel($x, $y)
    return ([Math]::Abs($p.R - $r) -le 6 -and [Math]::Abs($p.G - $g) -le 6 -and [Math]::Abs($p.B - $b) -le 6)
}
$x3dPng = Join-Path $outDir "transform-3d.png"
$x3dOff = Join-Path $outDir "transform-3d-off.png"
foreach ($f in @($x3dPng, $x3dOff)) { if (Test-Path $f) { Remove-Item -LiteralPath $f -Force } }
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\transform-3d.html") $x3dPng 640 320 550 50 3 | Out-Null
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\transform-3d.html") $x3dOff 640 320 0 0 3 | Out-Null
if (-not (Test-Path $x3dPng) -or -not (Test-Path $x3dOff)) { throw "transform-3d: sem PNG" }
$x3d = New-Object System.Drawing.Bitmap $x3dPng
$x3o = New-Object System.Drawing.Bitmap $x3dOff
try {
    Assert "translate3d desloca (e sai da origem)" ((Px3d $x3d 150 50 255 0 0) -and (Px3d $x3d 50 50 255 255 255)) ("pixel="+$x3d.GetPixel(150,50))
    Assert "matrix3d: a 4a coluna e a translacao" ((Px3d $x3d 310 250 255 0 0) -and (Px3d $x3d 225 250 255 255 255)) ("pixel="+$x3d.GetPixel(310,250))
    Assert "rotateX(60deg) encolhe a altura pela metade" ((Px3d $x3d 50 150 255 0 0) -and (Px3d $x3d 50 125 255 255 255)) ("pixel="+$x3d.GetPixel(50,125))
    Assert "X90 . X-90 e a identidade (projeta o PRODUTO)" (Px3d $x3d 50 225 255 0 0) ("pixel="+$x3d.GetPixel(50,225))
    Assert "Y180 . Z90 troca os eixos: o canto marcado fica no lugar" ((Px3d $x3d 130 230 0 0 0) -and (Px3d $x3d 170 230 255 0 0) -and (Px3d $x3d 170 270 255 0 0)) ("pixel="+$x3d.GetPixel(130,230))
    Assert "flip-card parado: o verso (rotateY 180) fica escondido" (Px3d $x3d 250 50 0 0 255) ("pixel="+$x3d.GetPixel(250,50))
    Assert "flip-card virado com preserve-3d: frente some, verso desespelhado" ((Px3d $x3d 325 50 255 255 255) -and (Px3d $x3d 350 50 0 0 0) -and (Px3d $x3d 370 50 255 165 0)) ("pixel="+$x3d.GetPixel(325,50))
    Assert "virado SEM preserve-3d: achata, e a frente sai espelhada" ((Px3d $x3d 470 50 0 0 0) -and (Px3d $x3d 430 50 0 0 255)) ("pixel="+$x3d.GetPixel(470,50))
    Assert "flip no :hover mostra o verso" ((Px3d $x3d 525 50 255 255 255) -and (Px3d $x3d 550 50 0 0 0) -and (Px3d $x3d 570 50 255 165 0)) ("pixel="+$x3d.GetPixel(550,50))
    Assert "o mesmo cartao SEM hover mostra a frente" ((Px3d $x3o 525 50 0 0 255) -and (Px3d $x3o 570 50 0 0 255)) ("pixel="+$x3o.GetPixel(525,50))
    Assert "backface hidden esconde o elemento virado (transform)" (Px3d $x3d 250 150 0 128 0) ("pixel="+$x3d.GetPixel(250,150))
    Assert "backface hidden esconde o elemento virado (prop rotate: y)" (Px3d $x3d 350 150 0 128 0) ("pixel="+$x3d.GetPixel(350,150))
    Assert "controle: scaleX(-1) espelha sem virar a face" (Px3d $x3d 150 150 0 128 0) ("pixel="+$x3d.GetPixel(150,150))
    Assert "translateZ(0) cria stacking context" (Px3d $x3d 450 150 0 128 0) ("pixel="+$x3d.GetPixel(450,150))
    Assert "controle: translate(0) cria o mesmo contexto" (Px3d $x3d 550 150 0 128 0) ("pixel="+$x3d.GetPixel(550,150))
} finally { $x3d.Dispose(); $x3o.Dispose() }

# Listas: canais independentes, ultima animacao vence, identidade e eventos DOM.
$listPng = Join-Path $outDir "animation-lists.png"
if (Test-Path $listPng) { Remove-Item -LiteralPath $listPng -Force }
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\animation-lists.html") $listPng 360 100 0 0 3 | Out-Null
if (-not (Test-Path $listPng)) { throw "animation-lists: sem PNG" }
$listBmp = New-Object System.Drawing.Bitmap $listPng
try {
    Assert "animation lista combina opacidade e fundo" (Px3d $listBmp 50 50 127 127 255) ("pixel="+$listBmp.GetPixel(50,50))
    Assert "animation posterior vence na mesma propriedade" (Px3d $listBmp 130 50 64 64 64) ("pixel="+$listBmp.GetPixel(130,50))
    Assert "animation transform identidade substitui escala zero" (Px3d $listBmp 210 50 0 0 0) ("pixel="+$listBmp.GetPixel(210,50))
    Assert "animationstart/end entregam nome e tempo e atualizam DOM" (Px3d $listBmp 290 50 0 255 0) ("pixel="+$listBmp.GetPixel(290,50))
} finally { $listBmp.Dispose() }

# Pausar por clique precisa conservar o instante, inclusive no --render.
$liveRef = Join-Path $outDir "animation-live-reference.png"
$livePause = Join-Path $outDir "animation-live-paused.png"
foreach ($f in @($liveRef,$livePause)) { if(Test-Path $f) { Remove-Item -LiteralPath $f -Force } }
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\animation-live.html") $liveRef 1040 620 0 0 179 | Out-Null
& $Browser --render (Join-Path $PSScriptRoot "tests\paint\animation-live.html") $livePause 1040 620 100 180 180 0 0 1 | Out-Null
if (-not (Test-Path $liveRef) -or -not (Test-Path $livePause)) { throw "animation-live: sem PNG" }
$refBmp=New-Object System.Drawing.Bitmap $liveRef
$pauseBmp=New-Object System.Drawing.Bitmap $livePause
try {
    $fade=$refBmp.GetPixel(134,300); $combo=$refBmp.GetPixel(818,300)
    Assert "animation pausa por clique preserva os relogios" ((Px3d $pauseBmp 134 300 $fade.R $fade.G $fade.B) -and (Px3d $pauseBmp 818 300 $combo.R $combo.G $combo.B)) ("antes="+$combo+", pausa="+$pauseBmp.GetPixel(818,300))
} finally { $refBmp.Dispose(); $pauseBmp.Dispose() }

# Contextos: a mesma fixture roda sozinha para comparacao antes/depois.
& (Join-Path $PSScriptRoot "tools/check-stacking.ps1") -Browser $Browser
Assert "24 casos de contexto de empilhamento" ($LASTEXITCODE -eq 0) "ver casos acima"

if (-not $Keep) { Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host ("=== paint-check: " + ($checks - $fails) + " PASS / " + $fails + " FAIL (de " + $checks + ") ===")
if ($fails -gt 0) { exit 1 }
exit 0
