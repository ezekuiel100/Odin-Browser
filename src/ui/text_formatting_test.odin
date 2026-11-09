package ui

import "core:testing"
import "core:strings"
import im "../../vendor/imgui"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private="file")
tf_find :: proc(b: ^Box) -> ^Box {
    if b.node != nil && b.node.attrs["id"] == "t" do return b
    for c in b.children { if r := tf_find(c); r != nil do return r }
    return nil
}

@(private="file")
tf_font :: proc(b: ^Box, f: ^im.Font) {
    for &it in b.inlines { if it.kind == .Word { it.font = f; it.em = 1; it.text_w = 0 } }
    for c in b.children do tf_font(c, f)
}

@(private="file")
tf_build :: proc(source: string, f: ^im.Font) -> (^Box, ^Box, ^dompkg.Node) {
    doc := htmlp.parse(source)
    rules, _ := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    styles, _ := compute_styles(doc, &rules, 800, 600)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    tf_font(root, f)
    return root, tf_find(root), doc
}

@(private="file")
tf_init_font :: proc(advances: ^[128]f32) -> im.Font {
    for &a in advances do a = 10
    return im.Font{FontSize = 20, IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
}

@(test)
test_text_white_space_modes_geometry :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    cases := []struct { style, text: string, height, second_x: f32 }{
        {"normal", "AA   BB", 20, 30},
        {"nowrap", "AA   BB", 20, 30},
        {"pre", "AA   BB", 20, 20},
        {"pre-wrap", "AA   BB", 40, 20},
        {"break-spaces", "AA   BB", 40, 20},
        {"pre-line", "AA   BB", 20, 30},
    }
    for c in cases {
        source := strings.concatenate({`<div id="t" style="width:50px;font-size:20px;line-height:1;white-space:`, c.style, `">`, c.text, `</div>`})
        root, b, doc := tf_build(source, &f)
        delete(source)
        defer free_layout(root)
        defer dompkg.free_tree(doc)
        testing.expect(t, b != nil)
        if b == nil do continue
        layout_box(b, 0, 0, 50)
        testing.expectf(t, b.h == c.height, "%s: height %v expected %v", c.style, b.h, c.height)
        testing.expectf(t, len(b.inlines) > 1 && b.inlines[1].x == c.second_x, "%s: second item x", c.style)
    }
}

@(test)
test_text_pre_lines_and_blank_line_height :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    for mode in ([]string{"pre", "pre-wrap", "pre-line", "break-spaces"}) {
        source := strings.concatenate({`<div id="t" style="width:100px;font-size:20px;line-height:1;white-space:`, mode, `">AA`, "\n\n  BB\n", `</div>`})
        root, b, doc := tf_build(source, &f)
        delete(source)
        defer free_layout(root)
        defer dompkg.free_tree(doc)
        layout_box(b, 0, 0, 100)
        testing.expectf(t, b.h == 60, "%s: blank line counts, final newline adds no empty line: %v", mode, b.h)
        last_word: ^Inline_Item
        for &it in b.inlines do if it.kind == .Word && it.text == "BB" do last_word = &it
        testing.expect(t, last_word != nil)
        if last_word != nil { testing.expect(t, last_word.y == 40); testing.expect(t, last_word.x == (mode == "pre-line" ? 0 : 20)) }
    }
}

@(test)
test_text_pre_never_soft_wraps_across_spans_and_atoms :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<div id="t" style="width:25px;font-size:20px;line-height:1;white-space:pre">AA <b>BB</b><span style="display:inline-block;width:20px;height:20px"></span></div>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    layout_box(b, 0, 0, 25)
    testing.expectf(t, b.h == 24, "pre content stays on one line: %v", b.h)
    testing.expect(t, b.inlines[len(b.inlines)-1].x >= 50)
}

@(test)
test_text_break_all_fills_remaining_line :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<div id="t" style="width:60px;font-size:20px;line-height:1;word-break:break-all">AA ABCDEF</div>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    layout_box(b, 0, 0, 60)
    testing.expect(t, len(b.inlines) == 3)
    testing.expectf(t, b.inlines[1].text == "ABC" && b.inlines[1].x == 30 && b.inlines[1].y == 0, "fills remainder before breaking")
    testing.expect(t, b.inlines[2].text == "DEF" && b.inlines[2].y == 20)
}

@(test)
test_text_overflow_wrap_emergency_vs_intrinsic :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    for mode in ([]string{"break-word", "anywhere"}) {
        source := strings.concatenate({`<div id="t" style="width:60px;font-size:20px;line-height:1;overflow-wrap:`, mode, `">AA ABCDEFGH</div>`})
        root, b, doc := tf_build(source, &f)
        delete(source)
        defer free_layout(root)
        defer dompkg.free_tree(doc)
        testing.expect(t, tf_intrinsic(b, true) == (mode == "anywhere" ? 10 : 80))
        testing.expect(t, tf_intrinsic(b, false) == 110)
        layout_box(b, 0, 0, 60)
        testing.expect(t, len(b.inlines) == 3)
        testing.expect(t, b.inlines[1].x == 0 && b.inlines[1].y == 20)
        testing.expect(t, b.h == 60)
    }
}

@(test)
test_text_reflow_restores_unsplit_words_and_intrinsic :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<div id="t" style="font-size:20px;line-height:1;overflow-wrap:break-word"><a href="/">ABCDEFGH</a></div>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    for _ in 0..<3 {
        b.has_width = true; b.width = 30
        layout_box(b, 0, 0, 30)
        testing.expect(t, b.h == 60)
        testing.expect(t, len(b.inlines) == 3)
        testing.expect(t, tf_intrinsic(b, true) == 80)
        testing.expect(t, tf_intrinsic(b, false) == 80)
        b.has_width = true; b.width = 100
        layout_box(b, 0, 0, 100)
        testing.expect(t, b.h == 20)
        testing.expect(t, len(b.inlines) == 1 && b.inlines[0].text == "ABCDEFGH")
        testing.expect(t, b.inlines[0].href != "")
    }
}

@(test)
test_text_cluster_boundaries :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    f.FallbackAdvanceX = 10
    defer text_metrics_clear()
    cases := []string{"a\u0301", "\U0001f1e7\U0001f1f7", "\U0001f469\u200d\U0001f4bb", "\u2764\ufe0f"}
    for cluster in cases {
        b := Box{is_inline = true, has_width = true, width = 10}
        append(&b.inlines, Inline_Item{kind = .Word, font = &f, fsize = 20, em = 1, lh = 1,
            text = strings.concatenate({cluster, "X"}), can_break = true})
        layout_box(&b, 0, 0, 10)
        testing.expectf(t, len(b.inlines) == 2 && b.inlines[0].text == cluster, "cluster %s stays intact", cluster)
        for &it in b.inlines do delete(it.text)
        delete(b.inlines)
    }
}

@(test)
test_text_pre_wrap_hanging_vs_break_spaces :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<div id="t" style="width:50px;font-size:20px;line-height:1;white-space:pre-wrap;text-align:right">AA   </div>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    testing.expect(t, tf_intrinsic(b, false) == 20 && tf_intrinsic(b, true) == 20)
    layout_box(b, 0, 0, 50)
    testing.expectf(t, b.inlines[0].x == 30, "trailing spaces hang outside alignment: %v", b.inlines[0].x)
    root2, b2, doc2 := tf_build(`<div id="t" style="width:30px;font-size:20px;line-height:1;white-space:break-spaces">AA   </div>`, &f)
    defer free_layout(root2)
    defer dompkg.free_tree(doc2)
    testing.expect(t, tf_intrinsic(b2, false) == 50)
    testing.expect(t, tf_intrinsic(b2, true) == 30)
    layout_box(b2, 0, 0, 30)
    testing.expect(t, b2.h == 40)
}

@(test)
test_text_style_serialization_and_validation :: proc(t: ^testing.T) {
    for mode in ([]string{"normal", "nowrap", "pre", "pre-wrap", "pre-line", "break-spaces"}) {
        decl := strings.concatenate({"white-space:", mode})
        c := test_apply(decl)
        delete(decl)
        node := dompkg.Node{}
        styles := make(map[^dompkg.Node]Computed)
        styles[&node] = c
        js_style_source_set(styles, nil, 800, 600)
        testing.expect(t, js_computed_style(&node, "white-space") == mode)
        js_style_source_free()
        delete(styles)
        testing.expect(t, css_supports_decl("white-space", mode))
    }
    testing.expect(t, !css_supports_decl("white-space", "garbage"))
    testing.expect(t, !css_supports_decl("word-break", "keep-all"))
    testing.expect(t, !css_supports_decl("overflow-wrap", "invalid"))
}
// Exercise the intrinsic path through the actual width:min/max-content layout.
@(private="file")
tf_intrinsic :: proc(b: ^Box, minc: bool) -> f32 {
    old_has, old_w, old_mc, old_minc := b.has_width, b.width, b.width_mc, b.width_minc
    defer { b.has_width = old_has; b.width = old_w; b.width_mc = old_mc; b.width_minc = old_minc }
    b.has_width = false; b.width_mc = true; b.width_minc = minc
    layout_box(b, 0, 0, 1000)
    return b.w
}
@(test)
test_text_nowrap_overrides_character_breaks :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<div id="t" style="width:20px;font-size:20px;line-height:1;white-space:nowrap;word-break:break-all;overflow-wrap:anywhere">AA BBBB</div>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    testing.expect(t, tf_intrinsic(b, true) == 70)
    layout_box(b, 0, 0, 20)
    testing.expect(t, b.h == 20 && len(b.inlines) == 2)
}

@(test)
test_text_wrap_inheritance_and_reset :: proc(t: ^testing.T) {
    c := test_compute_child(".g{overflow-wrap:anywhere;word-break:break-all;white-space:pre-wrap}")
    testing.expect(t, c.wrap_anywhere && c.break_word && c.break_all && c.white_space == .Pre_Wrap)
    reset := test_apply("overflow-wrap:anywhere;overflow-wrap:normal;word-break:break-all;word-break:normal")
    testing.expect(t, !reset.wrap_anywhere && !reset.break_word && !reset.break_all)
}
@(test)
test_text_pre_author_normal_overrides_ua :: proc(t: ^testing.T) {
    advances: [128]f32
    f := tf_init_font(&advances)
    defer text_metrics_clear()
    root, b, doc := tf_build(`<pre id="t" style="width:50px;font-size:20px;line-height:1;white-space:normal;margin:0">AA   BB</pre>`, &f)
    defer free_layout(root)
    defer dompkg.free_tree(doc)
    layout_box(b, 0, 0, 50)
    testing.expect(t, b.h == 20 && len(b.inlines) == 2)
    testing.expect(t, b.inlines[1].x == 30 && !b.inlines[1].nowrap)
}