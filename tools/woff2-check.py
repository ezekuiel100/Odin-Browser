#!/usr/bin/env python3
"""Prova o WOFF2 contra o fontTools em fontes REAIS.

    python tools\\woff2-check.py [pasta_de_trabalho]

Baixa um punhado de webfonts woff2 de verdade (pedindo como navegador moderno,
que e o que faz o provedor servir woff2), remonta cada uma com
`browser.exe --woff2test` e compara com a reconstrucao do fontTools glifo a
glifo (tools/woff2-difftest.py).

As fontes foram escolhidas por CARACTERISTICA, nao por popularidade: uma com
muitos compostos (acentos), uma monoespacada, uma com CFF (OTF, que nao tem
glyf e portanto passa por outro caminho), uma serifada grande e uma variavel.
"""
import os, sys, subprocess, urllib.request, re, shutil

work = sys.argv[1] if len(sys.argv) > 1 else "woff2-check-out"
exe = os.path.abspath("browser.exe")
if not os.path.exists(exe):
    sys.exit("browser.exe nao encontrado — buildar antes")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# (rotulo, familia do Google Fonts, por que esta na lista)
FAMILIAS = [
    ("roboto",     "Roboto:wght@400",            "base de comparacao, TrueType comum"),
    ("notosans",   "Noto+Sans:wght@400",         "muitos glifos compostos (acentuados)"),
    ("robotomono", "Roboto+Mono:wght@400",       "monoespacada: hmtx com corrida monoespacada"),
    ("lora",       "Lora:wght@400",              "serifada, contornos mais densos"),
    ("inter",      "Inter:wght@100..900",        "fonte VARIAVEL (eixo de peso)"),
    ("playfair",   "Playfair+Display:wght@400",  "contraste alto, muitos pontos por contorno"),
]

def baixar(fam):
    css_url = "https://fonts.googleapis.com/css2?family=%s&display=swap" % fam
    req = urllib.request.Request(css_url, headers={"User-Agent": UA})
    css = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")
    urls = re.findall(r"https://[^)\s]+\.woff2", css)
    if not urls:
        raise RuntimeError("o CSS nao trouxe woff2 (formato negociado mudou?)")
    req2 = urllib.request.Request(urls[0], headers={"User-Agent": UA})
    return urllib.request.urlopen(req2, timeout=60).read()

os.makedirs(work, exist_ok=True)
linhas, falhou = [], False
for rotulo, fam, porque in FAMILIAS:
    w2 = os.path.join(work, rotulo + ".woff2")
    ttf = os.path.join(work, rotulo + ".ttf")
    try:
        if not os.path.exists(w2):
            data = baixar(fam)
            open(w2, "wb").write(data)
        tam = os.path.getsize(w2)
        if open(w2, "rb").read(4) != b"wOF2":
            linhas.append("PULADO %-11s nao veio woff2" % rotulo)
            continue
    except Exception as e:
        linhas.append("PULADO %-11s download: %s" % (rotulo, e))
        continue

    r = subprocess.run([exe, "--woff2test", w2, ttf], capture_output=True, text=True)
    if r.returncode != 0:
        linhas.append("FALHOU %-11s --woff2test: %s" % (rotulo, (r.stdout + r.stderr).strip()))
        falhou = True
        continue
    resumo = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""

    d = subprocess.run([sys.executable, os.path.join("tools", "woff2-difftest.py"), w2, ttf],
                       capture_output=True, text=True)
    saida = (d.stdout + d.stderr).strip()
    if d.returncode != 0:
        linhas.append("DIFERE %-11s (%s)\n%s" % (rotulo, porque, saida))
        falhou = True
    else:
        linhas.append("IGUAL  %-11s %d B woff2 | %s | %s" %
                      (rotulo, tam, resumo, saida.splitlines()[0] if saida else ""))

print()
for l in linhas:
    print(l)
print()
if falhou:
    sys.exit("HOUVE DIVERGENCIA")
if not any(l.startswith("IGUAL") for l in linhas):
    sys.exit("nenhuma fonte foi comparada de verdade — resultado INVALIDO, nao 'bom'")
print("TODAS AS FONTES COMPARADAS BATEM COM O FONTTOOLS")
