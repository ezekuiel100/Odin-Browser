package ui

// M123 — estende o fix do M122 (porcentagem em calc()) a min/max-width e min/max-height.
// Estado anterior:
//   - min/max-WIDTH já aceitavam % pura, mas calc com % caía no caminho velho
//     (`max-width:calc(100% - 2rem)`, padrão MUITO comum, virava ~2px).
//   - min/max-HEIGHT DESCARTAVAM porcentagem por completo (`k && !pct`), então
//     `min-height:50%` simplesmente não fazia nada.
// Agora as quatro passam pela forma linear `pct*base + px_off`. Para as ALTURAS a
// base é a altura DEFINIDA do pai, que só o pai conhece → `resolve_child_minmax_h`
// converte a fração em px nos campos minh/maxh antes de dispor o filho (mesma
// estratégia já usada por height_pct).

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

// max-width: calc(100% - Npx) — o padrão comum que o M122 deixou pendente.
@(test)
m123_max_width_calc_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px">
        <div id="a" style="width:calc(100% - 40px);max-width:calc(100% - 100px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.w == 500, "max-width calc(100%%-100px) limita a 500, tem %.1f", a.w)
}

// min-width com calc: precisa AUMENTAR uma largura menor.
@(test)
m123_min_width_calc_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px">
        <div id="a" style="width:100px;min-width:calc(100% - 100px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.w == 500, "min-width calc(100%%-100px) sobe p/ 500, tem %.1f", a.w)
}

// min-height em % — funcionalidade NOVA (antes a % era descartada).
@(test)
m123_min_height_pct_puro :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:10px;min-height:50%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 200, "min-height:50%% de 400 = 200, tem %.1f", a.h)
}

@(test)
m123_min_height_calc_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:100px;min-height:calc(100% - 100px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 300, "min-height calc(100%%-100px) sobe p/ 300, tem %.1f", a.h)
}

@(test)
m123_max_height_calc_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:350px;max-height:calc(100% - 100px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 300, "max-height calc(100%%-100px) limita a 300, tem %.1f", a.h)
}

// Não-regressão: min/max em px puro seguem iguais, e a % NÃO resolve quando o pai
// não tem altura definida (spec: fica como se não houvesse mínimo).
@(test)
m123_px_puro_e_pai_sem_altura :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:10px;min-height:120px"></div></div>
        <div><div id="b" style="height:10px;min-height:50%"></div></div></body>`)
    a := find_id(root, "a"); b := find_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou #a e #b")
    if a == nil || b == nil do return
    testing.expectf(t, a.h == 120, "min-height:120px continua px puro, tem %.1f", a.h)
    testing.expectf(t, b.h == 10, "pai sem altura definida: %% não resolve, tem %.1f", b.h)
}
