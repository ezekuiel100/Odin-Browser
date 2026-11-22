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

// The test runner rolls back each test's allocator. Global map headers must
// not retain buckets allocated by a previous test after that rollback.
@(private="file")
Container_Test_Inputs :: struct {
    widths, used: map[^dom.Node]f32,
    dirty: bool,
}

@(private="file")
container_test_inputs_begin :: proc() -> Container_Test_Inputs {
    saved := Container_Test_Inputs{g_container_w, g_container_used, g_container_dirty}
    g_container_w = nil
    g_container_used = nil
    g_container_dirty = false
    return saved
}

@(private="file")
container_test_inputs_end :: proc(saved: Container_Test_Inputs) {
    delete(g_container_w)
    delete(g_container_used)
    g_container_w, g_container_used, g_container_dirty = saved.widths, saved.used, saved.dirty
}

@(test)
container_invalidation_tracks_measured_inputs :: proc(t: ^testing.T) {
    saved_inputs := container_test_inputs_begin()
    defer container_test_inputs_end(saved_inputs)
    doc := html.parse(`<html><body><main id="c"><div id="target">text</div></main><section id="clean"><span>keep</span></section></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`main{container-type:inline-size;width:200px} div{width:20px} .paint{background:red;opacity:.5} @container(min-width:250px){div{width:80px}}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    c, target := el(doc, "c"), el(doc, "target")
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[target].width, f32(80)) // initial viewport fallback
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, 0)
    container_w_record(c, 200)
    g_container_dirty = false // the UI consumes this flag before restyling
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    testing.expect_value(t, tab.styles[target].width, f32(20))
    expect_matches_full(t, &tab)
    root := tab.layout
    sa(target, "class", "paint")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    testing.expect(t, !tab.restyle_layout)
    testing.expect_value(t, tab.layout, root)
    expect_matches_full(t, &tab)
    // First measurement, subsequent threshold crossings and removal of the
    // measurement must all invalidate without any DOM mutation.
    container_w_record(c, 300)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    testing.expect_value(t, tab.styles[target].width, f32(80))
    expect_matches_full(t, &tab)
    container_w_clear()
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    expect_matches_full(t, &tab)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, 0)
    // Another document's measurements do not belong to this tab's snapshot.
    other_doc := dom.make_node(.Element)
    defer dom.free_tree(other_doc)
    container_w_record(other_doc, 42)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, 0)
    // Viewport/font/zoom invalidations retain the full path.
    tab.zoom_applied = -1
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
}

@(test)
container_invalidation_named_and_structural_changes :: proc(t: ^testing.T) {
    saved_inputs := container_test_inputs_begin()
    defer container_test_inputs_end(saved_inputs)
    doc := html.parse(`<html><body><main id="outer"><section id="inner"><div id="target">text</div></section></main><aside>clean</aside></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`main{container-type:inline-size;container-name:outer} section{container-type:inline-size;container-name:inner} .rename{container-name:outer} .off{container-type:normal} div{width:10px;height:10px} @container outer (min-width:300px){div{width:80px}} @container inner (min-width:150px){div{height:50px}}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    outer, inner, target := el(doc, "outer"), el(doc, "inner"), el(doc, "target")
    container_w_record(outer, 400)
    container_w_record(inner, 100)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[target].width, f32(80))
    testing.expect_value(t, tab.styles[target].height, f32(10))
    sa(inner, "class", "rename")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    testing.expect_value(t, tab.styles[target].width, f32(10))
    expect_matches_full(t, &tab)
    sa(inner, "class", "off")
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[target].width, f32(80))
    expect_matches_full(t, &tab)
    set_text(target.children[0], "new text")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout && tab.restyle_nodes < len(tab.styles))
    expect_matches_full(t, &tab)
    added := new_el("div", "added")
    dom.append_child(inner, added)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout && tab.restyle_nodes < len(tab.styles))
    testing.expect_value(t, tab.styles[added].width, f32(80))
    expect_matches_full(t, &tab)
    remove_kid(inner, added)
    restyle_tab(&tab, 400, 300)
    dom.free_tree(added)
    expect_matches_full(t, &tab)
}

@(test)
container_invalidation_after_sibling_layout_change :: proc(t: ^testing.T) {
    saved_inputs := container_test_inputs_begin()
    defer container_test_inputs_end(saved_inputs)
    doc := html.parse(`<html><body><main><aside id="side"></aside><section id="c"><div id="target"></div></section></main><footer>keep</footer></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`main{display:flex;width:400px} aside{width:100px;flex-shrink:0} section{flex:1;container-type:inline-size} .wide{width:300px} div{width:10px} @container(min-width:200px){div{width:80px}}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    ensure_tab_geometry(tab.layout, 400, 300)
    restyle_tab(&tab, 400, 300)
    ensure_tab_geometry(tab.layout, 400, 300)
    c, target := el(doc, "c"), el(doc, "target")
    testing.expect_value(t, g_container_w[c], f32(300))
    testing.expect_value(t, tab.styles[target].width, f32(80))
    sa(el(doc, "side"), "class", "wide")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    ensure_tab_geometry(tab.layout, 400, 300)
    testing.expect_value(t, g_container_w[c], f32(100))
    // The container's own branch had no mutation; the measurement pass must
    // still force a full cascade and update its descendants.
    g_container_dirty = false
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    testing.expect_value(t, tab.styles[target].width, f32(10))
    expect_matches_full(t, &tab)
}

@(private="file")
expect_relational_geometry_full :: proc(t: ^testing.T, tab: ^Tab) {
    ref, _ := compute_styles(tab.dom, &tab.rules, 400, 300, tab.kf[:])
    layout := build_layout(tab.dom, ref, tab.url)
    defer { free_layout(layout); free_styles(ref); svg_css_bind(tab.styles) }
    ensure_tab_geometry(tab.layout, 400, 300)
    ensure_tab_geometry(layout, 400, 300)
    a := make(map[^dom.Node]^Box, context.temp_allocator)
    b := make(map[^dom.Node]^Box, context.temp_allocator)
    test_style_box_index(tab.layout, &a)
    test_style_box_index(layout, &b)
    testing.expect_value(t, len(a), len(b))
    for n, box in a {
        r, found := b[n]
        if !testing.expect(t, found) do continue
        testing.expect_value(t, box.x, r.x)
        testing.expect_value(t, box.y, r.y)
        testing.expect_value(t, box.w, r.w)
        testing.expect_value(t, box.h, r.h)
    }
}

@(test)
relational_invalidation_descendant_groups_and_inheritance :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><article id="card" class="card"><div id="trigger"><i></i></div><span id="label">text</span><b class="ready"></b></article><section id="far"><span>keep</span></section></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`.card{width:60px;--tone:red} .card:has(.on,.alt):has(.ready){width:180px;--tone:blue} .card:not(:has(.on,.alt)){opacity:.75} .card span{color:var(--tone)} section::before{content:'owned'}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    stable := tab.styles[el(doc, "far")].before
    cls_cases := [?]string{"on", "alt", "", "on", ""}
    for cls in cls_cases {
        sa(el(doc, "trigger"), "class", cls)
        restyle_tab(&tab, 400, 300)
        testing.expect(t, tab.restyle_nodes < len(tab.styles))
        testing.expect_value(t, tab.styles[el(doc, "far")].before, stable)
        testing.expect_value(t, tab.styles[el(doc, "card")].width, cls == "" ? f32(60) : f32(180))
        testing.expect_value(t, tab.styles[el(doc, "card")].opacity, cls == "" ? f32(.75) : f32(1))
        testing.expect_value(t, tab.styles[el(doc, "label")].color, cls == "" ? u32(0xff0000) : u32(0x0000ff))
        expect_matches_full(t, &tab)
        expect_relational_geometry_full(t, &tab)
    }
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, 0)
}

@(test)
relational_invalidation_reaches_siblings_and_nested_functions :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><aside id="anchor" class="anchor"><span id="inside"></span></aside><div class="panel" id="panel"><i class="label" id="label"></i></div><section id="trigger" class="trigger"><b id="flag"></b></section><footer id="far">keep</footer></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`.anchor:has(+ .panel .on){width:31px} .anchor:has(~ .trigger .on){--tone:blue} .anchor span{color:var(--tone,red)} :is(.anchor:has(.on),.unused) + .panel{width:101px} .panel:not(:has(.on)){height:42px} .panel .label{width:12px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    id_cases := [?]string{"label", "flag", "inside"}
    for id in id_cases {
        cls_cases := [?]string{"on", ""}
        for cls in cls_cases {
            sa(el(doc, id), "class", id == "label" ? (cls == "" ? "label" : "label on") : cls)
            restyle_tab(&tab, 400, 300)
            testing.expect(t, tab.restyle_nodes < len(tab.styles))
            expect_matches_full(t, &tab)
            expect_relational_geometry_full(t, &tab)
        }
    }
}

@(test)
relational_invalidation_structure_text_moves_and_freed_subjects :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><main><article id="left" class="card"><i id="moving" class="on">x</i></article><article id="right" class="card"><b id="empty"></b></article></main><aside id="far"><span>keep</span></aside></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`.card:has(>.on){width:80px} .card:not(:has(>.on)){width:20px} .card:has(:empty){height:31px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    left, right, moving := el(doc, "left"), el(doc, "right"), el(doc, "moving")
    text := dom.make_node(.Text)
    text.text = strings.clone("filled")
    dom.append_child(el(doc, "empty"), text)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    expect_matches_full(t, &tab)
    set_text(text, " ")
    restyle_tab(&tab, 400, 300)
    expect_matches_full(t, &tab)
    remove_kid(left, moving)
    dom.append_child(right, moving)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    testing.expect_value(t, tab.styles[left].width, f32(20))
    testing.expect_value(t, tab.styles[right].width, f32(80))
    expect_matches_full(t, &tab)
    expect_relational_geometry_full(t, &tab)
    // Free a matched subject before planning. Its cached pointer is a key only.
    remove_kid(right.parent, right)
    dom.free_tree(right)
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    expect_matches_full(t, &tab)
}

@(test)
relational_invalidation_nth_filter_and_sheet_replacement :: proc(t: ^testing.T) {
    doc := html.parse(`<html><body><ul><li id="a"><i id="flag"></i></li><li id="b"><b class="on"></b></li><li id="c"><em class="on"></em></li></ul><aside>keep</aside></body></html>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=`li:nth-child(2 of :has(.on)){width:77px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    cls_cases := [?]string{"on", ""}
    for cls in cls_cases {
        sa(el(doc, "flag"), "class", cls)
        restyle_tab(&tab, 400, 300)
        testing.expect(t, tab.restyle_nodes < len(tab.styles))
        expect_matches_full(t, &tab)
    }
    tab_drop_rules(&tab)
    testing.expect(t, !tab.relational_ready && tab.relational_matches == nil && len(tab.relational_selectors) == 0)
    tab.css_text = `li:has(.on){height:20px}`
    restyle_tab(&tab, 400, 300)
    expect_matches_full(t, &tab)
    // A tab transferred from a worker has no membership snapshot yet.
    tab.relational_ready = false
    sa(el(doc, "flag"), "class", "on")
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    expect_matches_full(t, &tab)
}
