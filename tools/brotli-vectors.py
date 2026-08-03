#!/usr/bin/env python3
"""Gera os vetores de teste do decodificador de Brotli.

    python tools\\brotli-vectors.py src\\brotli\\testdata [rfc7932.txt] [fonte.woff2]

Para cada caso escreve NOME.raw (o esperado) e NOME.br (o comprimido pelo
brotli de REFERENCIA). O teste em Odin carrega os dois com #load e exige
igualdade byte a byte -- o oraculo e a implementacao de referencia, nao a
minha leitura da RFC.

Os casos foram escolhidos por qual PARTE do formato exercitam, nao por
serem "dados variados": ver o comentario de cada um.
"""
import os, sys, brotli

out = sys.argv[1] if len(sys.argv) > 1 else "."
rfc = sys.argv[2] if len(sys.argv) > 2 else None
w2f = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(out, exist_ok=True)

cases = {}

# meta-bloco vazio / ISLASTEMPTY
cases["empty"] = b""
# caminho mais curto que existe: um comando, so literais
cases["hello"] = b"hello"
# referencias para tras curtas e repetidas: exercita o ANEL de distancias
# (simbolos 0..15) e o "distancia implicita zero" dos codigos cmd < 128
cases["repeat"] = b"abcabcabcabcabcabcabcabcabc" * 40
# copia longa com sobreposicao e distancia 1
cases["zeros"] = b"\x00" * 100000
# incompressivel: forca meta-bloco ISUNCOMPRESSED. Semente fixa para o vetor
# ser reproduzivel -- os.urandom faria o arquivo mudar a cada geracao.
import random
random.seed(20260729)
cases["random"] = bytes(random.getrandbits(8) for _ in range(3000))
# texto ASCII com estrutura de linguagem: modo de contexto UTF8, varias
# arvores de literal, mapa de contexto com corridas de zero
cases["html"] = (b'<!doctype html>\n<html lang="en">\n<head>\n'
                 b'<meta charset="utf-8">\n<title>The quick brown fox</title>\n'
                 b'</head>\n<body>\n<div class="content">\n' +
                 b'<p>The quick brown fox jumps over the lazy dog.</p>\n' * 60 +
                 b'</div>\n</body>\n</html>\n')
# texto nao-ASCII: o Ferment* das transformacoes e ciente de UTF-8, e o modo
# de contexto UTF8 usa as duas Luts de verdade
cases["utf8"] = ("Olá, mundo. Ação, coração, informação. "
                 "Ямб, что-то по-русски. 日本語のテキストです。 "
                 "Grüße aus München — schöne Grüße!\n").encode("utf-8") * 30
# palavras do dicionario estatico: entradas curtas e "de site" sao onde o
# codificador de referencia acha vantagem em referenciar o dicionario em vez
# de emitir literais. Se nenhum destes exercitar o dicionario, o proprio
# decodificador acusa (ele conta as referencias) e o vetor e trocado.
cases["dict"] = (b'<a href="http://www.example.com/index.html">click here</a>'
                 b' Copyright 2016 All rights reserved. Terms of Service'
                 b' <div class="footer"><span style="display:none">')
cases["dictwords"] = b"timedownlifeleftbackcodedatashowonlysitecityopenjustlikefreework"

if rfc:
    # texto real e grande: muitos meta-blocos, muitas arvores, distancias longas
    cases["rfctext"] = open(rfc, "rb").read()[:65536]

for name, raw in sorted(cases.items()):
    comp = brotli.compress(raw, quality=11)
    open(os.path.join(out, name + ".raw"), "wb").write(raw)
    open(os.path.join(out, name + ".br"), "wb").write(comp)
    # sanidade: o proprio oraculo tem de fechar o ciclo
    assert brotli.decompress(comp) == raw, name
    print("%-12s raw=%-7d br=%-7d" % (name, len(raw), len(comp)))

# O ALVO de verdade: o stream de dentro de um woff2 real. Vem do arquivo em vez
# de ser recomprimido, porque o que interessa e o stream que o encoder do
# provedor produziu -- nao um que este script produziria.
if w2f:
    import struct
    b = open(w2f, "rb").read()
    assert b[:4] == b"wOF2", w2f
    num = struct.unpack_from(">H", b, 12)[0]
    total_comp = struct.unpack_from(">I", b, 20)[0]
    KNOWN_GL = (10, 11)  # indices de glyf e loca na tabela de tags conhecidas
    o = 48
    for _ in range(num):
        flags = b[o]; o += 1
        idx, tv = flags & 0x3f, (flags >> 6) & 3
        if idx == 63:
            o += 4
        transformada = (tv == 0) if idx in KNOWN_GL else (tv != 0)
        for _campo in range(2 if transformada else 1):
            while b[o] & 0x80:
                o += 1
            o += 1
    comp = b[o:o + total_comp]
    raw = brotli.decompress(comp)
    open(os.path.join(out, "woff2stream.br"), "wb").write(comp)
    open(os.path.join(out, "woff2stream.raw"), "wb").write(raw)
    print("%-12s raw=%-7d br=%-7d  (extraido de %s)" %
          ("woff2stream", len(raw), len(comp), os.path.basename(w2f)))

print("%d casos em %s" % (len(cases) + (1 if w2f else 0), out))
