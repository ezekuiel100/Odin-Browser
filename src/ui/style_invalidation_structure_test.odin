package ui

// Restyle incremental para mudança ESTRUTURAL, de TEXTO e com `+`/`~` na folha
// (antes os três caíam na cascata completa). Todo caso confere o mapa
// incremental contra uma cascata completa recomputada do zero, nó a nó.

import "core:strings"
import "core:testing"
import dom "../dom"
import html "../html"

@(private="file")
expect_matches_full :: proc(t: ^testing.T, tab: ^Tab, vw: f32 = 400, vh: f32 = 300, loc := #caller_location) {
    ref, _ := compute_styles(tab.dom, &tab.rules, vw, vh, tab.kf[:])
    defer { free_styles(ref); svg_css_bind(tab.styles) }
    testing.expectf(t, len(tab.styles) == len(ref), "mapa incremental com %d entradas, cascata completa com %d", len(tab.styles), len(ref), loc = loc)
    for n, r in ref {
        g, ok := tab.styles[n]
        if !testing.expectf(t, ok, "nó <%s> sem estilo no mapa incremental", n.tag, loc = loc) do continue
        rr := r
        p := deep_diff(&g, &rr, type_info_of(Computed), "")
        testing.expectf(t, p == "", "nó <%s id=%q> diverge da cascata completa no campo %s", n.tag, n.attrs["id"] if n.kind == .Element else "", p, loc = loc)
    }
}

@(private="file")
el :: proc(doc: ^dom.Node, id: string) -> ^dom.Node {
    walk :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
        if n.kind == .Element {
            if v, ok := n.attrs["id"]; ok && v == id do return n
        }
        for c in n.children do if r := walk(c, id); r != nil do return r
        return nil
    }
    return walk(doc, id)
}

// O DOM é DONO das strings (free_tree/set_attr as liberam): tudo clonado.
@(private="file")
new_el :: proc(tag, id: string) -> ^dom.Node {
    n := dom.make_node(.Element)
    n.tag = strings.clone(tag)
    dom.set_attr(n, strings.clone("id"), strings.clone(id))
    return n
}

@(private="file")
sa :: proc(n: ^dom.Node, k, v: string) { dom.set_attr(n, strings.clone(k), strings.clone(v)) }

@(private="file")
set_text :: proc(n: ^dom.Node, s: string) {
    if n.text != "" do delete(n.text)
    n.text = strings.clone(s)
}

@(private="file")
insert_first :: proc(parent, child: ^dom.Node) {
    child.parent = parent
    dom.kids_insert(parent, 0, child)
}

@(private="file")
remove_kid :: proc(parent, child: ^dom.Node) {
    for c, i in parent.children do if c == child { dom.kids_remove_at(parent, i); break }
}

// Inserir no INÍCIO da lista: `:first-child` muda de dono e o novo nó herda do pai.
@(test)
incremental_structure_insert_nth :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><ul id="u" style="color:#00ff00"><li id="a"></li><li id="b"></li></ul><section id="far"><p>longe</p></section></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `li:first-child{width:7px} li:nth-child(2){height:5px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    ul := el(doc, "u")
    x := new_el("li", "x")
    insert_first(ul, x)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles)) // a <section> ficou de fora
    testing.expect(t, tab.restyle_layout)
    testing.expect_value(t, tab.styles[x].width, f32(7))
    testing.expect(t, !tab.styles[el(doc, "a")].has_width)
    testing.expect_value(t, tab.styles[el(doc, "a")].height, f32(5))
    testing.expect_value(t, tab.styles[x].color, u32(0x00ff00))
    expect_matches_full(t, &tab)
}

// Remover: a entrada do nó morto sai do mapa (e é liberada).
@(test)
incremental_structure_remove_prunes :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><div id="d"><span id="s1"><b>x</b></span><span id="s2"></span></div><p>fica</p></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `span{width:3px} span:last-child{height:9px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    before := len(tab.styles)
    s2 := el(doc, "s2")
    remove_kid(el(doc, "d"), s2)
    dom.free_tree(s2)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, len(tab.styles), before - 1)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    testing.expect_value(t, tab.styles[el(doc, "s1")].height, f32(9)) // virou o último
    expect_matches_full(t, &tab)
}

// `+`/`~` na folha: a mudança de classe chega aos irmãos SEGUINTES.
@(test)
incremental_sibling_combinator :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><main><div id="a"></div><section id="b"><i id="c"></i></section><aside id="d"></aside></main><footer id="f"><b>longe</b></footer></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `.on + section{color:#ff0000} .on ~ aside{width:4px} .on + section i{height:2px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    sa(el(doc, "a"), "class", "on")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles)) // o <footer> ficou de fora
    testing.expect_value(t, tab.styles[el(doc, "b")].color, u32(0xff0000))
    testing.expect_value(t, tab.styles[el(doc, "d")].width, f32(4))
    testing.expect_value(t, tab.styles[el(doc, "c")].height, f32(2))
    expect_matches_full(t, &tab)
    sa(el(doc, "a"), "class", "")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, !tab.styles[el(doc, "d")].has_width)
    expect_matches_full(t, &tab)
}

// Texto: estilo igual, mas as caixas têm de ser refeitas. Com `:empty`, o
// texto novo vira o match do PAI (e, com `+`, do irmão do pai).
@(test)
incremental_text_and_empty :: proc(t: ^testing.T) {
    // com `:empty` + `+` a região de uma mudança de texto é o AVÔ do texto:
    // o <main> limita essa região, e o <footer> tem de ficar de fora
    doc := html.parse(`<html><body><main><div id="e"></div><p id="n"></p><div id="t">a</div></main><footer><b>longe</b></footer></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `div:empty{width:6px} div:empty + p{height:8px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[el(doc, "e")].width, f32(6))
    testing.expect_value(t, tab.styles[el(doc, "n")].height, f32(8))
    // texto num nó que já existia: só relayout
    set_text(el(doc, "t").children[0], "outro texto")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    expect_matches_full(t, &tab)
    // texto NOVO dentro do vazio: `:empty` deixa de casar no pai e no irmão
    txt := dom.make_node(.Text)
    set_text(txt, "cheio")
    dom.append_child(el(doc, "e"), txt)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, !tab.styles[el(doc, "e")].has_width)
    testing.expect(t, !tab.styles[el(doc, "n")].has_height)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    expect_matches_full(t, &tab)
}

// dir=auto: a direção vem do TEXTO, então mudar texto lá dentro vira a
// direção da subárvore inteira — inclusive de quem não foi tocado.
@(test)
incremental_dir_auto_text :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><div id="r" dir="auto"><p id="p">abc</p><span id="s"></span></div></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `span{width:1px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[el(doc, "s")].direction, Directionality.Ltr)
    set_text(el(doc, "p").children[0], "אבג") // hebraico: forte RTL
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[el(doc, "s")].direction, Directionality.Rtl)
    expect_matches_full(t, &tab)
}

// :has() e counters continuam na cascata completa (o alcance deles não cabe
// numa subárvore) — e o resultado continua certo.
@(test)
incremental_has_and_counters_stay_full :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><div id="d"></div><ol id="o"><li id="l1"></li></ol></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom = doc, css_text = `body:has(.x){width:300px} ol{counter-reset:k} li::before{content:counter(k)}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    dom.append_child(el(doc, "o"), new_el("li", "l2"))
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    expect_matches_full(t, &tab)
    sa(el(doc, "d"), "class", "x")
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    body := dom.find_first(doc, "body")
    testing.expect_value(t, tab.styles[body].width, f32(300))
    expect_matches_full(t, &tab)
}
