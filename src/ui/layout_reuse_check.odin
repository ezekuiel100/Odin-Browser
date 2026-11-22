package ui

import "core:fmt"

// Optional geometry oracle for real pages, analogous to STYLECHECK. It builds
// an independent complete tree from the same styles and compares anonymous
// boxes and inline fragments too. Disabled builds pay no comparison cost.
LAYOUTCHECK :: #config(LAYOUTCHECK, false)
when LAYOUTCHECK {
    g_layout_check_runs, g_layout_check_boxes, g_layout_check_mismatches: int
}

layout_check_reuse :: proc(tab: ^Tab, vw, vh: f32) {
    when LAYOUTCHECK {
        ref := build_layout(tab.dom, tab.styles, tab.url)
        defer free_layout(ref)
        ensure_tab_geometry(tab.layout, vw, vh)
        ensure_tab_geometry(ref, vw, vh)
        compare :: proc(a, b: ^Box) {
            if a == nil || b == nil {
                if a != b do g_layout_check_mismatches += 1
                return
            }
            g_layout_check_boxes += 1
            if a.node != b.node || a.kind != b.kind || a.is_inline != b.is_inline ||
               a.is_flex != b.is_flex || a.is_grid != b.is_grid ||
               a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h ||
               a.content_w != b.content_w || len(a.children) != len(b.children) || len(a.inlines) != len(b.inlines) {
                g_layout_check_mismatches += 1
                if g_layout_check_mismatches <= 8 {
                    tag := a.node != nil ? a.node.tag : "anonymous"
                    fmt.eprintfln("[layoutcheck] DIVERGE tag=%s node=%p box=%p xywh=%v/%v children=%d/%d inlines=%d/%d",
                        tag, a.node, a, [4]f32{a.x,a.y,a.w,a.h}, [4]f32{b.x,b.y,b.w,b.h}, len(a.children),len(b.children),len(a.inlines),len(b.inlines))
                    fmt.eprintfln("[layoutcheck] model flex/grid/inline=%v/%v/%v height=%v/%v hasH=%v/%v min=%v/%v max=%v/%v pad=%v/%v margin=%v/%v border=%v/%v",
                        a.is_flex,a.is_grid,a.is_inline,a.height,b.height,a.has_height,b.has_height,a.minh,b.minh,a.maxh,b.maxh,a.padding,b.padding,a.margin,b.margin,a.border_w,b.border_w)
                    if len(a.children)>0 && len(b.children)>0 do fmt.eprintfln("[layoutcheck] first child xywh=%v/%v",[4]f32{a.children[0].x,a.children[0].y,a.children[0].w,a.children[0].h},[4]f32{b.children[0].x,b.children[0].y,b.children[0].w,b.children[0].h})
                }
            }
            for i in 0..<min(len(a.children),len(b.children)) do compare(a.children[i],b.children[i])
            for i in 0..<min(len(a.inlines),len(b.inlines)) {
                x,y := a.inlines[i],b.inlines[i]
                if x.kind != y.kind || x.text != y.text || x.x != y.x || x.y != y.y || x.w != y.w || x.h != y.h do g_layout_check_mismatches += 1
                compare(x.box,y.box)
            }
        }
        compare(tab.layout,ref)
        g_layout_check_runs += 1
        fmt.eprintfln("[layoutcheck] runs=%d boxes=%d mismatches=%d",g_layout_check_runs,g_layout_check_boxes,g_layout_check_mismatches)
    }
}
