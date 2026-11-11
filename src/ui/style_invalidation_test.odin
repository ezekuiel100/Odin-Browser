package ui

import "core:testing"
import "core:strings"
import "core:fmt"
import "core:time"
import dom "../dom"
import html "../html"
import css "../css"

@(test)
incremental_style_class_variable_and_layout :: proc(t: ^testing.T) {
    doc := html.parse("<html><body><div id='target'><span>text</span></div><section id='clean'><b>keep</b></section></body></html>")
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text="div{--tone:red} div span{color:var(--tone)} .on{--tone:blue;background-color:red} .wide{width:200px}"}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    n := dom.find_first(doc, "div")
    clean := dom.find_first(doc, "section")
    span := dom.find_first(doc, "span")
    untouched := tab.styles[clean]
    dom.set_attr(n, "class", "on")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_nodes < len(tab.styles))
    testing.expect_value(t, tab.styles[span].color, u32(0x0000ff))
    testing.expect_value(t, tab.styles[clean].style_fp, untouched.style_fp)
    testing.expect(t, tab.restyle_layout) // text color currently needs new runs
    dom.set_attr(n, "class", "wide")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout)
    testing.expect_value(t, tab.styles[n].width, f32(200))
}

@(test)
incremental_style_paint_and_noop_preserve_boxes :: proc(t: ^testing.T) {
    doc := html.parse("<html><body><div>hello</div><section>keep</section></body></html>")
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=".on{background-color:red;opacity:0.5}"}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    layout := tab.layout
    n := dom.find_first(doc, "div")
    dom.set_attr(n, "class", "on")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, !tab.restyle_layout)
    testing.expect_value(t, tab.layout, layout)
    index := make(map[^dom.Node]^Box, context.temp_allocator)
    test_style_box_index(tab.layout, &index)
    testing.expect_value(t, index[n].bg, u32(0xff0000))
    testing.expect_value(t, index[n].opacity, f32(0.5))
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, 0)
    testing.expect_value(t, tab.layout, layout)
    // Direct attribute map writes are also detected, including CSS variables.
    n.attrs[strings.clone("style")] = strings.clone("--alpha:0.25;opacity:var(--alpha);background-color:blue")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, !tab.restyle_layout)
    clear(&index)
    test_style_box_index(tab.layout, &index)
    testing.expect_value(t, index[n].opacity, f32(0.25))
    testing.expect_value(t, index[n].bg, u32(0x0000ff))
}

@(test)
incremental_style_relational_and_structure_fallback :: proc(t: ^testing.T) {
    doc := html.parse("<html><body><div></div><section>keep</section></body></html>")
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text=".on + section{color:red} body:has(.on){background-color:blue}"}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    n := dom.find_first(doc, "div")
    dom.set_attr(n, "class", "on")
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    testing.expect_value(t, tab.styles[dom.find_first(doc, "section")].color, u32(0xff0000))
    testing.expect_value(t, tab.page_bg, u32(0x0000ff))
    dom.append_child(n, dom.make_node(.Text))
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    restyle_tab(&tab, 500, 300)
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    tab_drop_rules(&tab)
    tab.css_text = "@container (min-width:100px){div{color:red}}"
    restyle_tab(&tab, 500, 300)
    restyle_tab(&tab, 500, 300) // measurements can change without DOM edits
    testing.expect_value(t, tab.restyle_nodes, len(tab.styles))
    testing.expect(t, tab.restyle_layout)
}

// Includes ordinary boxes, unlike the animation-only restore index.
test_style_box_index :: proc(b: ^Box, index: ^map[^dom.Node]^Box) {
    if b == nil do return
    if b.node != nil do index[b.node] = b
    for c in b.children do test_style_box_index(c, index)
    for it in b.inlines do if it.box != nil do test_style_box_index(it.box, index)
}

@(test)
incremental_style_attribute_inline_and_owned_subtrees :: proc(t: ^testing.T) {
    doc := html.parse("<html><body><div data-state='off'></div><section><span>inline</span></section></body></html>")
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text="[data-state=on]{width:120px} section{transform:translateX(2px)} section::before{content:'keep'} .paint{background-color:red}"}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    n := dom.find_first(doc, "div")
    section := dom.find_first(doc, "section")
    pseudo := tab.styles[section].before
    xform := tab.styles[section].xform
    for i in 0..<8 {
        dom.set_attr(n, "data-state", i % 2 == 0 ? "on" : "off")
        restyle_tab(&tab, 400, 300)
        testing.expect(t, tab.restyle_nodes < len(tab.styles))
        testing.expect_value(t, tab.styles[section].before, pseudo)
        testing.expect_value(t, tab.styles[section].before.content, "keep")
        testing.expect_value(t, tab.styles[section].xform, xform)
        testing.expect_value(t, tab.styles[n].has_width, i % 2 == 0)
    }
    dom.set_attr(dom.find_first(doc, "span"), "class", "paint")
    restyle_tab(&tab, 400, 300)
    testing.expect(t, tab.restyle_layout) // background lives in an inline run
}

// Opt-in synthetic benchmark; timings are observations, never pass/fail limits.
// odin test src/ui -o:speed -define:ODIN_TEST_THREADS=1
//   -define:ODIN_TEST_NAMES=incremental_style_benchmark -define:BENCH_RESTYLE=true
@(test)
incremental_style_benchmark :: proc(t: ^testing.T) {
    when !#config(BENCH_RESTYLE, false) { return }
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, "<html><body>")
    for i in 0..<1000 do strings.write_string(&sb, "<div><section></section></div>")
    strings.write_string(&sb, "</body></html>")
    doc := html.parse(strings.to_string(sb))
    defer dom.free_tree(doc)
    tab := Tab{dom=doc, css_text="div{height:10px} .on{background-color:red;opacity:0.5}"}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab, 400, 300)
    n := dom.find_first(doc, "div")
    elapsed: [2]f64
    nodes: [2]int
    for mode in 0..<2 {
        start := time.tick_now()
        for i in 0..<20 {
            dom.set_attr(n, "class", i % 2 == 0 ? "on" : "")
            if mode == 0 do tab.style_vw = 0 // force the original full path
            restyle_tab(&tab, 400, 300)
        }
        elapsed[mode] = time.duration_milliseconds(time.tick_since(start)) / 20
        nodes[mode] = tab.restyle_nodes
    }
    fmt.printf("Restyle %d DOM nodes: full %.3f ms (%d cascades); incremental %.3f ms (%d cascades); %.2fx\n",
        len(tab.styles), elapsed[0], nodes[0], elapsed[1], nodes[1], elapsed[0]/elapsed[1])
    testing.expect(t, nodes[1] < nodes[0])
}
