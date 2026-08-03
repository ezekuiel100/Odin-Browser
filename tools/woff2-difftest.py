#!/usr/bin/env python3
"""Compara a reconstrucao de WOFF2 do browser com a do fontTools, glifo a glifo.

    browser.exe --woff2test fonte.woff2 minha.ttf
    python tools\\woff2-difftest.py fonte.woff2 minha.ttf

Por que existe: a spec do WOFF2 diz que a reconstrucao preserva a FUNCIONALIDADE,
nao os bytes -- varias codificacoes do mesmo contorno sao validas. Logo comparar
arquivos byte a byte nao serve de nada, e comparar tamanho serve menos. O que
tem de bater e o CONTEUDO SEMANTICO: numero de contornos, pontos por contorno,
coordenadas ABSOLUTAS de cada ponto, quais pontos estao sobre a curva, as
instrucoes, a caixa de contorno e as metricas horizontais.

O oraculo e o fontTools, uma implementacao independente.
"""
import sys

try:
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("preciso do fontTools: python -m pip install fonttools brotli")

if len(sys.argv) < 3:
    sys.exit(__doc__)

ref = TTFont(sys.argv[1])   # fontTools descomprime o woff2 por conta propria
mine = TTFont(sys.argv[2])  # o que o nosso decodificador produziu

falhas = []
def cobra(cond, msg):
    if not cond:
        falhas.append(msg)
    return cond

n_ref = ref["maxp"].numGlyphs
n_mine = mine["maxp"].numGlyphs
cobra(n_ref == n_mine, "numGlyphs: %d x %d" % (n_ref, n_mine))

rg, mg = ref["glyf"], mine["glyf"]
ordem = ref.getGlyphOrder()
cobra(list(ordem) == list(mine.getGlyphOrder()), "a ordem dos glifos difere")

comparados = simples = compostos = vazios = 0
for i, nome in enumerate(ordem):
    if nome not in mg.glyphs:
        falhas.append("glifo %d (%s) nao existe na minha fonte" % (i, nome))
        continue
    a, b = rg[nome], mg[nome]
    a.expand(rg)
    b.expand(mg)
    comparados += 1
    rot = "glifo %d (%s)" % (i, nome)

    if a.numberOfContours != b.numberOfContours:
        falhas.append("%s: numberOfContours %d x %d" % (rot, a.numberOfContours, b.numberOfContours))
        continue

    if a.numberOfContours == 0:
        vazios += 1
        continue

    if a.numberOfContours > 0:
        simples += 1
        if not cobra(list(a.endPtsOfContours) == list(b.endPtsOfContours),
                     "%s: endPtsOfContours %s x %s" % (rot, a.endPtsOfContours, b.endPtsOfContours)):
            continue
        ca, cb = list(a.coordinates), list(b.coordinates)
        if not cobra(len(ca) == len(cb), "%s: %d pontos x %d" % (rot, len(ca), len(cb))):
            continue
        for k, (pa, pb) in enumerate(zip(ca, cb)):
            if pa != pb:
                falhas.append("%s: ponto %d em %s, esperava %s" % (rot, k, pb, pa))
                break
        # so o bit 0 (sobre a curva) tem significado semantico; os outros
        # descrevem a codificacao, que a spec permite ser diferente
        fa = [f & 0x01 for f in a.flags]
        fb = [f & 0x01 for f in b.flags]
        cobra(fa == fb, "%s: bits de sobre-a-curva diferem" % rot)
        # OVERLAP_SIMPLE (bit 6) so no primeiro ponto, e tem de ser preservado
        cobra((a.flags[0] & 0x40) == (b.flags[0] & 0x40),
              "%s: OVERLAP_SIMPLE %d x %d" % (rot, a.flags[0] & 0x40, b.flags[0] & 0x40))
    else:
        compostos += 1
        cca = [(c.glyphName, getattr(c, "x", None), getattr(c, "y", None), c.transform,
                getattr(c, "firstPt", None), getattr(c, "secondPt", None)) for c in a.components]
        ccb = [(c.glyphName, getattr(c, "x", None), getattr(c, "y", None), c.transform,
                getattr(c, "firstPt", None), getattr(c, "secondPt", None)) for c in b.components]
        cobra(cca == ccb, "%s: componentes diferem\n  ref  %s\n  meu  %s" % (rot, cca, ccb))

    # caixa de contorno: e ela que a spec manda CALCULAR quando o bit esta
    # desligado, e errar a conta nao aparece em nenhum outro campo
    for campo in ("xMin", "yMin", "xMax", "yMax"):
        va, vb = getattr(a, campo, None), getattr(b, campo, None)
        cobra(va == vb, "%s: %s %s x %s" % (rot, campo, va, vb))

    # instrucoes (fpgm/prep sao tabelas cruas, mas as do glifo vao pelo
    # instructionStream e podem desalinhar junto com o resto)
    pa = a.program.getBytecode() if hasattr(a, "program") and a.program else b""
    pb = b.program.getBytecode() if hasattr(b, "program") and b.program else b""
    cobra(pa == pb, "%s: instrucoes com %d x %d bytes" % (rot, len(pa), len(pb)))

# metricas horizontais: e aqui que a transform de hmtx aparece, se usada
ha, hb = ref["hmtx"], mine["hmtx"]
for nome in ordem:
    if nome in hb.metrics:
        cobra(ha[nome] == hb[nome], "hmtx[%s]: %s x %s" % (nome, ha[nome], hb[nome]))

print("comparados %d glifos (%d simples, %d compostos, %d vazios)" %
      (comparados, simples, compostos, vazios))
if falhas:
    print("\n%d DIVERGENCIAS:" % len(falhas))
    for f in falhas[:40]:
        print("  " + f)
    if len(falhas) > 40:
        print("  ... e %d outras" % (len(falhas) - 40))
    sys.exit(1)
print("IGUAIS: a reconstrucao bate com o fontTools em tudo que e semantico")
