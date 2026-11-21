package ui

import "core:testing"
import "core:fmt"
import "core:strings"
import dompkg "../dom"
import htmlp "../html"
import csspkg "../css"

@(private="file")
homepage_geometry :: proc(source: string, height: f32 = 600, passes: int = 1) -> map[string]Rect {
    doc := htmlp.parse(source)
    rules, kf := csspkg.parse(collect_css(doc))
    styles, _ := compute_styles(doc, &rules, 800, height)
    root := build_layout(doc, styles, "")
    defer {
        free_layout(root); free_styles(styles)
        csspkg.free_rules(&rules); csspkg.free_keyframes(&kf)
        dompkg.free_tree(doc)
    }
    for i in 0 ..< passes {
        layout_box(root, 0, 0, 800)
        page := Rect{0, 0, 800, height}
        layout_absolutes(root, page, page)
    }
    result := make(map[string]Rect, context.temp_allocator)
    homepage_collect(root, &result)
    return result
}

@(private="file")
homepage_collect :: proc(b: ^Box, result: ^map[string]Rect) {
    if b == nil do return
    if b.node != nil {
        if id, ok := b.node.attrs["id"]; ok do result[strings.clone(id, context.temp_allocator)] = Rect{b.x, b.y, b.w, b.h}
    }
    for c in b.children do homepage_collect(c, result)
    for it in b.inlines do if it.box != nil do homepage_collect(it.box, result)
}

@(test)
homepage_percent_height_chain_keeps_footer_at_viewport_bottom :: proc(t: ^testing.T) {
    heights := []f32{600, 900}
    for height in heights {
        r := homepage_geometry(`<html><head><style>html,body{height:100%;margin:0}
            main{display:flex;flex-direction:column;height:100%}</style></head><body>
            <main><header style="height:60px"></header><section id="space" style="flex-grow:1"></section>
            <footer id="footer" style="height:80px"></footer></main></body></html>`, height)
        testing.expect_value(t, r["footer"].y, height - 80)
        testing.expect_value(t, r["space"].h, height - 140)
    }
    // An ordinary auto-height ancestor must still leave percentages unresolved.
    r := homepage_geometry(`<body style="margin:0"><div><div id="auto" style="height:50%">
        <div style="height:20px"></div></div></div></body>`)
    testing.expect_value(t, r["auto"].h, f32(20))
}

@(test)
homepage_flex_overlays_do_not_collapse_text_field :: proc(t: ^testing.T) {
    directions := []string{"row", "column"}
    positions := []string{"absolute", "fixed"}
    for direction in directions {
        for position in positions {
            source := fmt.tprintf(`<body style="margin:0"><div style="position:relative;display:flex;
                flex-direction:%s;width:400px;height:100px;gap:10px">
                <div style="width:40px;height:20px;flex-shrink:0"></div>
                <div id="field" style="flex:1;min-width:0;min-height:0"></div>
                <div style="width:40px;height:20px;flex-shrink:0"></div>
                <div style="position:%s;width:100%%;height:100%%;flex:1"></div></div></body>`, direction, position)
            for passes in 1 ..= 2 {
                r := homepage_geometry(source, 600, passes)
                if direction == "row" {
                    testing.expect_value(t, r["field"].x, f32(50))
                    testing.expect_value(t, r["field"].w, f32(300))
                } else {
                    testing.expect_value(t, r["field"].y, f32(30))
                    testing.expect_value(t, r["field"].h, f32(40))
                }
            }
        }
    }
}

@(test)
homepage_center_tag_aligns_buttons_and_author_css_wins :: proc(t: ^testing.T) {
    doc := htmlp.parse(`<center id="buttons"><span>buttons</span></center>
        <center id="override" style="text-align:left">buttons</center>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse("")
    defer { csspkg.free_rules(&rules); csspkg.free_keyframes(&kf) }
    styles, _ := compute_styles(doc, &rules, 800, 600)
    defer free_styles(styles)
    for node, style in styles {
        if node.tag == "span" || node.attrs["id"] == "buttons" do testing.expect_value(t, style.text_align, Text_Align.Center)
        if node.attrs["id"] == "override" do testing.expect_value(t, style.text_align, Text_Align.Left)
    }
}
