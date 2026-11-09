package ui

// Lote 27 — `all: initial|unset|revert` (7 sites no gap-miner).
// A parte SVG do lote 27 (fill-opacity/stroke-*/fill-rule) ficou em
// style_lote23_test.odin: a família de pintura SVG (fill-opacity/…) mora lá
// porque é o mesmo caminho (Computed.svg_css), não por causa de um global.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// Computed de um elemento DENTRO de uma árvore (o test_compute_one só tem um
// elemento — ali `div{color:red}` seria DECLARAÇÃO no próprio nó, não HERANÇA,
// e o teste de all:initial não provaria nada).
@(private = "file")
comp_de :: proc(html, css, tag: string) -> Computed {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    n := dompkg.find_first(dom, tag)
    if n == nil do return {}
    return styles[n]
}

@(test)
test_prop_all :: proc(t: ^testing.T) {
    // all:initial zera até o que se HERDA: a cor vem do PAI e tem de sumir
    c := comp_de(`<div style="color:red"><p class="r">x</p></div>`, `.r{all:initial}`, "p")
    testing.expectf(t, c.color == DEFAULT_TEXT, "all:initial deveria zerar a cor HERDADA, veio %x", c.color)
    testing.expectf(t, c.opacity == 1, "all:initial precisa restaurar opacity=1 (senão a página some), veio %v", c.opacity)

    // all:unset MANTÉM a herdada (é a diferença entre os dois valores)
    c2 := comp_de(`<div style="color:#0000ff"><p class="r">x</p></div>`, `.r{all:unset}`, "p")
    testing.expectf(t, c2.color == 0x0000ff, "all:unset deveria MANTER a cor herdada, veio %x", c2.color)

    // e o revert idem (descarta autor, mantém UA/herança)
    c3 := comp_de(`<div style="color:#0000ff"><p class="r">x</p></div>`, `.r{all:revert}`, "p")
    testing.expectf(t, c3.color == 0x0000ff, "all:revert deveria MANTER a cor herdada, veio %x", c3.color)

    // declaração que acompanha o all continua valendo (uso real: `all:unset;color:x`)
    c4 := comp_de(`<div style="color:red"><p class="r">x</p></div>`, `.r{all:initial;color:#00ff00}`, "p")
    testing.expectf(t, c4.color == 0x00ff00, "prop declarada junto do all deveria valer, veio %x", c4.color)
}
