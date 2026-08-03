#!/usr/bin/env python3
"""Gera as tabelas do WOFF2 a partir do HTML da spec.

    python tools\\woff2-tables.py WOFF2.html src\\woff2

Baixe a spec de https://www.w3.org/TR/WOFF2/

Duas tabelas nao dao para digitar sem errar em silencio: a codificacao por
TRIPLETO (128 linhas x 7 colunas, que decide como cada par de coordenadas foi
empacotado) e as 63 tags conhecidas do diretorio. Diferente da RFC do Brotli,
a spec do WOFF2 nao publica CRC -- entao o que confere a extracao sao
INVARIANTES estruturais, reconferidas em woff2_test.odin:

  * byteCount == 1 + ceil((xbits+ybits)/8) nas 128 linhas
  * xbits+ybits == 8*(byteCount-1) exatamente (nao ha bit de sobra, o que e o
    que torna a decodificacao nao-ambigua)
  * as 63 tags tem 4 bytes depois do preenchimento com espaco
"""
import re, html, sys, os

src_path = sys.argv[1] if len(sys.argv) > 1 else "WOFF2.html"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "."
src = open(src_path, encoding="utf-8", errors="replace").read()
src = re.sub(r"(?is)<(script|style).*?</\1>", " ", src)

def cells(row):
    out = []
    for m in re.finditer(r"(?is)<t[dh][^>]*>(.*?)</t[dh]>", row):
        t = re.sub(r"(?s)<[^>]+>", " ", m.group(1))
        out.append(html.unescape(t).strip())
    return out

tables = re.findall(r"(?is)<table[^>]*>(.*?)</table>", src)

# ---- tripleto ---------------------------------------------------------------
trip = None
for tb in tables:
    rows = [cells(r) for r in re.findall(r"(?is)<tr[^>]*>(.*?)</tr>", tb)]
    body = [r for r in rows if len(r) == 8 and re.fullmatch(r"\d+", r[0] or "")]
    if len(body) == 128:
        trip = body
        break
if trip is None:
    sys.exit("tabela de tripleto nao encontrada com 128 linhas")

# A tabela deixa a celula VAZIA quando o valor repete o da linha de cima
# ("idem"). "N/A" e um valor de verdade (eixo de 0 bits), nao um vazio. Se o
# preenchimento estiver errado, os invariantes abaixo denunciam.
for i in range(1, len(trip)):
    for c in range(1, 8):
        if trip[i][c] == "":
            trip[i][c] = trip[i - 1][c]
if any(c == "" for r in trip for c in r):
    sys.exit("sobrou celula vazia depois do preenchimento")

def sign(s, bits):
    s = s.strip()
    if s in ("-", "+"): return 1 if s == "-" else 0
    if s.upper() in ("N/A", "") and bits == 0: return 0
    sys.exit("sinal inesperado: %r (bits=%d)" % (s, bits))

def num(s, bits):
    s = s.strip()
    if re.fullmatch(r"-?\d+", s): return int(s)
    if s.upper() in ("N/A", "") and bits == 0: return 0
    sys.exit("numero inesperado: %r (bits=%d)" % (s, bits))

rec = []
for i, r in enumerate(trip):
    if int(r[0]) != i:
        sys.exit("indice fora de ordem: %s != %d" % (r[0], i))
    bc, xb, yb = int(r[1]), int(r[2]), int(r[3])
    dx, dy = num(r[4], xb), num(r[5], yb)
    sx, sy = sign(r[6], xb), sign(r[7], yb)
    if 1 + (xb + yb + 7) // 8 != bc:
        sys.exit("linha %d: byteCount %d nao bate com xbits=%d ybits=%d" % (i, bc, xb, yb))
    if xb + yb != 8 * (bc - 1):
        sys.exit("linha %d: xbits+ybits=%d nao enche %d bytes" % (i, xb + yb, bc - 1))
    rec.append((bc, xb, yb, dx, dy, sx, sy))
print("tripleto: 128 linhas, byteCount e soma de bits consistentes em todas")

# ---- tags conhecidas --------------------------------------------------------
tags = None
for tb in tables:
    rows = [cells(r) for r in re.findall(r"(?is)<tr[^>]*>(.*?)</tr>", tb)]
    flat = []
    for r in rows:
        # a tabela vem em pares (valor, tag) repetidos na mesma linha
        for j in range(0, len(r) - 1, 2):
            if re.fullmatch(r"\d+", r[j] or ""):
                flat.append((int(r[j]), r[j + 1]))
    d = {}
    for v, t in flat:
        d.setdefault(v, t)
    # so 0..62 sao tags; 63 significa "vem uma tag arbitraria a seguir"
    if all(i in d for i in range(63)):
        tags = [d[i] for i in range(63)]
        break
if tags is None:
    sys.exit("tabela de tags conhecidas nao encontrada")

# Tag de OpenType tem SEMPRE 4 bytes, preenchida com espaco a direita; o texto
# da celula HTML perde esse espaco final ("cvt ", "CFF ", "SVG ").
bad = [t for t in tags if not t or len(t) > 4 or not t.isprintable()]
if bad:
    sys.exit("tags improvaveis: %r" % bad)
tags = [t.ljust(4) for t in tags]
print("tags conhecidas: 63, normalizadas para 4 bytes")

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "tables.odin"), "w", encoding="utf-8") as f:
    f.write("package woff2\n\n")
    f.write("// GERADO por tools/woff2-tables.py a partir do HTML da spec do WOFF2.\n")
    f.write("// NAO EDITAR A MAO. Os invariantes conferidos na geracao sao\n")
    f.write("// reconferidos em woff2_test.odin.\n")
    f.write("//\n")
    f.write("// @(rodata) e nao `::`: uma CONSTANTE de Odin nao tem endereco e por isso\n")
    f.write("// nao pode ser indexada por valor de RUNTIME (`Cannot index a constant`),\n")
    f.write("// que e exatamente como estas duas sao usadas. O @(rodata) da o endereco\n")
    f.write("// sem abrir mao da imutabilidade (mesmo tratamento de NDBITS no brotli).\n\n")
    f.write("// byte_count, x_bits, y_bits, delta_x, delta_y, x_negativo, y_negativo\n")
    f.write("@(rodata)\n")
    f.write("W2_TRIPLET := [128][7]u16{\n")
    for i, r in enumerate(rec):
        f.write("    {%s}, // %d\n" % (", ".join(str(v) for v in r), i))
    f.write("}\n\n")
    f.write("// Indices 0..62 do campo de flags do diretorio; 63 = tag explicita.\n")
    f.write("@(rodata)\n")
    f.write("W2_KNOWN_TAGS := [63]string{\n")
    for i, t in enumerate(tags):
        f.write('    "%s", // %d\n' % (t, i))
    f.write("}\n")
print("gerado em %s: tables.odin" % out_dir)
