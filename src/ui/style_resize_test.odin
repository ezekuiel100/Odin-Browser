package ui

// `resize` (css-ui §5.2) — a alça de redimensionamento pelo usuário.
// Era o MAIOR gap real do gap-report por nº de sites (10 sites / 72 ocorrências),
// e o uso dominante em site real é `resize:none`/`resize:vertical` em <textarea>
// — o que só significa alguma coisa se o <textarea> for redimensionável POR
// PADRÃO (é o default de todas as UAs). Por isso o UA style entra aqui também.
//
// O que É testável por unidade: o parsing, a APLICABILIDADE (a prop não vale em
// elemento com overflow:visible) e o efeito do tamanho arrastado sobre o layout.
// O ARRASTE em si (mouse) só existe no app — mesma situação do scroll-behavior
// (lote 9) e do scroll-margin (lote 11). Fixture manual: tests/manual/resize.html.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
box_de :: proc(html: string, tag: string, vw: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, 600}
    layout_absolutes(root, page, page)
    return find_tag(root, tag)
}

// ⚠️ um <textarea> é display:inline-block, e átomo inline NÃO mora em
// `children`: vira Inline_Item{kind=.InlineBox} com a caixa pendurada em `box`.
// Procurar só nos filhos devolvia nil (foi o 1º vermelho deste arquivo).
@(private = "file")
find_tag :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := find_tag(c, tag); r != nil do return r
    }
    for it in b.inlines {
        if it.kind != .InlineBox do continue
        if r := find_tag(it.box, tag); r != nil do return r
    }
    return nil
}

@(test)
test_prop_resize_parse :: proc(t: ^testing.T) {
    testing.expect(t, css_prop_is_known("resize"), "`resize` precisa ser prop conhecida")

    c := test_compute_one("div{resize:both}")
    testing.expectf(t, c.resize == .Both, "resize:both, veio %v", c.resize)
    c = test_compute_one("div{resize:horizontal}")
    testing.expectf(t, c.resize == .Horizontal, "resize:horizontal, veio %v", c.resize)
    c = test_compute_one("div{resize:vertical}")
    testing.expectf(t, c.resize == .Vertical, "resize:vertical, veio %v", c.resize)
    // grafias LÓGICAS (horizontal-tb): inline = eixo horizontal, block = vertical
    c = test_compute_one("div{resize:inline}")
    testing.expectf(t, c.resize == .Horizontal, "resize:inline ≡ horizontal, veio %v", c.resize)
    c = test_compute_one("div{resize:block}")
    testing.expectf(t, c.resize == .Vertical, "resize:block ≡ vertical, veio %v", c.resize)
    c = test_compute_one("div{resize:none}")
    testing.expectf(t, c.resize == .None, "resize:none, veio %v", c.resize)
    // valor desconhecido não pode virar "redimensionável" por acidente
    c = test_compute_one("div{resize:xyz}")
    testing.expectf(t, c.resize == .None, "valor inválido tem de cair em None, veio %v", c.resize)
    // não HERDA (é o default da spec; herdar poria alça em todo descendente)
    c2 := test_compute_one("")
    testing.expectf(t, c2.resize == .None, "sem declaração, resize é None, veio %v", c2.resize)
}

@(test)
test_prop_resize_aplicabilidade :: proc(t: ^testing.T) {
    // A spec só aplica `resize` a quem estabelece contexto de rolagem. Sem esta
    // guarda uma <div> comum ganharia alça — que é o que nenhum navegador faz.
    b := box_de(`<div style="resize:both;width:200px;height:100px">x</div>`, "div")
    testing.expect(t, b != nil, "não achei a div")
    if b == nil do return
    testing.expectf(t, b.resize == .None, "overflow:visible ⇒ sem alça, veio %v", b.resize)

    b2 := box_de(`<div style="resize:both;overflow:auto;width:200px;height:100px">x</div>`, "div")
    testing.expect(t, b2 != nil, "não achei a div com overflow")
    if b2 == nil do return
    testing.expectf(t, b2.resize == .Both, "overflow:auto ⇒ alça, veio %v", b2.resize)

    b3 := box_de(`<div style="resize:both;overflow:hidden;width:200px;height:100px">x</div>`, "div")
    if b3 != nil {
        testing.expectf(t, b3.resize == .Both, "overflow:hidden também aplica, veio %v", b3.resize)
    }
}

@(test)
test_prop_resize_textarea :: proc(t: ^testing.T) {
    // <textarea> é redimensionável por padrão (UA). É o que dá sentido ao
    // `resize:none` que os sites escrevem.
    b := box_de(`<textarea></textarea>`, "textarea")
    testing.expect(t, b != nil, "não achei o textarea")
    if b == nil do return
    testing.expectf(t, b.resize == .Both, "textarea sem CSS é resizable (UA), veio %v", b.resize)

    // ... e a declaração do AUTOR vence a UA nas duas direções
    b2 := box_de(`<textarea style="resize:none"></textarea>`, "textarea")
    testing.expect(t, b2 != nil, "não achei o textarea (none)")
    if b2 == nil do return
    testing.expectf(t, b2.resize == .None, "resize:none do autor vence a UA, veio %v", b2.resize)

    b3 := box_de(`<textarea style="resize:vertical"></textarea>`, "textarea")
    testing.expect(t, b3 != nil, "não achei o textarea (vertical)")
    if b3 == nil do return
    testing.expectf(t, b3.resize == .Vertical, "resize:vertical do autor, veio %v", b3.resize)
}

@(test)
test_resize_tamanho_arrastado :: proc(t: ^testing.T) {
    // O tamanho arrastado entra pelos MESMOS campos que `width`/`height` do autor.
    // Testado pela função pura (resize_apply_size), não pelo mapa global g_resize:
    // o mapa é escrito só no paint (arraste do mouse), e teste que escreve em
    // global de pacote corre com o runner de 16 threads.
    b := box_de(`<body style="margin:0"><div style="resize:both;overflow:auto;width:200px;height:100px">x</div></body>`, "div")
    testing.expect(t, b != nil, "não achei a div")
    if b == nil do return
    testing.expectf(t, b.w == 200 && b.h == 100, "tamanho inicial 200x100, veio %vx%v", b.w, b.h)

    resize_apply_size(b, {w = 320, h = 150, has_w = true, has_h = true})
    layout_box(b, b.x, b.y, 600)
    testing.expectf(t, b.w == 320, "largura arrastada deveria valer 320, veio %v", b.w)
    testing.expectf(t, b.h == 150, "altura arrastada deveria valer 150, veio %v", b.h)
}

@(test)
test_resize_respeita_max_width :: proc(t: ^testing.T) {
    // Consequência de entrar pelos campos do autor: min/max continuam mandando,
    // sem uma linha de código a mais. (Chrome faz o mesmo: a alça para no max.)
    b := box_de(`<body style="margin:0"><div style="resize:both;overflow:auto;width:200px;max-width:250px;height:100px">x</div></body>`, "div")
    testing.expect(t, b != nil, "não achei a div")
    if b == nil do return

    resize_apply_size(b, {w = 400, has_w = true})
    layout_box(b, b.x, b.y, 600)
    testing.expectf(t, b.w == 250, "max-width:250 tem de segurar o arraste de 400, veio %v", b.w)
    // eixo NÃO arrastado fica intacto (resize:horizontal não pode congelar a altura)
    testing.expectf(t, b.h == 100, "altura não arrastada deveria seguir 100, veio %v", b.h)
}
