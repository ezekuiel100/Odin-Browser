package ui

import "core:testing"
import "core:strings"
import dompkg "../dom"
import htmlp "../html"
import csspkg "../css"
import im "../../vendor/imgui"

@(private="file")
td_find :: proc(b: ^Box) -> ^Box {
    if b.node != nil && b.node.attrs["id"] == "t" do return b
    for c in b.children { if r := td_find(c); r != nil do return r }
    return nil
}

@(private="file")
td_font :: proc(b: ^Box, f: ^im.Font) {
    for &it in b.inlines { if it.kind == .Word { it.font = f; it.em = 1; it.text_w = 0 } }
    for c in b.children do td_font(c, f)
}

@(private="file")
td_build :: proc(source: string, f: ^im.Font) -> (^Box, ^Box, ^dompkg.Node) {
    doc := htmlp.parse(source)
    rules, _ := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    styles, _ := compute_styles(doc, &rules, 800, 600)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    td_font(root, f)
    return root, td_find(root), doc
}

@(private="file")
td_init_font :: proc(advances: ^[128]f32) -> im.Font {
    for &a in advances do a = 10
    return im.Font{FontSize = 20, IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
}

@(private="file")
td_intrinsic :: proc(b: ^Box, minc: bool) -> f32 {
    old_has, old_w, old_mc, old_minc := b.has_width, b.width, b.width_mc, b.width_minc
    defer { b.has_width = old_has; b.width = old_w; b.width_mc = old_mc; b.width_minc = old_minc }
    b.has_width = false; b.width_mc = true; b.width_minc = minc
    layout_box(b, 0, 0, 1000)
    return b.w
}

@(test)
text_direction_alignment_geometry :: proc(t: ^testing.T) {
    advances: [128]f32
    f := td_init_font(&advances)
    defer text_metrics_clear()
    cases := []struct { css: string, x: f32 }{
        {"direction:rtl",80},
        {"direction:rtl;text-align:start",80},
        {"direction:rtl;text-align:end",0},
        {"direction:rtl;text-align:left",0},
        {"direction:ltr;text-align:end",80},
        {"direction:rtl;text-indent:10px",70},
    }
    for c in cases {
        source := strings.concatenate({`<div id="t" style="width:100px;font-size:20px;line-height:1;`,c.css,`">AA</div>`})
        root,b,doc := td_build(source,&f)
        layout_box(b,0,0,100)
        testing.expectf(t,b.inlines[0].x == c.x,"%s: x=%v expected %v",c.css,b.inlines[0].x,c.x)
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
}

@(test)
text_direction_logical_cascade :: proc(t: ^testing.T) {
    for decl in ([]string{
        "direction:rtl;padding-inline-start:11px;padding-inline-end:22px",
        "--d:rtl;direction:var(--d);padding-inline:11px 22px",
    }) {
        source := strings.concatenate({`<div id="t" style="`,decl,`"></div>`})
        root,b,doc := td_build(source,nil)
        testing.expectf(t,b.padding[1] == 11 && b.padding[3] == 22,"%s: %v",decl,b.padding)
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
    root,b,doc := td_build(`<div style="direction:rtl"><div id="t" style="margin-inline-start:13px;border-start-start-radius:7px;padding-right:2px;padding-inline-start:9px"></div></div>`,nil)
    testing.expect(t,b.margin[1] == 13 && b.padding[1] == 9 && b.border_radius[1] == 7)
    free_layout(root); dompkg.free_tree(doc)
    root,b,doc = td_build(`<div dir="rtl"><div id="t" style="padding-inline:5px 12px;padding-left:4px!important"></div></div>`,nil)
    testing.expectf(t,b.direction == .Rtl && b.padding[1] == 5 && b.padding[3] == 4,"direction %v padding %v",b.direction,b.padding)
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
text_direction_match_parent :: proc(t: ^testing.T) {
    advances: [128]f32
    f := td_init_font(&advances)
    defer text_metrics_clear()
    for match in ([]bool{false,true}) {
        align := match ? "match-parent" : "start"
        source := strings.concatenate({`<div style="direction:rtl;text-align:start"><div id="t" style="direction:ltr;text-align:`,align,`;width:100px;font-size:20px;line-height:1">AA</div></div>`})
        root,b,doc := td_build(source,&f)
        layout_box(b,0,0,100)
        testing.expectf(t,b.inlines[0].x == (match ? 80 : 0),"%s",align)
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
}

@(test)
text_indent_forced_and_soft_lines :: proc(t: ^testing.T) {
    advances: [128]f32
    f := td_init_font(&advances)
    defer text_metrics_clear()
    cases := []struct { value: string, xs: [3]f32 }{
        {"10px",{10,0,0}},
        {"10px each-line",{10,0,10}},
        {"10px hanging",{0,10,10}},
        {"each-line 10px hanging",{0,10,0}},
    }
    for c in cases {
        source := strings.concatenate({`<div id="t" style="width:40px;font-size:20px;line-height:1;text-indent:`,c.value,`">AAA BB<br>CC</div>`})
        root,b,doc := td_build(source,&f)
        layout_box(b,0,0,40)
        testing.expectf(t,len(b.inlines)==4,"%s items %d",c.value,len(b.inlines))
        if len(b.inlines)==4 {
            testing.expectf(t,b.inlines[0].x==c.xs[0] && b.inlines[1].x==c.xs[1] && b.inlines[3].x==c.xs[2],"%s: %v/%v/%v",c.value,b.inlines[0].x,b.inlines[1].x,b.inlines[3].x)
            testing.expect(t,b.inlines[1].y==20 && b.inlines[3].y==40)
        }
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
}

@(test)
text_tabs_position_intrinsic_reflow :: proc(t: ^testing.T) {
    advances: [128]f32
    f := td_init_font(&advances)
    defer text_metrics_clear()
    for mode in ([]string{"pre","pre-wrap","break-spaces"}) {
        source := strings.concatenate({`<div id="t" style="font-size:20px;line-height:1;white-space:`,mode,`;tab-size:4">A`,"\t",`B`,"\t",`C</div>`})
        root,b,doc := td_build(source,&f)
        testing.expectf(t,td_intrinsic(b,false)==90,"%s intrinsic",mode)
        for _ in 0..<2 {
            layout_box(b,0,0,200)
            testing.expectf(t,len(b.inlines)==5,"%s tabs are individual items",mode)
            if len(b.inlines)==5 {
                testing.expectf(t,b.inlines[2].x==40 && b.inlines[4].x==80,"%s: %v/%v",mode,b.inlines[2].x,b.inlines[4].x)
                testing.expect(t,b.inlines[1].w==30 && b.inlines[3].w==30)
            }
        }
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
    root,b,doc := td_build(`<div id="t" style="font-size:20px;line-height:1;white-space:pre;tab-size:0">A`+"\t"+`B</div>`,&f)
    layout_box(b,0,0,200)
    testing.expect(t,b.inlines[2].x==10)
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
text_direction_values_and_cssom :: proc(t: ^testing.T) {
    for good in ([]string{"2em each-line","hanging -10% each-line","0","calc(10px + 2%) hanging"}) {
        testing.expectf(t,css_supports_decl("text-indent",good),"valid: %s",good)
    }
    for bad in ([]string{"each-line","2px 3px","2px each-line each-line","auto","junk"}) {
        testing.expectf(t,!css_supports_decl("text-indent",bad),"invalid: %s",bad)
    }
    testing.expect(t,!css_supports_decl("text-align","junk"))
    testing.expect(t,css_supports_decl("text-align","match-parent"))
    testing.expect(t,!css_supports_decl("tab-size","-1"))
    testing.expect(t,!css_supports_decl("tab-size","junk"))
    c := test_apply("text-align:start;text-align-last:end;text-indent:10% hanging each-line;tab-size:0")
    n := dompkg.Node{}
    styles := make(map[^dompkg.Node]Computed); styles[&n]=c
    js_style_source_set(styles,nil,800,600)
    testing.expect(t,js_computed_style(&n,"text-align")=="start")
    testing.expect(t,js_computed_style(&n,"text-align-last")=="end")
    testing.expect(t,js_computed_style(&n,"text-indent")=="10% hanging each-line")
    testing.expect(t,js_computed_style(&n,"tab-size")=="0")
    js_style_source_free(); delete(styles)
}
