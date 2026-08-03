package ui

// M124 — fecha a série calc()/%: padding, margin, gap e flex-basis.
// Estados encontrados (além do calc, havia bug de % PURA em quase todos):
//   - padding/margin: `parse_box4` fazia `ok && !pct` → porcentagem DESCARTADA.
//     `padding-top:56.25%` (truque clássico de caixa com proporção fixa) não fazia nada.
//   - gap/row-gap/column-gap: `parse_len(...)` com `_` → `gap:5%` virava 0.05 PIXEL.
//   - flex-basis: tinha % só no eixo ROW; na COLUNA `bases[i] = child.flex_basis`
//     ignorava a fração, então `flex-basis:50%` virava 0.5 PIXEL.
// Bases (spec): padding/margin → LARGURA do bloco contenedor nos 4 lados; gap →
// tamanho de conteúdo do container no eixo; flex-basis → eixo principal.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

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

// padding: % resolve contra a LARGURA do contenedor (600) → 60 por lado.
@(test)
m124_padding_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px"><div id="a" style="padding:10%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 120, "padding:10%% de 600 = 60+60 de altura, tem %.1f", a.h)
}

// O truque de proporção fixa: padding-top em % usa a LARGURA (não a altura).
@(test)
m124_padding_top_pct_usa_largura :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px"><div id="a" style="padding-top:50%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 300, "padding-top:50%% usa a LARGURA (600) = 300, tem %.1f", a.h)
}

// calc com % dentro de um shorthand: exige split que respeite parênteses
// (`strings.fields` quebrava `calc(10% - 20px)` em 3 tokens).
@(test)
m124_padding_calc_no_shorthand :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px"><div id="a" style="padding:calc(10% - 20px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 80, "padding:calc(10%%-20px) = 40 por lado → 80, tem %.1f", a.h)
}

@(test)
m124_margin_pct :: proc(t: ^testing.T) {
    root := lay(`<body style="margin:0"><div style="width:600px"><div id="a" style="margin-left:10%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.x == 60, "margin-left:10%% de 600 = 60, tem %.1f", a.x)
}

// gap em % no eixo inline: base = largura de conteúdo do container.
@(test)
m124_gap_pct :: proc(t: ^testing.T) {
    root := lay(`<body style="margin:0"><div style="display:flex;width:600px;gap:10%">
        <div style="flex:0 0 100px"></div><div id="a" style="flex:0 0 100px"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    // 1º item ocupa 100px a partir de x=0; gap = 10% de 600 = 60 → 2º começa em 160
    testing.expectf(t, a.x == 160, "gap:10%% de 600 = 60 → 2º item em x=160, tem %.1f", a.x)
}

// row-gap em % (eixo de bloco): base = altura DEFINIDA do container.
@(test)
m124_row_gap_pct :: proc(t: ^testing.T) {
    root := lay(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:600px;height:400px;row-gap:10%">
        <div style="flex:0 0 100px"></div><div id="a" style="flex:0 0 100px"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    // 1º item 100px + row-gap 10% de 400 = 40 → 2º começa 140 abaixo do topo do container
    testing.expectf(t, a.y == 140, "row-gap:10%% de 400 = 40 → 2º item em y=140, tem %.1f", a.y)
}

// flex-basis em % na COLUNA (era ignorado: virava 0.5px).
@(test)
m124_flex_basis_pct_na_coluna :: proc(t: ^testing.T) {
    root := lay(`<body><div style="display:flex;flex-direction:column;width:600px;height:400px">
        <div id="a" style="flex-grow:0;flex-shrink:0;flex-basis:50%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 200, "flex-basis:50%% de 400 = 200, tem %.1f", a.h)
}

@(test)
m124_flex_basis_calc_na_linha :: proc(t: ^testing.T) {
    root := lay(`<body><div style="display:flex;width:600px;height:400px">
        <div id="a" style="flex-grow:0;flex-shrink:0;flex-basis:calc(50% - 20px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.w == 280, "flex-basis calc(50%%-20px) de 600 = 280, tem %.1f", a.w)
}

// Não-regressão: valores em px puro seguem intactos nas quatro propriedades.
@(test)
m124_px_puro_intacto :: proc(t: ^testing.T) {
    root := lay(`<body style="margin:0"><div style="width:600px">
        <div id="a" style="padding:20px"></div>
        <div id="b" style="display:flex;gap:20px"><div style="flex:0 0 100px"></div><div id="c" style="flex:0 0 100px"></div></div>
        </div></body>`)
    a := find_id(root, "a"); c := find_id(root, "c")
    testing.expect(t, a != nil && c != nil, "achou #a e #c")
    if a == nil || c == nil do return
    testing.expectf(t, a.h == 40, "padding:20px → 40 de altura, tem %.1f", a.h)
    testing.expectf(t, c.x == 120, "gap:20px → 2º item em x=120, tem %.1f", c.x)
}
