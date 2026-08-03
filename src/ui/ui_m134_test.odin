package ui

// M134 — `minmax(<%>, …)` no grid ignorava o mínimo PERCENTUAL.
//
// `parse_grid_track` fazia `if px, _, k := parse_len(mn, …); k do tr.min_px = px`
// — descartando o "é porcentagem?". Para `minmax(45%, max-content)` isso guardava
// `min_px = 0.45` (meio pixel de piso) e a trilha colapsava no max-content.
//
// Importa porque `repeat(auto-fit, minmax(<%|px>, …))` é O idioma de grid
// responsivo: o mínimo alimenta TAMBÉM a contagem de trilhas do auto-fit.

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

@(private = "file")
BODY :: `<body style="margin:0"><div style="width:600px">`

@(test)
m134_minmax_com_minimo_percentual :: proc(t: ^testing.T) {
    // 45% de 600 = 270. Antes: 26px (só o max-content).
    root := lay(BODY + `<div style="display:grid;grid-template-columns:minmax(45%,max-content)">
        <div id="x">UM</div></div></div></body>`)
    x := find_id(root, "x")
    testing.expect(t, x != nil, "achou o item")
    if x == nil do return
    testing.expectf(t, x.w == 270, "minmax(45%%,…) dá piso de 270px (w=%.0f)", x.w)
}

@(test)
m134_auto_fit_conta_trilhas_pelo_minimo_percentual :: proc(t: ^testing.T) {
    // min 45% de 600 = 270; cabem 2 trilhas (270+16+270 = 556 <= 600).
    root := lay(BODY + `<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(45%,max-content));column-gap:16px">
        <div id="a">UM</div><div id="b">DOIS</div></div></div></body>`)
    a, b := find_id(root, "a"), find_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou os itens")
    if a == nil || b == nil do return
    testing.expectf(t, a.w == 270, "1ª trilha 270 (w=%.0f)", a.w)
    testing.expectf(t, b.w == 270, "2ª trilha 270 (w=%.0f)", b.w)
    testing.expectf(t, b.x > a.x, "ficaram em COLUNAS diferentes (a.x=%.0f b.x=%.0f)", a.x, b.x)
}

@(test)
m134_minimo_em_px_continua_valendo :: proc(t: ^testing.T) {
    // Não-regressão: o piso absoluto já funcionava e não pode ter mudado.
    root := lay(BODY + `<div style="display:grid;grid-template-columns:minmax(200px,max-content)">
        <div id="x">UM</div></div></div></body>`)
    x := find_id(root, "x")
    testing.expect(t, x != nil, "achou o item")
    if x == nil do return
    testing.expectf(t, x.w == 200, "piso de 200px (w=%.0f)", x.w)
}

@(test)
m134_repeat_fixo_com_minmax_intacto :: proc(t: ^testing.T) {
    // Não-regressão: `repeat(2, minmax(100px,1fr))` já dividia 50/50.
    root := lay(BODY + `<div style="display:grid;grid-template-columns:repeat(2,minmax(100px,1fr))">
        <div id="a">UM</div><div id="b">DOIS</div></div></div></body>`)
    a, b := find_id(root, "a"), find_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou os itens")
    if a == nil || b == nil do return
    testing.expectf(t, a.w == 300 && b.w == 300, "50/50 (a=%.0f b=%.0f)", a.w, b.w)
}

@(test)
m134_auto_fill_com_minimo_em_px :: proc(t: ^testing.T) {
    // 600 / (200+10) → 2 trilhas (o 3º item desce de linha).
    root := lay(BODY + `<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px">
        <div id="a">UM</div><div id="b">DOIS</div><div id="c">TRES</div></div></div></body>`)
    a, b, c := find_id(root, "a"), find_id(root, "b"), find_id(root, "c")
    testing.expect(t, a != nil && b != nil && c != nil, "achou os itens")
    if a == nil || b == nil || c == nil do return
    testing.expectf(t, b.x > a.x, "b na 2ª coluna (a.x=%.0f b.x=%.0f)", a.x, b.x)
    testing.expectf(t, c.x == a.x, "c volta p/ a 1ª coluna (c.x=%.0f)", c.x)
}
