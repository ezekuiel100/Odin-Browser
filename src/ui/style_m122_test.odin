package ui

// M122 — PORCENTAGEM dentro de calc() valia ZERO.
// `eval_calc_expr` chamava parse_len e DESCARTAVA o flag de porcentagem, então
// `100%` virava 1 *pixel*: `calc(100% - 40px)` = 1-40 = -39 (→0) e
// `calc(50% + 10px)` = 0.5+10 ≈ 10. Como a base da % só existe no LAYOUT (é o
// bloco contenedor), o calc agora é avaliado na forma LINEAR `pct*base + px_off`
// e resolvido no layout. Era o BLANK do openstreetmap:
// `#map{height:calc(100% - 40px)}` colapsava a 0 (sobrava só a borda de 2px).

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

// O caso do openstreetmap: altura = 100% do pai menos um offset em px.
@(test)
m122_calc_pct_menos_px_na_altura :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:calc(100% - 40px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 360, "calc(100%% - 40px) de 400 = 360, tem %.1f", a.h)
}

@(test)
m122_calc_pct_menos_px_na_largura :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px">
        <div id="a" style="width:calc(100% - 40px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.w == 560, "calc(100%% - 40px) de 600 = 560, tem %.1f", a.w)
}

// Soma (não só subtração) e fração diferente de 100%.
@(test)
m122_calc_pct_mais_px :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:calc(50% + 10px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 210, "calc(50%% + 10px) de 400 = 210, tem %.1f", a.h)
}

// calc que resulta em porcentagem PURA (sem offset) — o `*`/`/` por escalar
// precisa escalar a fração, não virar px.
@(test)
m122_calc_pct_puro :: proc(t: ^testing.T) {
    root := lay(`<body><div style="width:600px">
        <div id="a" style="width:calc(100% / 2)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.w == 300, "calc(100%% / 2) de 600 = 300, tem %.1f", a.w)
}

// Duas porcentagens somam como frações (não viram px).
@(test)
m122_calc_pct_menos_pct :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:calc(100% - 10%)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.h == 360, "calc(100%% - 10%%) de 400 = 360, tem %.1f", a.h)
}

// Não-regressão: calc SEM porcentagem continua px puro, e % pura continua igual.
@(test)
m122_calc_sem_pct_e_pct_pura_intactos :: proc(t: ^testing.T) {
    root := lay(`<body><div style="height:400px">
        <div id="a" style="height:calc(100px + 20px)"></div>
        <div id="b" style="height:50%"></div></div></body>`)
    a := find_id(root, "a"); b := find_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou #a e #b")
    if a == nil || b == nil do return
    testing.expectf(t, a.h == 120, "calc(100px + 20px) = 120, tem %.1f", a.h)
    testing.expectf(t, b.h == 200, "50%% de 400 = 200, tem %.1f", b.h)
}
