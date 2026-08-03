package ui

// M121 — colapso de altura em flex-column (bandcamp/coingecko ficavam BLANK).
// Dois bugs de layout encadeados, ambos de spec:
//  (1) ICB: o bloco contenedor inicial usava a ALTURA DO DOCUMENTO em vez das
//      dimensões do VIEWPORT (CSS 2.1 §10.1). Com `html{position:absolute}` o root
//      sai do fluxo → altura do doc = 0 → o próprio html resolvia p/ 0 (circular).
//  (2) Tamanho mínimo AUTOMÁTICO de flex item (CSS Flexbox §4.5): min-height:auto
//      resolvia p/ 0 em vez do mínimo baseado em conteúdo. Um item `flex:1`
//      (flex-basis:0) numa linha que já transborda encolhia a ZERO e sumia.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

// Pipeline completo + layout + passe de absolutos (cópia local: o helper de
// layout_test.odin é private="file"). O ICB passado é o VIEWPORT, como na spec.
@(private = "file")
layout_from_html :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

// Primeira caixa cujo elemento tem este id (pré-ordem).
@(private = "file")
find_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == want do return b
    }
    for c in b.children {
        if r := find_id(c, want); r != nil do return r
    }
    return nil
}

@(private = "file")
find_tag :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == want do return b
    for c in b.children {
        if r := find_tag(c, want); r != nil do return r
    }
    return nil
}

// (1) ICB = viewport: um <html> absolutamente posicionado com inset:0 recebe a
// ALTURA DO VIEWPORT. Antes resolvia contra a altura do documento (=0, pois ele
// mesmo saiu do fluxo) e colapsava a página inteira — o BLANK do bandcamp.
@(test)
m121_icb_e_o_viewport :: proc(t: ^testing.T) {
    root := layout_from_html(
        `<html style="position:absolute;inset:0"><body><div>x</div></body></html>`,
        800, 600)
    h := find_tag(root, "html")
    testing.expect(t, h != nil, "achou a caixa <html>")
    if h == nil do return
    testing.expectf(t, h.h == 600, "html abspos inset:0 deve ter a altura do viewport (600), tem %.1f", h.h)
}

// Um absoluto de topo com inset:0 estica até o ICB (viewport), não até o doc.
@(test)
m121_abspos_inset_estica_ate_o_icb :: proc(t: ^testing.T) {
    root := layout_from_html(
        `<body><div id="x" style="position:absolute;inset:0"></div></body>`, 800, 600)
    x := find_id(root, "x")
    testing.expect(t, x != nil, "achou #x")
    if x == nil do return
    testing.expectf(t, x.h == 600, "abspos inset:0 deve esticar até o viewport (600), tem %.1f", x.h)
}

// (2) Mínimo automático: item `flex:1` numa coluna que JÁ TRANSBORDA não pode
// encolher a zero — seu mínimo é o conteúdo. Era exatamente o main.app do
// bandcamp (h=0 enquanto o footer absorvia todo o encolhimento).
@(test)
m121_flex_item_nao_colapsa_a_zero :: proc(t: ^testing.T) {
    root := layout_from_html(`<body>
        <div style="height:200px;display:flex;flex-direction:column">
          <div id="a" style="flex:1"><div style="height:500px"></div></div>
          <div id="b" style="height:300px"></div>
        </div></body>`, 800, 600)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h >= 500, "item flex:1 mantém o mínimo de conteúdo (500), tem %.1f", a.h)
}

// A regra §4.5 só vale com overflow VISÍVEL no eixo principal: com overflow:hidden
// o item PODE encolher abaixo do conteúdo (mínimo automático não se aplica).
@(test)
m121_overflow_hidden_desliga_o_minimo_automatico :: proc(t: ^testing.T) {
    root := layout_from_html(`<body>
        <div style="height:200px;display:flex;flex-direction:column">
          <div id="a" style="flex:1;overflow:hidden"><div style="height:500px"></div></div>
          <div id="b" style="height:300px"></div>
        </div></body>`, 800, 600)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h < 500, "com overflow:hidden o item encolhe abaixo do conteúdo, tem %.1f", a.h)
}

// Não-regressão do caminho de CRESCIMENTO: quando o conteúdo CABE, `flex:1` ainda
// cresce p/ preencher o container (o mínimo automático não pode travá-lo no conteúdo).
@(test)
m121_flex_grow_ainda_preenche :: proc(t: ^testing.T) {
    root := layout_from_html(`<body>
        <div style="height:600px;display:flex;flex-direction:column">
          <div id="a" style="flex:1"><div style="height:100px"></div></div>
        </div></body>`, 800, 700)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 600, "flex:1 cresce p/ preencher os 600px do container, tem %.1f", a.h)
}
