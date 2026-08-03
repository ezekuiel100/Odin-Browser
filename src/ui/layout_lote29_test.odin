package ui

// Lote 29 — `content-visibility` + `contain-intrinsic-size` (13 sites no
// gap-miner). O `hidden` é questão de CORREÇÃO, não de performance: sem ele
// mostrávamos conteúdo que o autor mandou esconder (painéis de aba, acordeões).

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay :: proc(html: string) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 800)
    page := Rect{0, 0, 800, 600}
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
por_classe :: proc(b: ^Box, cls: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if c, ok := b.node.attrs["class"]; ok && c == cls do return b
    }
    for c in b.children {
        if r := por_classe(c, cls); r != nil do return r
    }
    return nil
}

@(test)
test_content_visibility_hidden :: proc(t: ^testing.T) {
    // o conteúdo não é construído...
    r := lay(`<body style="margin:0"><div class="x" style="content-visibility:hidden"><div>a</div><div>b</div></div></body>`)
    d := por_classe(r, "x")
    testing.expect(t, d != nil, "a caixa deveria EXISTIR (≠ display:none)")
    if d == nil do return
    testing.expectf(t, len(d.children) == 0 && len(d.inlines) == 0,
        "conteúdo não deveria ser construído, veio %d filhos / %d inlines", len(d.children), len(d.inlines))

    // ...e sem contain-intrinsic-size a caixa fica sem altura
    testing.expectf(t, d.h == 0, "sem reserva a altura deveria ser 0, veio %v", d.h)

    // controle: SEM a prop o mesmo HTML constrói o conteúdo (senão o teste não prova nada)
    r2 := lay(`<body style="margin:0"><div class="x"><div>a</div><div>b</div></div></body>`)
    d2 := por_classe(r2, "x")
    testing.expect(t, d2 != nil && len(d2.children) == 2, "controle: sem a prop, os 2 filhos existem")
    testing.expect(t, d2 != nil && d2.h > 0, "controle: sem a prop, a caixa tem altura")
}

@(test)
test_contain_intrinsic_size :: proc(t: ^testing.T) {
    // a reserva evita o colapso p/ 0 (é o motivo de a prop existir)
    r := lay(`<body style="margin:0"><div class="x" style="content-visibility:hidden;contain-intrinsic-size:300px 120px"><div>a</div></div></body>`)
    d := por_classe(r, "x")
    testing.expect(t, d != nil, "caixa deveria existir")
    if d == nil do return
    testing.expectf(t, d.h == 120, "altura de reserva esperada 120, veio %v", d.h)
    testing.expectf(t, d.w == 300, "largura de reserva esperada 300, veio %v", d.w)

    // width/height do AUTOR vencem a reserva
    r2 := lay(`<body style="margin:0"><div class="x" style="content-visibility:hidden;contain-intrinsic-size:300px 120px;height:50px"><div>a</div></div></body>`)
    d2 := por_classe(r2, "x")
    testing.expectf(t, d2 != nil && d2.h == 50, "height do autor deveria vencer a reserva, veio %v", d2 != nil ? d2.h : -1)

    // um valor só = os DOIS eixos
    r3 := lay(`<body style="margin:0"><div class="x" style="content-visibility:hidden;contain-intrinsic-size:80px"><div>a</div></div></body>`)
    d3 := por_classe(r3, "x")
    testing.expectf(t, d3 != nil && d3.h == 80 && d3.w == 80,
        "1 valor deveria valer p/ os dois eixos, veio %v x %v", d3 != nil ? d3.w : -1, d3 != nil ? d3.h : -1)
}
