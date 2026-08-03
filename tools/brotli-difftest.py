#!/usr/bin/env python3
"""Prova diferencial em VOLUME do decodificador de Brotli.

    python tools\\brotli-difftest.py [pasta_de_saida]

Gera pares NOME.br / NOME.raw com o brotli de REFERENCIA e chama
`browser.exe --brotlitest <pasta>`, que exige igualdade byte a byte em todos.

O ponto nao e "dados variados": e varrer as DECISOES do codificador. A mesma
entrada compactada em qualidade 0 e em 11, ou com janela 10 e 24, produz
streams que usam partes DIFERENTES do formato -- codigo de prefixo simples x
complexo, bloco nao comprimido, muitas arvores de literal, distancias longas,
meta-blocos multiplos. Um decodificador pode acertar todos os vetores de
qualidade 11 e errar o caminho de qualidade 1.
"""
import os, sys, subprocess, random, shutil

out = sys.argv[1] if len(sys.argv) > 1 else "brotli-difftest-out"
exe = os.path.abspath("browser.exe")
if not os.path.exists(exe):
    sys.exit("browser.exe nao encontrado — buildar antes")
try:
    import brotli
except ImportError:
    sys.exit("preciso do brotli de referencia: python -m pip install brotli")

random.seed(20260729)
if os.path.isdir(out):
    shutil.rmtree(out)
os.makedirs(out)

def texto(n):
    pal = ("the of and to in a is that for it as was with be by on not he i this "
           "are or his from at which but have an they which one you were her all "
           "http://www.example.com/index.html <div class=\"x\"> </span> ".split(" "))
    s = []
    while sum(len(x) + 1 for x in s) < n:
        s.append(random.choice(pal))
    return (" ".join(s)).encode()[:n]

def estruturado(n):
    # blocos que se repetem em periodos diferentes: distancias curtas e longas
    parts, i = [], 0
    while sum(len(p) for p in parts) < n:
        i += 1
        if i % 3 == 0:
            parts.append(bytes([i & 0xff]) * random.randint(1, 900))
        elif i % 3 == 1:
            parts.append(texto(random.randint(50, 700)))
        else:
            parts.append(bytes(random.getrandbits(8) for _ in range(random.randint(20, 300))))
    return b"".join(parts)[:n]

def binario(n):
    # dados quase-aleatorios: forca o caminho de meta-bloco NAO COMPRIMIDO
    return bytes(random.getrandbits(8) for _ in range(n))

def utf8(n):
    base = ("Olá mundo ação coração informação Grüße München "
            "Ямб что-то по-русски 日本語のテキスト ").encode()
    return (base * (n // len(base) + 1))[:n]

geradores = [("texto", texto), ("estr", estruturado), ("bin", binario), ("utf8", utf8)]
tamanhos = [0, 1, 2, 3, 7, 31, 200, 1500, 9000, 60000, 300000]

casos = 0
manifesto = []
for gname, gen in geradores:
    for n in tamanhos:
        raw = gen(n) if n else b""
        for q in (0, 1, 2, 5, 9, 11):
            for lg in (10, 16, 24):
                # janela grande em entrada pequena e desperdicio; poda o obvio
                if lg > 16 and n < 9000:
                    continue
                try:
                    comp = brotli.compress(raw, quality=q, lgwin=lg)
                except Exception as e:
                    print("compress falhou (%s n=%d q=%d lg=%d): %s" % (gname, n, q, lg, e))
                    continue
                nome = "%s_%d_q%d_w%d" % (gname, n, q, lg)
                open(os.path.join(out, nome + ".br"), "wb").write(comp)
                open(os.path.join(out, nome + ".raw"), "wb").write(raw)
                manifesto.append((nome, os.path.abspath(os.path.join(out, nome + ".br")),
                                  os.path.abspath(os.path.join(out, nome + ".raw")), len(raw)))
                casos += 1

# Nota: meta-bloco de METADADOS e meta-bloco NAO COMPRIMIDO nao sao produzidos
# de forma confiavel por este codificador, entao nao ha como cobri-los aqui.
# Esses dois ramos tem vetor montado a mao em src/brotli/brotli_test.odin.

man_path = os.path.abspath(os.path.join(out, "manifesto.txt"))
with open(man_path, "w", encoding="utf-8", newline="\n") as f:
    for nome, br, rawp, n in manifesto:
        f.write("%s\t%s\t%s\t%d\n" % (nome, br, rawp, n))
print("gerados %d pares em %s" % (casos, out))

r = subprocess.run([exe, "--brotlitest", man_path], capture_output=True, text=True)
saida = (r.stdout or "") + (r.stderr or "")
print(saida.strip()[-4000:])
if "TOTAL:" not in saida:
    sys.exit("o binario nao chegou a imprimir TOTAL: — resultado INVALIDO, nao 'ruim'")
# o binario diz quantos casos rodou; tem de ser o numero que geramos
esperado = "TOTAL: %d OK, 0 BAD" % casos
if esperado not in saida:
    sys.exit("esperava %r — se o numero de OK for menor, casos foram PULADOS" % esperado)
sys.exit(r.returncode)
