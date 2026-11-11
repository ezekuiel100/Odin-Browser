package ui

import "core:testing"
import "core:strings"
import dompkg "../dom"
import htmlp "../html"
import csspkg "../css"
import im "../../vendor/imgui"

@(private="file")
wm_find :: proc(b: ^Box) -> ^Box {
    if b.node != nil && b.node.attrs["id"] == "t" do return b
    for c in b.children { if r := wm_find(c); r != nil do return r }
    return nil
}

@(private="file")
wm_font :: proc(b: ^Box, f: ^im.Font) {
    for &it in b.inlines { if it.kind == .Word { it.font = f; it.em = 1; it.text_w = 0 } }
    for c in b.children do wm_font(c, f)
}

@(private="file")
wm_build :: proc(source: string, f: ^im.Font) -> (^Box, ^Box, ^dompkg.Node) {
    doc := htmlp.parse(source)
    rules, _ := csspkg.parse("")
    defer csspkg.free_rules(&rules)
    styles, _ := compute_styles(doc, &rules, 800, 600)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    wm_font(root, f)
    return root, wm_find(root), doc
}

@(private="file")
wm_init_font :: proc(advances: ^[128]f32) -> im.Font {
    for &a in advances do a = 10
    return im.Font{FontSize = 20, IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
}

@(private="file")
wm_intrinsic :: proc(b: ^Box, minc: bool) -> f32 {
    old_has, old_w, old_mc, old_minc := b.has_width, b.width, b.width_mc, b.width_minc
    defer { b.has_width = old_has; b.width = old_w; b.width_mc = old_mc; b.width_minc = old_minc }
    b.has_width = false; b.width_mc = true; b.width_minc = minc
    layout_box(b, 0, 0, 1000)
    return b.w
}


@(test)
writing_vertical_geometry_and_reflow :: proc(t:^testing.T) {
    advances:[128]f32
    f:=wm_init_font(&advances)
    defer text_metrics_clear()
    for mode in ([]string{"vertical-rl","vertical-lr"}) {
        source:=strings.concatenate({`<div id="t" style="writing-mode:`,mode,`;text-orientation:upright;font-size:20px;line-height:1;height:40px">ABCD</div>`})
        root,b,doc:=wm_build(source,&f)
        for _ in 0..<3 {
            layout_box(b,0,0,300)
            testing.expectf(t,b.w==40 && b.h==40,"%s: %v x %v",mode,b.w,b.h)
            testing.expect(t,len(b.inlines)==4)
            if len(b.inlines)==4 {
                testing.expect(t,b.inlines[0].y==0 && b.inlines[1].y==20 && b.inlines[2].y==0)
                testing.expect(t,b.inlines[0].x==(mode=="vertical-rl" ? 20 : 0))
                testing.expect(t,b.inlines[2].x==(mode=="vertical-rl" ? 0 : 20))
            }
            b.height=80
            layout_box(b,0,0,300)
            testing.expect(t,b.w==20 && b.h==80 && len(b.inlines)==4)
            b.height=40
        }
        free_layout(root); dompkg.free_tree(doc); delete(source)
    }
}

@(test)
writing_sideways_metrics :: proc(t:^testing.T) {
    advances:[128]f32
    f:=wm_init_font(&advances)
    defer text_metrics_clear()
    root,b,doc:=wm_build(`<div id="t" style="writing-mode:vertical-rl;text-orientation:sideways;font-size:20px;line-height:1;height:40px">AB CD</div>`,&f)
    layout_box(b,0,0,300)
    testing.expect(t,b.w==40 && len(b.inlines)==2)
    testing.expect(t,b.inlines[0].vertical_sideways && b.inlines[0].h==20 && b.inlines[0].w==20)
    testing.expect(t,b.inlines[0].x==20 && b.inlines[1].x==0)
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
writing_logical_axes_and_inheritance :: proc(t:^testing.T) {
    root,b,doc:=wm_build(`<div style="writing-mode:vertical-rl"><div id="t" style="inline-size:80px;block-size:60px;padding-inline:5px 7px;padding-block:11px 13px;border-start-start-radius:9px"></div></div>`,nil)
    testing.expect(t,b.writing_mode==.Vertical_Rl && b.has_height && b.height==80 && b.width==60)
    testing.expectf(t,b.padding==[4]f32{5,11,7,13},"padding %v",b.padding)
    testing.expect(t,b.border_radius[1]==9)
    free_layout(root); dompkg.free_tree(doc)
    root,b,doc=wm_build(`<div id="t" style="--mode:vertical-lr;writing-mode:var(--mode);direction:rtl;padding-inline-start:5px;padding-block-start:9px"></div>`,nil)
    testing.expect(t,b.writing_mode==.Vertical_Lr && b.padding[2]==5 && b.padding[3]==9)
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
writing_vertical_blocks_flow :: proc(t:^testing.T) {
    root,b,doc:=wm_build(`<div id="t" style="writing-mode:vertical-rl;width:100px;height:80px"><div style="width:20px;height:30px"></div><div style="width:40px;height:50px"></div></div>`,nil)
    layout_box(b,0,0,300)
    testing.expect(t,len(b.children)==2)
    if len(b.children)==2 {
        testing.expect(t,b.children[0].x==80 && b.children[1].x==40)
        testing.expect(t,b.children[0].y==0 && b.children[1].y==0)
    }
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
writing_inline_bidi_scopes :: proc(t:^testing.T) {
    advances:[128]f32
    f:=wm_init_font(&advances)
    defer text_metrics_clear()
    root,b,doc:=wm_build(`<div id="t" style="font-size:20px;line-height:1;width:300px">AA <span style="direction:rtl;unicode-bidi:isolate-override">BB CC</span> DD</div>`,&f)
    layout_box(b,0,0,300)
    testing.expect(t,len(b.inlines)==4)
    if len(b.inlines)==4 {
        testing.expect(t,b.inlines[1].bidi_scope_n==1 && b.inlines[1].bidi_override)
        testing.expect(t,b.inlines[2].x<b.inlines[1].x)
        testing.expect(t,b.inlines[0].x<b.inlines[2].x && b.inlines[1].x<b.inlines[3].x)
        testing.expect(t,b.inlines[1].text=="BB")
    }
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
writing_css_validation :: proc(t:^testing.T) {
    testing.expect(t,css_supports_decl("writing-mode","vertical-rl"))
    testing.expect(t,css_supports_decl("writing-mode","vertical-lr"))
    testing.expect(t,!css_supports_decl("writing-mode","diagonal"))
    testing.expect(t,css_supports_decl("text-orientation","upright"))
    testing.expect(t,!css_supports_decl("text-orientation","upside-down"))
    testing.expect(t,css_supports_decl("unicode-bidi","isolate-override"))
    testing.expect(t,!css_supports_decl("unicode-bidi","reverse"))
}

@(test)
writing_unicode_vertical_orientation :: proc(t:^testing.T) {
    testing.expect(t,vertical_upright("日",.Mixed))
    testing.expect(t,!vertical_upright("A",.Mixed))
    testing.expect(t,vertical_upright("A",.Upright))
    testing.expect(t,!vertical_upright("日",.Sideways))
    advances:[128]f32
    f:=wm_init_font(&advances)
    f.FallbackAdvanceX=10
    defer text_metrics_clear()
    root,b,doc:=wm_build(`<div id="t" style="writing-mode:vertical-rl;height:200px;font-size:20px;line-height:1">AB日本CD</div>`,&f)
    layout_box(b,0,0,300)
    testing.expect(t,len(b.inlines)==4)
    if len(b.inlines)==4 {
        testing.expect(t,b.inlines[0].text=="AB" && b.inlines[0].vertical_sideways)
        testing.expect(t,b.inlines[1].text=="日" && !b.inlines[1].vertical_sideways)
        testing.expect(t,b.inlines[3].text=="CD" && b.inlines[3].vertical_sideways)
    }
    free_layout(root); dompkg.free_tree(doc)
}

@(test)
writing_inline_orientation_override :: proc(t:^testing.T) {
    advances:[128]f32
    f:=wm_init_font(&advances)
    defer text_metrics_clear()
    root,b,doc:=wm_build(`<div id="t" style="writing-mode:vertical-rl;text-orientation:sideways;font-size:20px;line-height:1;height:100px"><span style="text-orientation:upright">AB</span></div>`,&f)
    defer { free_layout(root); dompkg.free_tree(doc) }
    for _ in 0..<2 {
        layout_box(b,0,0,300)
        testing.expect_value(t,len(b.inlines),2)
        for it in b.inlines {
            testing.expect(t,!it.vertical_sideways)
            testing.expect_value(t,it.h,20)
        }
    }
}
