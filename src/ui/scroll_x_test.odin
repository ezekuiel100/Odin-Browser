package ui

import "core:fmt"
import "core:testing"
import htmlp  "../html"
import csspkg "../css"

// Rolagem HORIZONTAL: o eixo X de container rolável (`scroll_max_x`), o Y que
// passou a respeitar `overflow-y` próprio, e a extensão X da PÁGINA com o
// bloqueio por `overflow-x:hidden` propagado de html/body. Todo caso tem um
// controle que muda UMA coisa.

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

@(test)
scroll_x_container_auto_mede_o_transbordo :: proc(t: ^testing.T) {
    root := lay(`<html><body><div id="s" style="width:200px;height:100px;overflow-x:auto">` +
        `<div style="width:500px;height:20px"></div></div></body></html>`)
    s := find_box_by_id(root, "s")
    testing.expect(t, s != nil)
    if s == nil do return
    testing.expect(t, s.ovf_scroll_x)
    testing.expectf(t, abs(s.scroll_max_x - 300) < 1, "500 de conteúdo em 200 visíveis: esperava 300, veio %.1f", s.scroll_max_x)
}

@(test)
scroll_x_hidden_clipa_mas_nao_rola :: proc(t: ^testing.T) {
    // controle do anterior: só troca auto → hidden
    root := lay(`<html><body><div id="s" style="width:200px;height:100px;overflow-x:hidden">` +
        `<div style="width:500px;height:20px"></div></div></body></html>`)
    s := find_box_by_id(root, "s")
    testing.expect(t, s != nil)
    if s == nil do return
    testing.expect(t, s.ovf_clip_x && !s.ovf_scroll_x)
    testing.expect_value(t, s.scroll_max_x, 0)
}

@(test)
scroll_x_linha_nowrap_transborda :: proc(t: ^testing.T) {
    // 5 átomos de 60px numa caixa de 100 com nowrap: a linha mede 300 (+ espaços
    // de 0 no teste, que não tem atlas de fonte ⇒ texto mede 0; por isso átomos)
    atomos :: `<span style="display:inline-block;width:60px;height:10px"></span>` +
        `<span style="display:inline-block;width:60px;height:10px"></span>` +
        `<span style="display:inline-block;width:60px;height:10px"></span>` +
        `<span style="display:inline-block;width:60px;height:10px"></span>` +
        `<span style="display:inline-block;width:60px;height:10px"></span>`
    root := lay(`<html><body><div id="s" style="width:100px;overflow-x:auto;white-space:nowrap">` + atomos + `</div></body></html>`)
    defer free_layout(root)
    s := find_box_by_id(root, "s")
    testing.expect(t, s != nil)
    if s == nil do return
    testing.expectf(t, abs(s.scroll_max_x - 200) < 1, "linha nowrap de 300 em 100: esperava 200, veio %.1f", s.scroll_max_x)
    // controle: os MESMOS átomos quebrando linha cabem na largura
    root2 := lay(`<html><body><div id="s" style="width:100px;overflow-x:auto">` + atomos + `</div></body></html>`)
    defer free_layout(root2)
    s2 := find_box_by_id(root2, "s")
    testing.expect(t, s2 != nil)
    if s2 == nil do return
    testing.expect_value(t, s2.scroll_max_x, 0)
}

@(test)
scroll_y_respeita_o_proprio_eixo :: proc(t: ^testing.T) {
    // `overflow: auto hidden` (carrossel): o Y clipa e NÃO rola pela roda
    alto :: `<div style="height:300px"></div>`
    root := lay(`<html><body><div id="s" style="height:50px;overflow-x:auto;overflow-y:hidden">` + alto + `</div></body></html>`)
    s := find_box_by_id(root, "s")
    testing.expect(t, s != nil)
    if s == nil do return
    testing.expect_value(t, s.scroll_max, 0)
    // controle: overflow-y:auto rola os 250 que sobram
    root2 := lay(`<html><body><div id="s" style="height:50px;overflow-x:auto;overflow-y:auto">` + alto + `</div></body></html>`)
    s2 := find_box_by_id(root2, "s")
    testing.expect(t, s2 != nil)
    if s2 == nil do return
    testing.expectf(t, abs(s2.scroll_max - 250) < 1, "esperava 250, veio %.1f", s2.scroll_max)
}

@(test)
scroll_x_pagina_extensao_e_bloqueio :: proc(t: ^testing.T) {
    largo :: `<div style="width:2000px;height:10px"></div>`
    root := lay(`<html><body style="margin:0">` + largo + `</body></html>`)
    testing.expectf(t, abs(box_scroll_extent_x(root) - 2000) < 1, "extensão X: %.1f", box_scroll_extent_x(root))
    testing.expect(t, !page_x_blocked(root), "sem overflow-x:hidden a página rola no X")

    // body{overflow-x:hidden} propaga ao viewport ⇒ eixo bloqueado
    rb := lay(`<html><body style="margin:0;overflow-x:hidden">` + largo + `</body></html>`)
    testing.expect(t, page_x_blocked(rb), "body overflow-x:hidden bloqueia")
    // idem no html
    rh := lay(`<html style="overflow-x:hidden"><body style="margin:0">` + largo + `</body></html>`)
    testing.expect(t, page_x_blocked(rh), "html overflow-x:hidden bloqueia")
    // e overflow-x:auto no body NÃO bloqueia (rola)
    ra := lay(`<html><body style="margin:0;overflow-x:auto">` + largo + `</body></html>`)
    testing.expect(t, !page_x_blocked(ra), "body overflow-x:auto não bloqueia")
}

@(test)
scroll_x_pagina_poda_conteudo_clipado_e_fixed :: proc(t: ^testing.T) {
    // o largo DENTRO de uma caixa que corta o X não conta; nem um fixed largo
    root := lay(`<html><body style="margin:0">` +
        `<div style="width:300px;overflow-x:hidden"><div style="width:2000px;height:10px"></div></div>` +
        `<div style="position:fixed;top:0;left:0;width:3000px;height:10px"></div>` +
        `</body></html>`)
    testing.expectf(t, box_scroll_extent_x(root) <= 800.5, "esperava ≤ 800 (a largura da página), veio %.1f", box_scroll_extent_x(root))
    // controle: a mesma caixa sem cortar o X deixa os 2000 aparecerem
    root2 := lay(`<html><body style="margin:0">` +
        `<div style="width:300px"><div style="width:2000px;height:10px"></div></div>` +
        `</body></html>`)
    testing.expectf(t, abs(box_scroll_extent_x(root2) - 2000) < 1, "controle: %.1f", box_scroll_extent_x(root2))
}

@(test)
scroll_y_pagina_poda_conteudo_clipado :: proc(t: ^testing.T) {
    // O espaço em branco no fim da página: o alto DENTRO de uma caixa que corta o
    // Y (menu `max-height:0;overflow:hidden`, rolável interno `overflow:auto`)
    // estendia a rolagem da página até onde o conteúdo ESCONDIDO terminaria.
    for ovf in ([]string{"hidden", "auto", "clip"}) {
        root := lay(fmt.tprintf(`<html><body style="margin:0">` +
            `<div style="height:100px;overflow-y:%s"><div style="height:5000px"></div></div>` +
            `</body></html>`, ovf))
        defer free_layout(root)
        e := box_scroll_extent(root)
        testing.expectf(t, e <= 100.5, "overflow-y:%s: esperava ≤ 100, veio %.1f", ovf, e)
    }
    // controle: a mesma caixa SEM cortar o Y deixa os 5000 transbordarem (visible
    // gera área rolável na página, como no Chrome)
    root2 := lay(`<html><body style="margin:0">` +
        `<div style="height:100px"><div style="height:5000px"></div></div>` +
        `</body></html>`)
    defer free_layout(root2)
    testing.expectf(t, abs(box_scroll_extent(root2) - 5000) < 1, "controle: %.1f", box_scroll_extent(root2))
    // `overflow-x:hidden` sozinho: o Y declarado visible não sobrevive
    root3 := lay(`<html><body style="margin:0">` +
        `<div style="height:100px;overflow-x:hidden;overflow-y:visible"><div style="height:5000px"></div></div>` +
        `</body></html>`)
    defer free_layout(root3)
    e3 := box_scroll_extent(root3)
    // overflow-x:hidden + y:visible computa y=auto (css-overflow §3) ⇒ também clipa
    testing.expectf(t, e3 <= 100.5, "x:hidden força y:auto: esperava ≤ 100, veio %.1f", e3)
}

@(test)
scroll_sobrevive_ao_rebuild_do_layout :: proc(t: ^testing.T) {
    // o restyle constrói uma árvore NOVA a partir do MESMO DOM: o scroll da caixa
    // velha tem de passar p/ a nova (casado pelo nó)
    dom := htmlp.parse(`<html><body><div id="s" style="width:200px;height:100px;overflow:auto">` +
        `<div style="width:500px;height:400px"></div></div></body></html>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    old := build_layout(dom, styles, "")
    layout_box(old, 0, 0, 800)
    defer free_layout(old)
    so := find_box_by_id(old, "s")
    testing.expect(t, so != nil)
    if so == nil do return
    so.scroll_x, so.scroll_y = 120, 80

    novo := build_layout(dom, styles, "")
    defer free_layout(novo)
    scroll_restore_tree(novo, old)
    layout_box(novo, 0, 0, 800) // reclampa: 120 ≤ 300 e 80 ≤ 300, ficam
    sn := find_box_by_id(novo, "s")
    testing.expect(t, sn != nil)
    if sn == nil do return
    testing.expect_value(t, sn.scroll_x, 120)
    testing.expect_value(t, sn.scroll_y, 80)

    // controle: a mesma reconstrução SEM o restore nasce no 0 (era o bug)
    cru := build_layout(dom, styles, "")
    defer free_layout(cru)
    layout_box(cru, 0, 0, 800)
    sc := find_box_by_id(cru, "s")
    testing.expect(t, sc != nil && sc.scroll_x == 0 && sc.scroll_y == 0)
}
