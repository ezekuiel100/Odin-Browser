package ui

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"
import im "../../vendor/imgui"

@(test)
inline_visibility_and_opacity_survive_flattening :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<body><div><span style="visibility:hidden;background:red">hidden <span style="visibility:visible">shown</span></span><span style="opacity:.5">one <span style="opacity:.5">two</span></span></div></body>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    inspect :: proc(b: ^Box, t: ^testing.T, count: ^int) {
        for it in b.inlines {
            switch it.text {
            case "hidden":
                count^ += 1
                testing.expect(t, it.invisible && it.ibg_invisible)
            case "shown":
                count^ += 1
                testing.expect(t, !it.invisible && it.ibg_invisible,
                    "visible descendant must not revive the hidden ancestor background")
            case "one":
                count^ += 1
                testing.expect(t, it.effect != nil && it.effect.opacity == .5)
            case "two":
                count^ += 1
                testing.expect(t, it.effect != nil && it.effect.parent != nil)
                if it.effect != nil && it.effect.parent != nil {
                    testing.expect(t, it.effect.opacity == .5 && it.effect.parent.opacity == .5)
                }
            }
        }
        for child in b.children do inspect(child, t, count)
    }
    count := 0
    inspect(root, t, &count)
    testing.expect_value(t, count, 4)
}

@(test)
inline_absolute_and_fixed_leave_text_flow :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<body style="margin:0"><div style="position:relative;width:200px;height:100px">before <span><span id="abs" style="position:absolute;left:30px;top:40px;width:20px;height:10px">tip</span></span> after <span id="fix" style="position:fixed;left:5px;top:6px;width:7px;height:8px">fixed</span></div></body>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    layout_box(root, 0, 0, 800)
    page := Rect{0, 0, 800, 600}
    layout_absolutes(root, page, page)
    inspect :: proc(b: ^Box, t: ^testing.T, count: ^int) {
        if b.node != nil {
            id := b.node.attrs["id"]
            if id == "abs" {
                count^ += 1
                testing.expect(t, b.pos == .Absolute && b.x == 30 && b.y == 40)
                testing.expect(t, b.w == 20 && b.h == 10)
            }
            if id == "fix" {
                count^ += 1
                testing.expect(t, b.pos == .Fixed && b.x == 5 && b.y == 6)
            }
        }
        if b.pos == .Static || b.pos == .Relative {
            for it in b.inlines do testing.expect(t, it.text != "tip" && it.text != "fixed",
                "out-of-flow text must not contribute to the parent's line")
        }
        for child in b.children do inspect(child, t, count)
    }
    count := 0
    inspect(root, t, &count)
    testing.expect_value(t, count, 2)
}

@(test)
inline_opacity_keeps_word_wrapping :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<div style="width:45px"><span style="opacity:.5">one two</span></div>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    advances: [128]f32
    for &a in advances do a = 10
    font := im.Font{FontSize = 10, IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
    inspect :: proc(b: ^Box, font: ^im.Font) -> ^Box {
        if len(b.inlines) == 2 {
            for &it in b.inlines { it.font = font; it.fsize = 10; it.em = 1; it.lh = 1 }
            return b
        }
        for child in b.children do if r := inspect(child, font); r != nil do return r
        return nil
    }
    line := inspect(root, &font)
    testing.expect(t, line != nil)
    if line == nil do return
    layout_box(root, 0, 0, 45)
    testing.expect(t, line.inlines[1].y > line.inlines[0].y,
        "opacity must not turn the span into an unbreakable inline-block")
    testing.expect(t, line.inlines[0].effect == line.inlines[1].effect)
    defer text_metrics_clear()
}

@(test)
inline_button_positions_absolute_and_viewport_fixed_children :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<body style="margin:0"><div style="position:absolute;left:100px;top:80px"><button style="position:relative;width:150px;height:50px;border:0;padding:0;margin:0"><span id="tip" style="position:absolute;left:10px;top:10px;width:40px;height:20px"></span><span id="fixedtip" style="position:fixed;left:600px;top:300px;width:40px;height:20px"></span></button></div></body>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    layout_box(root, 0, 0, 800)
    page := Rect{0, 0, 800, 600}
    layout_absolutes(root, page, page)
    inspect :: proc(b: ^Box, ox, oy: f32, t: ^testing.T, count: ^int) {
        if b.node != nil {
            switch b.node.attrs["id"] {
            case "tip":
                count^ += 1
                testing.expectf(t, b.x+ox == 110 && b.y+oy == 90,
                    "absolute tooltip global=(%v,%v)", b.x+ox, b.y+oy)
            case "fixedtip":
                count^ += 1
                testing.expectf(t, b.x+ox == 600 && b.y+oy == 300,
                    "fixed tooltip global=(%v,%v)", b.x+ox, b.y+oy)
            }
        }
        for child in b.children do inspect(child, ox, oy, t, count)
        for it in b.inlines do if it.kind == .InlineBox && it.box != nil {
            inspect(it.box, ox+b.content_x+it.x, oy+b.content_y+it.y, t, count)
        }
    }
    count := 0
    inspect(root, 0, 0, t, &count)
    testing.expect_value(t, count, 2)
}
