package ui

// M125 — último da família de comprimentos: inset (top/right/bottom/left).
// A porcentagem PURA já funcionava aqui (inset_pct existia); faltava o offset do
// calc — `top:calc(50% - 10px)` caía no parse_len antigo, que devolve pct=false com
// o valor já corrompido (a fração somada como px), e virava um deslocamento errado.
// Base (spec): ALTURA do bloco contenedor p/ top/bottom, LARGURA p/ left/right.

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

@(private = "file")
CB :: `<body style="margin:0"><div style="position:relative;width:600px;height:400px">`

// % pura: left usa a LARGURA (600), top usa a ALTURA (400) — eixos diferentes.
@(test)
m125_inset_pct_usa_eixos_certos :: proc(t: ^testing.T) {
    root := lay(CB + `<div id="a" style="position:absolute;width:50px;height:50px;left:10%;top:25%"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.x == 60,  "left:10%% da LARGURA (600) = 60, tem %.1f", a.x)
    testing.expectf(t, a.y == 100, "top:25%% da ALTURA (400) = 100, tem %.1f", a.y)
}

// calc com % nos dois eixos.
@(test)
m125_inset_calc_pct :: proc(t: ^testing.T) {
    root := lay(CB + `<div id="a" style="position:absolute;width:50px;height:50px;left:calc(10% - 20px);top:calc(25% + 10px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.x == 40,  "left:calc(10%%-20px) = 60-20 = 40, tem %.1f", a.x)
    testing.expectf(t, a.y == 110, "top:calc(25%%+10px) = 100+10 = 110, tem %.1f", a.y)
}

// Shorthand `inset` com calc: só parseia certo com split que respeite parênteses
// (há ESPAÇOS dentro do calc; strings.fields quebraria em tokens soltos).
@(test)
m125_inset_shorthand_com_calc :: proc(t: ^testing.T) {
    root := lay(CB + `<div id="a" style="position:absolute;width:50px;height:50px;inset:calc(10% - 5px) 0 0 calc(50% - 25px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.x == 275, "inset left calc(50%%-25px) = 300-25 = 275, tem %.1f", a.x)
    testing.expectf(t, a.y == 35,  "inset top calc(10%%-5px) = 40-5 = 35, tem %.1f", a.y)
}

// A ESTICADA entre lados opostos (o caso do bandcamp/osm) com calc dos dois lados.
@(test)
m125_inset_estica_com_calc :: proc(t: ^testing.T) {
    root := lay(CB + `<div id="a" style="position:absolute;top:calc(10% - 10px);bottom:calc(10% - 10px)"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    // top = bottom = 40-10 = 30 → altura = 400 - 30 - 30 = 340
    testing.expectf(t, a.y == 30,  "top calc(10%%-10px) = 30, tem %.1f", a.y)
    testing.expectf(t, a.h == 340, "altura = 400-30-30 = 340, tem %.1f", a.h)
}

// Não-regressão: px puro segue intacto.
@(test)
m125_inset_px_puro_intacto :: proc(t: ^testing.T) {
    root := lay(CB + `<div id="a" style="position:absolute;width:50px;height:50px;left:30px;top:40px"></div></div></body>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "achou #a")
    if a == nil do return
    testing.expectf(t, a.x == 30, "left:30px intacto, tem %.1f", a.x)
    testing.expectf(t, a.y == 40, "top:40px intacto, tem %.1f", a.y)
}
