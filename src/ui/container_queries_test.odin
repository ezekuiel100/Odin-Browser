package ui

import "core:testing"
import "core:strings"
import css "../css"
import dom "../dom"
import html "../html"

CQ_Test_Size :: struct { id: string, w, h: f32 }

cq_test_node :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
    if n.attrs["id"] == id do return n
    for c in n.children do if found := cq_test_node(c, id); found != nil do return found
    return nil
}

cq_test_compute :: proc(sheet: string, sizes: []CQ_Test_Size = nil, markup := `<section id="outer"><article id="inner"><div id="target"></div></article></section>`) -> Computed {
    old_w, old_used, old_dirty := g_container_w, g_container_used, g_container_dirty
    old_h, old_h_used := g_container_h, g_container_h_used
    g_container_h = nil; g_container_h_used = nil
    g_container_w = nil; g_container_used = nil; g_container_dirty = false
    defer {
        delete(g_container_w); delete(g_container_used)
        delete(g_container_h); delete(g_container_h_used)
        g_container_h, g_container_h_used = old_h, old_h_used
        g_container_w, g_container_used, g_container_dirty = old_w, old_used, old_dirty
    }
    root := html.parse(markup)
    defer dom.free_tree(root)
    rules, keys := css.parse(sheet)
    defer css.free_rules(&rules)
    defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules, 800, 600)
    free_styles(styles)
    for size in sizes do container_size_record(cq_test_node(root, size.id), size.w, size.h)
    styles, _ = compute_styles(root, &rules, 800, 600)
    defer free_styles(styles)
    return styles[cq_test_node(root, "target")]
}

@(test)
cq_requires_eligible_measured_ancestor :: proc(t: ^testing.T) {
    for base in ([]string{"", "section{container-type:inline-size}", "#target{container-type:inline-size}"}) {
        c := cq_test_compute(strings.concatenate({base, `#target{width:10px} @container (min-width:100px){#target{width:90px}}`}, context.temp_allocator))
        testing.expect_value(t, c.width, 10)
    }
    c := cq_test_compute(`section{container:actual / inline-size} #target{width:10px}
        @container missing (min-width:100px){#target{width:90px}}`, {{"outer",400,0}})
    testing.expect_value(t, c.width, 10)
}

@(test)
cq_boolean_conditions_and_unknown_features :: proc(t: ^testing.T) {
    for condition in ([]string{"not (width > 300px)", "(width < 100px) or (width = 200px)", "((width > 100px) and (width < 300px))"}) {
        c := cq_test_compute(strings.concatenate({`section{container-type:inline-size} #target{width:10px} @container `, condition, `{#target{width:90px}}`}, context.temp_allocator), {{"outer",200,0}})
        testing.expectf(t, c.width == 90, "condition %s -> %v", condition, c.width)
    }
    for condition in ([]string{"(future-size: 1)", "not (future-size:1)", "style(--theme:dark)", "(width > 0px) and garbage", "(width > 0px) or (width < 100px) and (width < 900px)"}) {
        c := cq_test_compute(strings.concatenate({`section{container-type:inline-size} #target{width:10px} @container `, condition, `{#target{width:90px}}`}, context.temp_allocator), {{"outer",200,0}})
        testing.expectf(t, c.width == 10, "unsupported/malformed condition %s -> %v", condition, c.width)
    }
}

@(test)
cq_nested_queries_keep_each_container :: proc(t: ^testing.T) {
    sheet := `section{container:outer / inline-size} article{container:inner / inline-size} #target{width:10px}
        @container outer (min-width:300px){@container inner (min-width:200px){#target{width:90px}}}`
    c := cq_test_compute(sheet, {{"outer",100,0}, {"inner",400,0}})
    testing.expect_value(t, c.width, 10)
    d := cq_test_compute(sheet, {{"outer",400,0}, {"inner",250,0}})
    testing.expect_value(t, d.width, 90)
    e := cq_test_compute(sheet, {{"outer",400,0}, {"inner",100,0}})
    testing.expect_value(t, e.width, 10)
}

@(test)
cq_names_are_case_sensitive_lists :: proc(t: ^testing.T) {
    sheet := `section{container-name:Card Other;container-type:inline-size} #target{width:10px}
        @container Card (width > 100px){#target{width:20px}}
        @container Other (width > 100px){#target{height:30px}}
        @container card (width > 100px){#target{width:90px}}`
    c := cq_test_compute(sheet, {{"outer",200,0}})
    testing.expect_value(t, c.width, 20)
    testing.expect_value(t, c.height, 30)
}

@(test)
cq_comma_alternatives_choose_containers_independently :: proc(t: ^testing.T) {
    sheet := `section{container:outer / inline-size} article{container:inner / size} #target{width:10px;height:20px}
        @container absent (width > 1px), outer (width >= 300px){#target{width:90px}}
        @container outer (width < 100px), inner (height > 100px){#target{height:70px}}
        @container outer (width > 1000px), missing (width > 1px){@container inner (height > 100px){#target{width:200px}}}`
    c := cq_test_compute(sheet,{{"outer",400,100},{"inner",200,150}})
    testing.expect_value(t,c.width,90)
    testing.expect_value(t,c.height,70)
}

@(test)
cq_physical_logical_axes_and_container_selection :: proc(t: ^testing.T) {
    for condition in ([]string{"(height >= 150px)", "(block-size:200px)", "(aspect-ratio:2/1)", "(orientation:landscape)", "(100px < height <= 200px)"}) {
        c := cq_test_compute(strings.concatenate({`section{container-type:size} #target{width:10px} @container `, condition, `{#target{width:90px}}`}, context.temp_allocator), {{"outer",400,200}})
        testing.expectf(t, c.width == 90, "%s => %v", condition, c.width)
    }
    // A horizontal inline-size container cannot answer block/height queries.
    c := cq_test_compute(`section{container:outer / size} article{container-type:inline-size} #target{width:10px}
        @container (height >= 150px){#target{width:90px}}`, {{"outer",400,200},{"inner",300,50}})
    testing.expect_value(t, c.width, 90)
    d := cq_test_compute(`section{container-type:inline-size} #target{width:10px}
        @container (height >= 10px){#target{width:90px}}`, {{"outer",400,200}})
    testing.expect_value(t, d.width, 10)
    for condition in ([]string{"(inline-size:300px)", "(height:300px)"}) {
        e := cq_test_compute(strings.concatenate({`section{container-type:inline-size;writing-mode:vertical-rl} #target{width:10px} @container `,condition,`{#target{width:90px}}`},context.temp_allocator), {{"outer",200,300}})
        testing.expect_value(t, e.width, 90)
    }
    f := cq_test_compute(`section{container-type:inline-size;writing-mode:vertical-rl} #target{width:10px}
        @container (block-size > 10px){#target{width:90px}}`, {{"outer",200,300}})
    testing.expect_value(t, f.width, 10)
    zero := cq_test_compute(`section{container-type:size} #target{width:10px}
        @container(aspect-ratio:2/1){#target{width:90px}}`,{{"outer",0,0}})
    testing.expect_value(t,zero.width,10)
    flat := cq_test_compute(`section{container-type:size} #target{width:10px}
        @container(aspect-ratio > 1000/1){#target{width:90px}}`,{{"outer",200,0}})
    testing.expect_value(t,flat.width,90)
}

@(test)
cq_relative_lengths_strict_ranges_and_closest_ancestor :: proc(t: ^testing.T) {
    c := cq_test_compute(`section{container-type:inline-size;font-size:20px} #target{width:10px}
        @container (width >= 10em){#target{width:90px}}`, {{"outer",200,50}})
    testing.expect_value(t, c.width, 90)
    d := cq_test_compute(`section{container-type:inline-size;font-size:24px} #target{width:10px}
        @container (width >= 10em){#target{width:90px}}`, {{"outer",200,50}})
    testing.expect_value(t, d.width, 10)
    e := cq_test_compute(`section,article{container-type:inline-size} #target{width:10px}
        @container (width > 200px){#target{width:90px}}`, {{"outer",600,50},{"inner",200,50}})
    testing.expect_value(t, e.width, 10)
    f := cq_test_compute(`section{container-type:inline-size} #target{width:10px}
        @container (width > 200px){#target{width:90px}}`, {{"outer",200.0005,50}})
    testing.expect_value(t, f.width, 90)
}

@(test)
cq_container_values_and_shorthand_priority :: proc(t: ^testing.T) {
    for entry in ([][2]string{{"container-type","banana"},{"container-name","none Card"},{"container-name","initial Card"},{"container","Card / size extra"},{"container","Card /"},{"container","Card / size / size"}}) {
        testing.expect(t, !css_supports_decl(entry[0],entry[1]))
    }
    a := cq_test_compute(`section{container-type:size;container:Card} #target{width:10px}
        @container Card (width > 100px){#target{width:90px}}`,{{"outer",400,200}})
    testing.expect_value(t, a.width, 10)
    b := cq_test_compute(`section{container:Card / size;container-type:normal} #target{width:10px}
        @container Card (width > 100px){#target{width:90px}}`,{{"outer",400,200}})
    testing.expect_value(t, b.width, 10)
    c := cq_test_compute(`section{container:Card / size;container-name:none} #target{width:10px}
        @container Card (width > 100px){#target{width:90px}}`,{{"outer",400,200}})
    testing.expect_value(t, c.width, 10)
    d := cq_test_compute(`section{container:Card / size} article{container:inherit} #target{width:10px}
        @container Card (width > 300px){#target{width:90px}}`,{{"outer",500,200},{"inner",100,200}})
    testing.expect_value(t,d.width,10)
}

@(test)
cq_layout_content_box_containment_and_nested_convergence :: proc(t: ^testing.T) {
    old_w, old_used, old_h, old_h_used, old_dirty := g_container_w, g_container_used, g_container_h, g_container_h_used, g_container_dirty
    g_container_w = nil; g_container_used = nil; g_container_h = nil; g_container_h_used = nil; g_container_dirty = false
    defer {
        delete(g_container_w); delete(g_container_used); delete(g_container_h); delete(g_container_h_used)
        g_container_w, g_container_used, g_container_h, g_container_h_used, g_container_dirty = old_w, old_used, old_h, old_h_used, old_dirty
    }
    root := html.parse(`<section id="outer"><article id="inner"><div id="target"></div></article></section>`)
    defer dom.free_tree(root)
    rules, keys := css.parse(`section{container:outer / size;width:400px;height:200px;padding:10px;border:5px solid}
        article{container:inner / size;width:100px;height:40px} #target{width:10px;height:20px}
        @container outer (width = 400px) and (height = 200px){article{width:300px}}
        @container inner (width >= 300px){#target{width:90px}}
        @container inner (height > 40px){#target{height:100px}}`)
    defer css.free_rules(&rules); defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules, 800, 600)
    layout := build_layout(root, styles, "")
    defer { free_layout(layout); free_styles(styles) }
    settle_container_tree(root, &rules, keys[:], &styles, &layout, "", 800, 600)
    testing.expect_value(t, g_container_w[cq_test_node(root,"outer")],400)
    testing.expect_value(t, g_container_h[cq_test_node(root,"outer")],200)
    testing.expect_value(t, styles[cq_test_node(root,"target")].width,90)
    testing.expect_value(t, styles[cq_test_node(root,"target")].height,20)
    testing.expect(t, !g_container_dirty)
}

@(test)
cq_size_containment_ignores_descendants_on_contained_axes :: proc(t: ^testing.T) {
    old_w, old_used, old_h, old_h_used, old_dirty := g_container_w, g_container_used, g_container_h, g_container_h_used, g_container_dirty
    g_container_w = nil; g_container_used = nil; g_container_h = nil; g_container_h_used = nil; g_container_dirty = false
    defer {
        delete(g_container_w); delete(g_container_used); delete(g_container_h); delete(g_container_h_used)
        g_container_w, g_container_used, g_container_h, g_container_h_used, g_container_dirty = old_w, old_used, old_h, old_h_used, old_dirty
    }
    root := html.parse(`<main><section id="full"><div></div></section><section id="inline"><div></div></section><section id="cis"><div></div></section></main>`)
    defer dom.free_tree(root)
    rules, keys := css.parse(`section{width:200px} #full,#cis{container-type:size}
        #inline{container-type:inline-size} #cis{contain-intrinsic-height:70px} div{height:120px}`)
    defer css.free_rules(&rules); defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root,&rules,800,600)
    defer free_styles(styles)
    layout := build_layout(root,styles,"")
    defer free_layout(layout)
    ensure_tab_geometry(layout,800,600)
    testing.expect_value(t,g_container_h[cq_test_node(root,"full")],0)
    testing.expect_value(t,g_container_h[cq_test_node(root,"inline")],120)
    testing.expect_value(t,g_container_h[cq_test_node(root,"cis")],70)
}
