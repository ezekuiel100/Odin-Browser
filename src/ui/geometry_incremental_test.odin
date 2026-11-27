package ui

import "core:testing"
import "core:strings"
import "core:fmt"
import "core:time"
import dom "../dom"
import html "../html"

@(private="file")
gi_compare :: proc(t: ^testing.T, a, b: ^Box) {
    if !testing.expect(t,(a == nil) == (b == nil)) || a == nil do return
    testing.expect_value(t,a.node,b.node)
    testing.expect_value(t,[4]f32{a.x,a.y,a.w,a.h},[4]f32{b.x,b.y,b.w,b.h})
    testing.expect_value(t,[3]f32{a.content_x,a.content_y,a.content_w},[3]f32{b.content_x,b.content_y,b.content_w})
    testing.expect_value(t,[3]f32{a.scroll_max,a.scroll_max_x,a.sticky_max_dy},[3]f32{b.scroll_max,b.scroll_max_x,b.sticky_max_dy})
    testing.expect_value(t,a.has_static,b.has_static)
    testing.expect_value(t,[4]f32{a.static_x,a.static_y,a.static_cw,a.static_ch},[4]f32{b.static_x,b.static_y,b.static_cw,b.static_ch})
    testing.expect_value(t,[2]f32{a.img_dw,a.img_dh},[2]f32{b.img_dw,b.img_dh})
    if testing.expect_value(t,len(a.children),len(b.children)) {
        for child,i in a.children do gi_compare(t,child,b.children[i])
    }
    if testing.expect_value(t,len(a.inlines),len(b.inlines)) {
        for it,i in a.inlines {
            ref := b.inlines[i]
            testing.expect_value(t,it.kind,ref.kind)
            testing.expect_value(t,it.text,ref.text)
            testing.expect_value(t,[4]f32{it.x,it.y,it.w,it.h},[4]f32{ref.x,ref.y,ref.w,ref.h})
            gi_compare(t,it.box,ref.box)
        }
    }
}

@(private="file")
gi_full :: proc(t: ^testing.T, tab: ^Tab, w: f32 = 400, h: f32 = 300) {
    // Independent tree: never transfers cached boxes or uses a geometry hit.
    styles, _ := compute_styles(tab.dom,&tab.rules,w,h,tab.kf[:])
    root := build_layout(tab.dom,styles,tab.url)
    defer { free_layout(root); free_styles(styles); svg_css_bind(tab.styles) }
    ensure_tab_geometry(root,w,h)
    gi_compare(t,tab.layout,root)
}

@(test)
geometry_incremental_skips_clean_siblings :: proc(t: ^testing.T) {
    markup := strings.builder_make(context.temp_allocator)
    strings.write_string(&markup,`<body style="margin:0"><div id="target"></div>`)
    for _ in 0 ..< 300 do strings.write_string(&markup,`<section><div><div style="height:10px"></div></div></section>`)
    strings.write_string(&markup,`</body>`)
    doc := html.parse(strings.to_string(markup))
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}.on{height:30px!important}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300)
    ensure_tab_geometry(tab.layout,400,300)
    full_calls := g_layout_calls
    classes := [?]string{"on","","on",""}
    for cls in classes {
        dom.set_attr(dom.find_first(doc,"div"),strings.clone("class"),strings.clone(cls))
        restyle_tab(&tab,400,300)
        ensure_tab_geometry(tab.layout,400,300)
        testing.expectf(t,g_layout_calls < full_calls/2,"incremental layout visited %v boxes; full layout visited %v",g_layout_calls,full_calls)
        testing.expect(t,tab.layout.geometry_stats.hits >= 300)
        testing.expect(t,tab.layout.geometry_stats.reflowed < 10)
        gi_full(t,&tab)
    }
}

@(test)
geometry_incremental_translates_clean_flex_grid_and_inline :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><div id="target"></div><main id="clean"><div style="display:flex;width:200px;height:40px"><div style="flex:1;height:20px"></div><div style="flex:1"></div></div><div style="display:grid;grid-template-columns:60px 1fr;height:30px"><div></div><div></div></div><p>one <b style="display:inline-block;width:20px;height:10px">two</b> three</p></main></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}.on{height:50px!important}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300)
    ensure_tab_geometry(tab.layout,400,300)
    classes := [?]string{"on","","on"}
    for cls in classes {
        dom.set_attr(dom.find_first(doc,"div"),strings.clone("class"),strings.clone(cls))
        restyle_tab(&tab,400,300)
        ensure_tab_geometry(tab.layout,400,300)
        testing.expectf(t,g_layout_calls < 10,"clean subtree reflowed: %v layout calls",g_layout_calls)
        gi_full(t,&tab)
    }
}

@(test)
geometry_incremental_width_changes_reflow_descendants :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><main style="display:flex;width:300px"><aside id="target" style="flex:none"></aside><section id="clean" style="flex:1;min-width:0"><div style="width:50%;height:20px"></div><div style="display:grid;grid-template-columns:1fr 2fr;height:30px"><div></div><div></div></div></section></main><footer><div style="height:20px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{width:50px}#target.on{width:170px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300)
    ensure_tab_geometry(tab.layout,400,300)
    classes := [?]string{"on","","on",""}
    for cls in classes {
        dom.set_attr(dom.find_first(doc,"aside"),strings.clone("class"),strings.clone(cls))
        restyle_tab(&tab,400,300)
        ensure_tab_geometry(tab.layout,400,300)
        gi_full(t,&tab)
    }
}

@(private="file")
gi_node :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
    if n.attrs["id"] == id do return n
    for c in n.children do if found := gi_node(c,id); found != nil do return found
    return nil
}

@(private="file")
gi_box :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs["id"] == id do return b
    for c in b.children do if found := gi_box(c,id); found != nil do return found
    for it in b.inlines do if found := gi_box(it.box,id); found != nil do return found
    return nil
}

@(private="file")
gi_attr :: proc(n: ^dom.Node, key, value: string) {
    dom.set_attr(n,strings.clone(key),strings.clone(value))
}

@(test)
geometry_incremental_noop_and_paint_do_not_reflow :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><div id="target" style="height:20px"></div><section><div style="height:30px"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`.on{background-color:red;opacity:.5;cursor:pointer}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    original := tab.layout
    gi_attr(gi_node(doc,"target"),"class","on")
    restyle_tab(&tab,400,300)
    testing.expect_value(t,tab.layout,original)
    testing.expect(t,!ensure_tab_geometry(tab.layout,400,300))
    testing.expect_value(t,tab.layout.geometry_stats.requests,0)
    restyle_tab(&tab,400,300)
    testing.expect(t,!ensure_tab_geometry(tab.layout,400,300))
    gi_full(t,&tab)
}

@(test)
geometry_incremental_environment_and_resources_require_full_pass :: proc(t: ^testing.T) {
    saved := g_geometry_resources
    defer { g_geometry_resources = saved }
    doc := html.parse(`<body style="margin:0"><div id="target"></div><section><div style="height:30px;width:50%"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:20px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on")
    restyle_tab(&tab,400,300)
    g_geometry_resources += 1
    ensure_tab_geometry(tab.layout,400,300)
    testing.expect_value(t,tab.layout.geometry_stats.hits,0)
    gi_full(t,&tab)
    gi_attr(gi_node(doc,"target"),"class","")
    restyle_tab(&tab,400,300)
    ensure_tab_geometry(tab.layout,500,350)
    testing.expect_value(t,tab.layout.geometry_stats.hits,0)
    gi_full(t,&tab,500,350)
}

@(test)
geometry_incremental_coalesced_mutations_before_flush :: proc(t: ^testing.T) {
    doc := html.parse(`<body><div id="target"></div><section><div style="height:30px"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:20px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on"); restyle_tab(&tab,400,300)
    gi_attr(gi_node(doc,"target"),"class",""); restyle_tab(&tab,400,300)
    ensure_tab_geometry(tab.layout,400,300)
    testing.expect_value(t,tab.layout.geometry_stats.hits,0)
    gi_full(t,&tab)
}

@(test)
geometry_incremental_structure_text_move_and_removal :: proc(t: ^testing.T) {
    doc := html.parse(`<body><main id="list"><div id="text">first text</div></main><article id="destination"></article><section><div style="height:20px"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`main,article{width:180px} div{height:10px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    text := gi_node(doc,"text").children[0]
    delete(text.text); text.text = strings.clone("changed text with more words")
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300); gi_full(t,&tab)
    inserted := dom.make_node(.Element); inserted.tag = strings.clone("div")
    gi_attr(inserted,"style","height:35px")
    list := gi_node(doc,"list")
    inserted.parent = list; dom.kids_insert(list,0,inserted)
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300); gi_full(t,&tab)
    dom.kids_remove_at(list,0)
    destination := gi_node(doc,"destination")
    inserted.parent = destination; dom.kids_append(destination,inserted)
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300); gi_full(t,&tab)
    dom.kids_remove_at(destination,0); dom.free_tree(inserted)
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300); gi_full(t,&tab)
}

@(test)
geometry_incremental_absolute_fixed_and_hoisting :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><div id="target"></div><main style="position:relative;width:200px;height:80px"><div><div style="position:absolute;right:10%;bottom:5px;width:40px;height:20px"></div><div style="position:fixed;right:0;bottom:0;width:30px;height:10px"></div></div></main><footer><div style="height:30px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:50px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    classes := [?]string{"on","","on"}
    for cls in classes {
        gi_attr(gi_node(doc,"target"),"class",cls)
        restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
        testing.expect(t,tab.layout.geometry_stats.hits > 0)
        gi_full(t,&tab)
    }
}

@(test)
geometry_incremental_scroll_sticky_and_animation_state :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><div id="target"></div><section id="scroll" style="height:30px;overflow:auto"><div style="height:100px"><div style="position:sticky;top:0;height:10px"></div></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:50px}section{animation:fade 2s infinite}@keyframes fade{from{opacity:0}to{opacity:1}}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    box := gi_box(tab.layout,"scroll")
    box.scroll_y = 12; box.animations[0].elapsed = .7
    gi_attr(gi_node(doc,"target"),"class","on")
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    testing.expect_value(t,gi_box(tab.layout,"scroll"),box)
    testing.expect_value(t,box.scroll_y,f32(12))
    testing.expect_value(t,box.animations[0].elapsed,f32(.7))
    testing.expect(t,tab.layout.geometry_stats.hits > 0)
    gi_full(t,&tab)
}

@(test)
geometry_incremental_parent_height_and_percentage_limits :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><main id="target"><section style="display:grid;grid-template-rows:1fr 2fr;min-height:50%"><div></div><div></div></section><article style="height:50%;max-height:80%"><div style="height:100%"></div></article></main><footer><div style="height:20px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`main{display:flex;height:80px}main.on{height:140px}section,article{width:100px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    classes := [?]string{"on","","on"}
    for cls in classes {
        gi_attr(gi_node(doc,"target"),"class",cls)
        restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
        gi_full(t,&tab)
    }
}

@(test)
geometry_incremental_intrinsic_measurement_invalidates_memo :: proc(t: ^testing.T) {
    doc := html.parse(`<body><div id="target"></div><section id="clean">text with inline fragments <b style="display:inline-block;width:20px;height:10px">atom</b></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:20px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on"); restyle_tab(&tab,400,300)
    clean := gi_box(tab.layout,"clean")
    testing.expect(t,clean.geometry_memo.valid)
    restore_text_fragments(clean)
    testing.expect(t,!clean.geometry_memo.valid)
    ensure_tab_geometry(tab.layout,400,300)
    testing.expect(t,clean.geometry_memo.valid)
    gi_full(t,&tab)
}

@(test)
geometry_incremental_complex_formatting_falls_back :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><div id="target"></div><table style="width:200px;border-collapse:collapse"><tr><td style="border:2px solid;width:50px"><div style="height:20px"></div></td><td><div style="height:30px"></div></td></tr></table><main style="display:grid;grid-template-columns:60px 100px"><section style="display:grid;grid-column:span 2;grid-template-columns:subgrid"><div style="height:10px"></div><div style="height:20px"></div></section></main><article style="writing-mode:vertical-rl;height:80px"><div style="width:20px;height:30px"></div></article><footer><div style="height:10px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:30px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on")
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    testing.expect(t,tab.layout.geometry_stats.hits > 0)
    gi_full(t,&tab)
}

@(test)
geometry_incremental_manual_resize_disables_hits :: proc(t: ^testing.T) {
    saved := g_resize; g_resize = make(map[^dom.Node]Resize_Size)
    defer { delete(g_resize); g_resize = saved }
    doc := html.parse(`<body><div id="target"></div><section id="resized" style="resize:both;overflow:auto;width:100px;height:30px"><div style="height:20px"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:30px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on"); restyle_tab(&tab,400,300)
    g_resize[gi_node(doc,"resized")] = {w=140,h=40,has_w=true,has_h=true}
    ensure_tab_geometry(tab.layout,400,300)
    testing.expect_value(t,tab.layout.geometry_stats.hits,0)
    testing.expect_value(t,gi_box(tab.layout,"resized").w,f32(140))
    gi_full(t,&tab)
}

@(test)
geometry_incremental_cssom_read_flushes_once :: proc(t: ^testing.T) {
    js_scroll_set(0,0)
    doc := html.parse(`<body style="margin:0"><div id="target"></div><section id="clean"><div style="height:20px"></div></section></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:40px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_free() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    gi_attr(gi_node(doc,"target"),"class","on"); restyle_tab(&tab,400,300)
    _, y, _, h, ok := js_element_rect(gi_node(doc,"clean"))
    testing.expect(t,ok); testing.expect_value(t,y,f32(40)); testing.expect_value(t,h,f32(20))
    testing.expect(t,tab.layout.geometry_stats.hits > 0)
    testing.expect(t,!ensure_tab_geometry(tab.layout,400,300))
    gi_full(t,&tab)
}

@(test)
geometry_incremental_query_containers_keep_measuring :: proc(t: ^testing.T) {
    saved_w,saved_h,saved_used,saved_h_used,saved_dirty := g_container_w,g_container_h,g_container_used,g_container_h_used,g_container_dirty
    g_container_w=nil; g_container_h=nil; g_container_used=nil; g_container_h_used=nil; g_container_dirty=false
    defer {
        delete(g_container_w); delete(g_container_h); delete(g_container_used); delete(g_container_h_used)
        g_container_w,g_container_h,g_container_used,g_container_h_used,g_container_dirty = saved_w,saved_h,saved_used,saved_h_used,saved_dirty
    }
    doc := html.parse(`<body style="margin:0"><div id="target"></div><section id="query" style="container-type:inline-size;width:200px"><div id="item"></div></section><footer><div style="height:10px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:10px}#target.on{height:30px}#item{height:10px}@container(min-width:100px){#item{height:40px}}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    for _ in 0 ..< 3 { g_container_dirty=false; restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300) }
    gi_attr(gi_node(doc,"target"),"class","on")
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    testing.expect(t,!gi_box(tab.layout,"query").geometry_memo.safe)
    testing.expect_value(t,gi_box(tab.layout,"item").h,f32(40))
    testing.expect_value(t,g_container_w[gi_node(doc,"query")],f32(200))
    gi_full(t,&tab)
}

BENCH_GEOMETRY :: #config(BENCH_GEOMETRY, false)
@(test)
geometry_incremental_fractional_repositioning_is_exact :: proc(t: ^testing.T) {
    markups := [?]string{
        `<body style="margin:0"><aside id="target"></aside><section style="padding:.1px"><div style="padding:.3px;height:10.2px"><div style="height:1.1px"></div></div></section></body>`,
        `<body style="margin:0"><main style="display:flex;width:400px"><aside id="target" style="flex:none"></aside><section style="flex:none;width:100px;height:20px;min-width:0"><div style="padding:.1px;height:1.2px"></div></section></main></body>`,
    }
    sheets := [?]string{`#target{height:10.1px}#target.on{height:20.2px}`,`#target{width:40.1px}#target.on{width:60.2px}`}
    for markup,i in markups {
        doc := html.parse(markup)
        tab := Tab{dom=doc,css_text=sheets[i]}
        restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
        for step in 0 ..< 4 {
            gi_attr(gi_node(doc,"target"),"class",step%2 == 0 ? "on" : "")
            restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
            gi_full(t,&tab)
        }
        free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear(); dom.free_tree(doc)
    }
}

@(test)
geometry_incremental_retained_grid_percentage_limits :: proc(t: ^testing.T) {
    doc := html.parse(`<body style="margin:0"><main style="display:flex;flex-direction:column;height:400px"><aside id="target" style="flex:none"></aside><section style="display:grid;flex:1;min-height:0;grid-template-rows:1fr 1fr"><div style="min-height:50%"><div style="height:10px"></div></div><div></div></section></main><footer><div style="height:20px"></div></footer></body>`)
    defer dom.free_tree(doc)
    tab := Tab{dom=doc,css_text=`#target{height:0}#target.on{height:360px}`}
    defer { free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear() }
    restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
    classes := [?]string{"on","","on"}
    for cls in classes {
        gi_attr(gi_node(doc,"target"),"class",cls)
        restyle_tab(&tab,400,300); ensure_tab_geometry(tab.layout,400,300)
        gi_full(t,&tab)
    }
}

@(test)
geometry_incremental_benchmark :: proc(t: ^testing.T) {
    when BENCH_GEOMETRY {
        markup := strings.builder_make(context.temp_allocator)
        strings.write_string(&markup,`<body style="margin:0"><div id="target"></div>`)
        for _ in 0 ..< 700 do strings.write_string(&markup,`<section><div style="display:grid;grid-template-columns:1fr 2fr;height:20px"><div></div><div></div></div></section>`)
        strings.write_string(&markup,`</body>`)
        for moving in 0 ..< 2 {
            for fast in 0 ..< 2 {
                doc := html.parse(strings.to_string(markup))
                tab := Tab{dom=doc,css_text=moving == 1 ? `#target{height:10px}#target.on{height:40px}` : `#target{width:80px;height:10px}#target.on{width:120px}`}
                restyle_tab(&tab,800,600); ensure_tab_geometry(tab.layout,800,600)
                elapsed: f64; reflowed,hits: int
                for i in 0 ..< 22 {
                    gi_attr(gi_node(doc,"target"),"class",i%2 == 0 ? "on" : "")
                    restyle_tab(&tab,800,600)
                    if fast == 0 do tab.layout.geometry_incremental = false
                    start := time.tick_now()
                    ensure_tab_geometry(tab.layout,800,600)
                    elapsed += time.duration_milliseconds(time.tick_since(start))
                    reflowed += tab.layout.geometry_stats.reflowed
                    hits += tab.layout.geometry_stats.hits
                }
                gi_full(t,&tab,800,600)
                fmt.eprintfln("[geometry-bench] moving=%d incremental=%d passes=22 ms=%.3f reflowed=%d hits=%d",moving,fast,elapsed,reflowed,hits)
                free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab); js_style_source_clear(); dom.free_tree(doc)
            }
        }
    }
}
