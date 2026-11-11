package ui

import "core:testing"
import "core:strings"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private="file")
fg_geometry :: proc(html: string) -> map[string]Rect {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 800)
    result := make(map[string]Rect, context.temp_allocator)
    fg_collect(root, &result)
    return result
}

@(private="file")
fg_collect :: proc(b: ^Box, result: ^map[string]Rect) {
    if b == nil do return
    if b.node != nil {
        if id, ok := b.node.attrs["id"]; ok { result[strings.clone(id, context.temp_allocator)] = Rect{b.x, b.y, b.w, b.h} }
    }
    for c in b.children do fg_collect(c, result)
}

@(private="file")
fg_eq :: proc(t: ^testing.T, got, want: f32) {
    testing.expectf(t, abs(got-want) < 0.02, "expected %v, got %v", want, got)
}

@(test)
fg_column_wrap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap;width:200px;height:100px;align-content:flex-start;gap:5px 10px"><div id="a" style="width:20px;height:60px"></div><div id="b" style="width:30px;height:60px"></div><div id="c" style="width:40px;height:60px"></div></div></body>`)
    fg_eq(t, r["a"].h, 60); fg_eq(t, r["b"].h, 60)
    fg_eq(t, r["b"].x, 30); fg_eq(t, r["b"].y, 0)
    fg_eq(t, r["c"].x, 70); fg_eq(t, r["c"].y, 0)
}

@(test)
fg_column_wrap_grow_per_line :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap;width:100px;height:100px;align-content:flex-start"><div id="a" style="width:20px;flex:1 1 40px"></div><div id="b" style="width:20px;flex:1 1 40px"></div><div id="c" style="width:30px;flex:1 1 40px"></div></div></body>`)
    fg_eq(t, r["a"].h, 50); fg_eq(t, r["b"].h, 50)
    fg_eq(t, r["b"].y, 50); fg_eq(t, r["c"].x, 20); fg_eq(t, r["c"].h, 100)
}

@(test)
fg_column_wrap_hypothetical_min :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap;width:100px;height:100px;align-content:flex-start"><div id="a" style="width:20px;flex:1 1 0px;min-height:60px"></div><div id="b" style="width:30px;flex:1 1 0px;min-height:60px"></div></div></body>`)
    fg_eq(t, r["a"].h, 100); fg_eq(t, r["b"].x, 20); fg_eq(t, r["b"].y, 0)
}

@(test)
fg_column_wrap_indefinite_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:flex;flex-flow:column wrap;width:100px;gap:5px 10px"><div id="a" style="width:20px;height:60px"></div><div id="b" style="width:30px;height:60px"></div></div></body>`)
    fg_eq(t, r["g"].h, 125); fg_eq(t, r["b"].x, 0); fg_eq(t, r["b"].y, 65)
}

@(test)
fg_grid_fr_automatic_min :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:1fr 1fr"><div id="a"><div style="width:200px;height:10px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].w, 200); fg_eq(t, r["b"].x, 200); fg_eq(t, r["b"].w, 0)
}

@(test)
fg_grid_fr_zero_min_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:minmax(0,1fr) 1fr"><div id="a"><div style="width:200px;height:10px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].w, 50); fg_eq(t, r["b"].w, 50)
}

@(test)
fg_grid_scroll_min_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:1fr 1fr"><div id="a" style="overflow:hidden"><div style="width:200px;height:10px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].w, 50); fg_eq(t, r["b"].w, 50)
}

// Two wrapped flex children give a font-independent min-content=100/max-content=200.
@(private="file")
fg_grid_track :: proc(track: string, width: string) -> map[string]Rect {
    return fg_geometry(strings.concatenate({`<body style="margin:0"><div id="g" style="display:grid;width:`, width, `;grid-template-columns:`, track, ` 1fr"><div id="a" style="display:flex;flex-wrap:wrap"><div style="width:100px;height:10px;flex-shrink:0"></div><div style="width:100px;height:10px;flex-shrink:0"></div></div><div id="b"></div></div></body>`}, context.temp_allocator))
}

@(test)
fg_grid_min_content_track :: proc(t: ^testing.T) {
    r := fg_grid_track("min-content", "400px")
    fg_eq(t, r["a"].w, 100); fg_eq(t, r["a"].h, 20); fg_eq(t, r["b"].w, 300)
}

@(test)
fg_grid_max_content_no_shrink :: proc(t: ^testing.T) {
    r := fg_grid_track("max-content", "120px")
    fg_eq(t, r["a"].w, 200); fg_eq(t, r["b"].w, 0)
}

@(test)
fg_grid_fit_content_cap :: proc(t: ^testing.T) {
    r := fg_grid_track("fit-content(120px)", "400px")
    fg_eq(t, r["a"].w, 120); fg_eq(t, r["b"].w, 280)
}

@(test)
fg_grid_auto_preserves_min_content :: proc(t: ^testing.T) {
    r := fg_grid_track("auto", "60px")
    fg_eq(t, r["a"].w, 100); fg_eq(t, r["b"].w, 0)
}

@(test)
fg_grid_minmax_intrinsic_min :: proc(t: ^testing.T) {
    r := fg_grid_track("minmax(max-content,1fr)", "120px")
    fg_eq(t, r["a"].w, 200); fg_eq(t, r["b"].w, 0)
}

@(test)
fg_column_wrap_reverse_direction :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column-reverse wrap;width:100px;height:100px;align-content:flex-start"><div id="a" style="width:20px;height:40px"></div><div id="b" style="width:20px;height:40px"></div><div id="c" style="width:30px;height:40px"></div></div></body>`)
    fg_eq(t, r["a"].y, 60); fg_eq(t, r["b"].y, 20)
    fg_eq(t, r["c"].x, 20); fg_eq(t, r["c"].y, 60)
}

@(test)
fg_column_wrap_stretch_lines :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap;width:100px;height:100px;column-gap:10px"><div id="a" style="height:60px"><div style="width:20px;height:5px"></div></div><div id="b" style="height:60px"><div style="width:20px;height:5px"></div></div></div></body>`)
    fg_eq(t, r["a"].w, 45); fg_eq(t, r["b"].x, 55); fg_eq(t, r["b"].w, 45)
}

@(test)
fg_column_explicit_zero_gap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;gap:0 10px"><div style="height:20px"></div><div id="b" style="height:20px"></div></div></body>`)
    fg_eq(t, r["b"].y, 20)
}

@(test)
fg_flex_ratio_transferred_min :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:60px"><div id="a" style="aspect-ratio:2;height:50px;flex:1 1 0px"></div></div></body>`)
    fg_eq(t, r["a"].w, 100)
}

@(test)
fg_flex_ratio_base :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:300px"><div id="a" style="aspect-ratio:2;height:50px"></div></div></body>`)
    fg_eq(t, r["a"].w, 100)
}

@(test)
fg_flex_ratio_specified_cap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:20px"><div id="a" style="aspect-ratio:2;height:50px;width:40px;flex-shrink:1"></div></div></body>`)
    fg_eq(t, r["a"].w, 40)
}

@(test)
fg_flex_ratio_percent_cross :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:60px;height:100px"><div id="a" style="aspect-ratio:2;height:50%;flex:1 1 0px"></div></div></body>`)
    fg_eq(t, r["a"].w, 100); fg_eq(t, r["a"].h, 50)
}

@(test)
fg_grid_row_fr_minimum :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:100px;grid-template-rows:1fr 1fr"><div id="a"><div style="height:200px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].h, 200); fg_eq(t, r["b"].y, 200); fg_eq(t, r["b"].h, 0)
}

@(test)
fg_grid_row_zero_min_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:100px;grid-template-rows:minmax(0,1fr) 1fr"><div id="a"><div style="height:200px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].h, 50); fg_eq(t, r["b"].h, 50)
}

@(test)
fg_column_wrap_reverse_cross :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap-reverse;width:100px;height:100px;align-content:flex-start;align-items:flex-start"><div id="a" style="width:20px;height:60px"></div><div id="b" style="width:30px;height:60px"></div></div></body>`)
    fg_eq(t, r["a"].x, 80); fg_eq(t, r["b"].x, 50)
}

@(test)
fg_row_reverse_wrap_collection :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:row-reverse wrap;width:100px"><div id="a" style="width:40px;height:10px"></div><div id="b" style="width:40px;height:10px"></div><div id="c" style="width:40px;height:10px"></div></div></body>`)
    fg_eq(t, r["a"].x, 60); fg_eq(t, r["b"].x, 20)
    fg_eq(t, r["c"].x, 60); fg_eq(t, r["c"].y, 10)
}

@(test)
fg_row_wrap_cross_gap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap;width:50px;gap:7px 20px"><div style="width:40px;height:10px"></div><div id="b" style="width:40px;height:10px"></div></div></body>`)
    fg_eq(t, r["b"].y, 17)
}

@(test)
fg_row_wrap_single_line_alignment :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap;width:100px;height:100px;align-content:center"><div id="a" style="width:20px;height:20px"></div></div></body>`)
    fg_eq(t, r["a"].y, 40)
}

@(test)
fg_row_wrap_stretch_and_reverse :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap-reverse;width:50px;height:100px;row-gap:10px"><div id="a" style="width:40px"><div style="height:10px"></div></div><div id="b" style="width:40px"><div style="height:10px"></div></div></div></body>`)
    fg_eq(t, r["a"].h, 45); fg_eq(t, r["a"].y, 55); fg_eq(t, r["b"].h, 45); fg_eq(t, r["b"].y, 0)
}

@(test)
fg_grid_fit_content_percentage :: proc(t: ^testing.T) {
    r := fg_grid_track("fit-content(30%)", "400px")
    fg_eq(t, r["a"].w, 120); fg_eq(t, r["b"].w, 280)
}

@(test)
fg_grid_explicit_intrinsic_min_with_scroll :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:minmax(min-content,1fr) 1fr"><div id="a" style="overflow:hidden"><div style="width:200px;height:10px"></div></div><div id="b"></div></div></body>`)
    fg_eq(t, r["a"].w, 200); fg_eq(t, r["b"].w, 0)
}

@(test)
fg_grid_span_flexible_min_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:1fr 1fr"><div id="a" style="grid-column:span 2"><div style="width:200px;height:10px"></div></div></div></body>`)
    fg_eq(t, r["a"].w, 100)
}

@(test)
fg_column_basis_content_box :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;height:100px"><div id="a" style="flex:0 0 20px;padding:10px;min-height:0"></div></div></body>`)
    fg_eq(t, r["a"].h, 40)
}

@(test)
fg_flex_ratio_box_sizing :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:10px"><div id="a" style="aspect-ratio:2;height:50px;padding:10px"></div><div id="b" style="aspect-ratio:2;height:50px;padding:10px;box-sizing:border-box"></div></div></body>`)
    fg_eq(t, r["a"].w, 120); fg_eq(t, r["b"].w, 100)
}

@(test)
fg_grid_intrinsic_zero_min :: proc(t: ^testing.T) {
    r := fg_grid_track("minmax(0,1fr)", "min-content")
    fg_eq(t, r["g"].w, 0); fg_eq(t, r["a"].w, 0)
}

@(test)
fg_grid_intrinsic_min_content :: proc(t: ^testing.T) {
    r := fg_grid_track("min-content", "max-content")
    fg_eq(t, r["g"].w, 100); fg_eq(t, r["a"].w, 100)
}

@(test)
fg_grid_intrinsic_fit_content :: proc(t: ^testing.T) {
    r := fg_grid_track("fit-content(120px)", "max-content")
    fg_eq(t, r["g"].w, 120); fg_eq(t, r["a"].w, 120)
}

@(test)
fg_row_span_shared_deficit :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:50px 50px;grid-template-rows:auto auto"><div id="span" style="grid-column:1;grid-row:1 / span 2;height:100px"></div><div id="a" style="grid-column:2;grid-row:1"></div><div id="b" style="grid-column:2;grid-row:2"></div></div></body>`)
    fg_eq(t, r["a"].h, 50); fg_eq(t, r["b"].h, 50); fg_eq(t, r["b"].y, 50)
}

@(test)
fg_cyclic_row_percentage :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:100px;grid-template-rows:50%"><div id="a" style="height:80px"></div></div></body>`)
    fg_eq(t, r["g"].h, 80)
}

@(test)
fg_first_baseline_nested :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;align-items:baseline"><div id="a" style="width:30px;height:50px"><div style="height:10px"></div></div><div id="b" style="width:30px;height:30px"></div></div></body>`)
    fg_eq(t, r["a"].y, 20); fg_eq(t, r["b"].y, 0)
}

@(test)
fg_grid_baseline_nested :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:50px 50px;align-items:baseline"><div id="a" style="height:50px"><div style="height:10px"></div></div><div id="b" style="height:30px"></div></div></body>`)
    fg_eq(t, r["a"].y, 20); fg_eq(t, r["b"].y, 0)
}

@(test)
fg_last_baseline_nested :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;align-items:last baseline"><div id="a" style="width:30px;height:50px"><div style="height:10px"></div><div style="height:10px"></div></div><div id="b" style="width:30px;height:30px"></div></div></body>`)
    fg_eq(t, r["a"].y, 10); fg_eq(t, r["b"].y, 0)
}

@(test)
fg_column_ratio_transfer :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:200px;height:40px"><div id="a" style="width:100px;aspect-ratio:2;flex:1 1 0px"><div style="height:10px"></div></div></div></body>`)
    fg_eq(t, r["a"].h, 50)
}

@(test)
fg_column_span_contribution :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:200px;grid-template-columns:auto auto"><div style="grid-column:1 / span 2;width:200px;height:10px"></div><div id="a"></div><div id="b"></div></div></body>`)
    fg_eq(t,r["a"].w,100); fg_eq(t,r["b"].w,100); fg_eq(t,r["b"].x,100)
}

@(test)
fg_column_span_fixed_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:200px;grid-template-columns:40px auto auto;column-gap:10px"><div style="grid-column:1 / span 3;width:200px;height:10px"></div><div id="a"></div><div id="b"></div><div id="c"></div></div></body>`)
    fg_eq(t,r["a"].w,40); fg_eq(t,r["b"].w,70); fg_eq(t,r["c"].w,70)
}

@(test)
fg_cyclic_percentage_gap_overflows :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:100px;row-gap:50%"><div id="a" style="height:20px"></div><div id="b" style="height:20px"></div></div></body>`)
    fg_eq(t,r["g"].h,40); fg_eq(t,r["b"].y,40)
}

@(test)
fg_indefinite_flex_percentage_gap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:flex;flex-direction:column;row-gap:50%"><div style="height:20px"></div><div id="b" style="height:20px"></div></div></body>`)
    fg_eq(t,r["g"].h,40); fg_eq(t,r["b"].y,20)
}

@(test)
fg_orthogonal_row_baseline_synthesis :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;align-items:baseline"><div id="a" style="writing-mode:vertical-rl;width:30px;height:50px"></div><div id="b" style="width:30px;height:30px"></div></div></body>`)
    fg_eq(t,r["a"].y,0); fg_eq(t,r["b"].y,20)
}

@(test)
fg_grid_horizontal_baseline :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:100px;justify-items:baseline"><div id="a" style="writing-mode:vertical-rl;width:20px;height:10px"></div><div id="b" style="writing-mode:vertical-lr;width:40px;height:10px"></div></div></body>`)
    fg_eq(t,r["a"].x,10); fg_eq(t,r["b"].x,0)
}

@(test)
fg_baseline_inline_local_coordinates :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="height:70px"></div><div style="display:flex;align-items:baseline"><div id="a" style="padding-top:10px;font-size:0"><span style="display:inline-block;width:10px;height:10px"></span></div><div id="b" style="width:10px;height:30px"></div></div></body>`)
    fg_eq(t,r["a"].y+20,r["b"].y+30)
}

@(test)
fg_grid_cyclic_child_height :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:100px;align-items:start"><div id="a" style="height:50%"><div style="height:80px"></div></div></div></body>`)
    fg_eq(t,r["g"].h,80); fg_eq(t,r["a"].h,40)
}

@(test)
fg_flex_column_percentage_height :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;height:200px"><div id="a" style="height:50%;flex-shrink:0"></div></div></body>`)
    fg_eq(t,r["a"].h,100)
}

@(test)
fg_overlapping_column_spans :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:150px;grid-template-columns:auto auto auto"><div style="grid-column:1 / span 2;grid-row:1;width:100px;height:10px"></div><div style="grid-column:2 / span 2;grid-row:2;width:100px;height:10px"></div><div id="a" style="grid-column:1;grid-row:3"></div><div id="b" style="grid-column:2;grid-row:3"></div><div id="c" style="grid-column:3;grid-row:3"></div></div></body>`)
    fg_eq(t,r["a"].w,50); fg_eq(t,r["b"].w,50); fg_eq(t,r["c"].w,50)
}

@(test)
fg_overlapping_row_spans :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:150px;grid-template-columns:50px 50px 50px;grid-template-rows:auto auto auto"><div style="grid-column:1;grid-row:1 / span 2;height:100px"></div><div style="grid-column:2;grid-row:2 / span 2;height:100px"></div><div id="a" style="grid-column:3;grid-row:1"></div><div id="b" style="grid-column:3;grid-row:2"></div><div id="c" style="grid-column:3;grid-row:3"></div></div></body>`)
    fg_eq(t,r["a"].h,50); fg_eq(t,r["b"].h,50); fg_eq(t,r["c"].h,50)
}

@(test)
fg_intrinsic_percentage_column_gap :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:max-content;grid-template-columns:50px 50px;column-gap:10%"><div></div><div id="b"></div></div></body>`)
    fg_eq(t,r["g"].w,100); fg_eq(t,r["b"].x,60)
}

@(test)
fg_grid_baseline_percentage_final_size :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:50px 50px;grid-template-rows:100px;align-items:baseline"><div id="a" style="height:50%"></div><div id="b" style="height:30px"></div></div></body>`)
    fg_eq(t,r["a"].y,0); fg_eq(t,r["b"].y,20)
}

@(test)
fg_grid_intrinsic_mixed_spans_order :: proc(t: ^testing.T) {
    for reverse in 0..<2 {
        first := `<div style="grid-column:1 / span 2;grid-row:1;width:100px;height:10px"></div>`
        second := `<div style="grid-column:2 / span 2;grid-row:2;width:100px;height:10px"></div>`
        r := fg_geometry(strings.concatenate({`<body style="margin:0"><div id="g" style="display:grid;width:max-content;grid-template-columns:20px auto auto">`, reverse==0 ? first : second, reverse==0 ? second : first, `<div id="a" style="grid-column:2;grid-row:3"></div><div id="b" style="grid-column:3;grid-row:3"></div></div></body>`},context.temp_allocator))
        fg_eq(t,r["g"].w,150); fg_eq(t,r["a"].w,80); fg_eq(t,r["b"].w,50)
    }
}

@(test)
fg_flex_cyclic_column_gap_intrinsic :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div id="g" style="display:flex;width:max-content;column-gap:10%"><div style="width:50px;height:10px"></div><div id="b" style="width:50px;height:10px"></div></div></body>`)
    fg_eq(t,r["g"].w,100); fg_eq(t,r["b"].x,50)
}

@(test)
fg_orthogonal_intrinsic_minimum :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:70px"><div id="a" style="writing-mode:vertical-rl;height:100px;line-height:0"><span style="display:inline-block;width:50px;height:100px"></span><span style="display:inline-block;width:50px;height:100px"></span></div></div></body>`)
    fg_eq(t,r["a"].w,100)
}

@(test)
fg_grid_last_baseline_percentage_final_size :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:50px 50px;grid-template-rows:100px;align-items:last baseline"><div id="a" style="height:50%"></div><div id="b" style="height:30px"></div></div></body>`)
    fg_eq(t,r["a"].y,50); fg_eq(t,r["b"].y,70)
}

@(test)
fg_flex_definite_column_gap_control :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:flex;width:100px;column-gap:10%"><div id="a" style="width:50px;height:10px;min-width:0"></div><div id="b" style="width:50px;height:10px;min-width:0"></div></div></body>`)
    fg_eq(t,r["a"].w,45); fg_eq(t,r["b"].x,55)
}

@(test)
fg_orthogonal_grid_minimum_border_box :: proc(t: ^testing.T) {
    r := fg_geometry(`<body style="margin:0"><div style="display:grid;width:70px;grid-template-columns:1fr"><div id="a" style="writing-mode:vertical-lr;height:120px;box-sizing:border-box;padding:10px;line-height:0"><span style="display:inline-block;width:50px;height:100px"></span><span style="display:inline-block;width:50px;height:100px"></span></div></div></body>`)
    fg_eq(t,r["a"].w,120)
}
