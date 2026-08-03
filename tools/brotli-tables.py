#!/usr/bin/env python3
"""Gera as tabelas do Brotli a partir do TEXTO da RFC 7932.

    python tools\\brotli-tables.py rfc7932.txt src\\brotli

Baixe a RFC de https://www.rfc-editor.org/rfc/rfc7932.txt

Por que gerar em vez de digitar: sao 122.784 bytes de dicionario estatico, 121
transformacoes e tres tabelas de 256 bytes. Digitar isso a mao erra em silencio,
e o erro so aparece como saida CORROMPIDA num stream especifico. A RFC publica o
CRC-32 de cada uma dessas tabelas -- este script confere os cinco CRC e se recusa
a escrever qualquer arquivo se um deles divergir. Os mesmos CRC sao reconferidos
em tempo de teste (brotli_test.odin), de modo que uma edicao a mao no arquivo
gerado tambem e pega.
"""
import re, sys, binascii, codecs, os

src_path = sys.argv[1] if len(sys.argv) > 1 else "rfc7932.txt"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "."
lines = open(src_path, "r", encoding="utf-8", errors="replace").read().split("\n")

def is_junk(l):
    return ("Alakuijala" in l) or ("RFC 7932" in l) or ("[Page" in l) or ("\x0c" in l)

def find(marker, start=0):
    for i in range(start, len(lines)):
        if marker in lines[i]:
            return i
    sys.exit("marcador nao achado no texto da RFC: " + marker)

ok_all = True
def check(name, data, want_len, want_crc):
    global ok_all
    crc = binascii.crc32(data) & 0xffffffff
    good = len(data) == want_len and crc == want_crc
    ok_all = ok_all and good
    print("%-8s len=%-7d (quer %-7d)  crc=0x%08x (quer 0x%08x)  %s" %
          (name, len(data), want_len, crc, want_crc, "OK" if good else "*** DIFERE ***"))

# ---- Appendix A: dicionario estatico ---------------------------------------
a0 = find("Appendix A.  Static Dictionary Data")
a1 = find("Appendix B.  List of Word Transformations", a0)
DICT = binascii.unhexlify("".join(
    s for l in lines[a0:a1] if not is_junk(l)
    for s in [l.strip()] if re.fullmatch(r"[0-9a-f]{8,}", s)))
check("DICT", DICT, 122784, 0x5136cb04)

# ---- Appendix B: as 121 transformacoes -------------------------------------
b1 = find("Appendix C.", a1)
KIND = {"Identity": 0, "FermentFirst": 1, "FermentAll": 2}
for i in range(1, 10):
    KIND["OmitFirst%d" % i] = 2 + i
    KIND["OmitLast%d" % i] = 11 + i
row = re.compile(r'^\s*(\d+)\s+"((?:[^"\\]|\\.)*)"\s+(\S+)\s+"((?:[^"\\]|\\.)*)"\s*$')
unesc = lambda s: codecs.decode(s, "unicode_escape").encode("latin-1")

trans = []
for l in lines[a1:b1]:
    if is_junk(l):
        continue
    m = row.match(l)
    if not m:
        continue
    if int(m.group(1)) != len(trans):
        sys.exit("transformacao fora de ordem em: %r" % l)
    if m.group(3) not in KIND:
        sys.exit("transformacao elementar desconhecida: %r" % m.group(3))
    trans.append((unesc(m.group(2)), KIND[m.group(3)], m.group(3), unesc(m.group(4))))
# a serializacao conferida pelo CRC e a que a propria RFC descreve:
# prefixo + \0 + byte do tipo + sufixo + \0, concatenados
check("TRANSF", b"".join(p + b"\0" + bytes([k]) + s + b"\0" for p, k, _, s in trans),
      648, 0x3d965f81)

# ---- 7.1: Lut0 / Lut1 / Lut2 -----------------------------------------------
def read_lut(name):
    out, j = [], find(name + " :=") + 1
    while len(out) < 256 and j < len(lines):
        l, j = lines[j], j + 1
        if is_junk(l) or not l.strip():
            continue
        if not re.fullmatch(r"[\s\d,]+", l):
            break
        out += [int(x) for x in re.findall(r"\d+", l)]
    return bytes(out)

LUT = {}
for nm, crc in (("Lut0", 0x8e91efb7), ("Lut1", 0xd01a32f4), ("Lut2", 0x0dd7a0d6)):
    LUT[nm] = read_lut(nm)
    check(nm, LUT[nm], 256, crc)

if not ok_all:
    sys.exit("EXTRACAO REPROVADA pelos CRC da RFC -- nenhum arquivo foi escrito")

# ---- saida ------------------------------------------------------------------
os.makedirs(out_dir, exist_ok=True)
open(os.path.join(out_dir, "dict.bin"), "wb").write(DICT)

def odin_str(b):
    out = ""
    for c in b:
        if c == 0x22: out += '\\"'
        elif c == 0x5c: out += "\\\\"
        elif c == 0x0a: out += "\\n"
        elif c == 0x0d: out += "\\r"
        elif c == 0x09: out += "\\t"
        elif 0x20 <= c < 0x7f: out += chr(c)
        else: out += "\\x%02x" % c
    return '"' + out + '"'

with open(os.path.join(out_dir, "tables.odin"), "w", encoding="utf-8") as f:
    f.write("package brotli\n\n")
    f.write("// GERADO por tools/brotli-tables.py a partir do texto da RFC 7932.\n")
    f.write("// NAO EDITAR A MAO. A RFC publica o CRC-32 de cada uma destas tabelas\n")
    f.write("// (apendices A e B, secao 7.1) e brotli_test.odin os reconfere, entao\n")
    f.write("// um valor trocado aqui derruba o teste em vez de corromper a saida.\n")
    f.write("//\n")
    f.write("// @(rodata) e nao `::`: uma CONSTANTE de Odin nao tem endereco e por isso\n")
    f.write("// nao pode ser indexada por valor de RUNTIME (`Cannot index a constant`),\n")
    f.write("// que e como todas estas sao usadas. O @(rodata) da o endereco sem abrir\n")
    f.write("// mao da imutabilidade (mesmo tratamento de NDBITS em brotli.odin).\n\n")
    f.write("// As 121 transformacoes de palavra do dicionario (apendice B).\n")
    f.write("@(rodata)\n")
    f.write("TRANSFORMS := [%d]Transform{\n" % len(trans))
    for i, (p, k, kn, s) in enumerate(trans):
        f.write("    {%s, .%s, %s}, // %d\n" % (odin_str(p), kn, odin_str(s), i))
    f.write("}\n\n")
    f.write("// Tabelas de ID de contexto para os modos UTF8 e Signed (secao 7.1).\n")
    for nm in ("Lut0", "Lut1", "Lut2"):
        f.write("@(rodata)\n")
        f.write("%s := [256]u8{\n" % nm.upper())
        for r in range(16):
            f.write("    " + ", ".join("%d" % v for v in LUT[nm][r * 16:(r + 1) * 16]) + ",\n")
        f.write("}\n\n")
print("gerados em %s: dict.bin, tables.odin" % out_dir)
