package ui

import "core:testing"
import "core:strings"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// Full parser/style/layout regressions with exact, font-independent geometry.
@(private="file")
fga_geometry :: proc(markup: string) -> map[string]Rect {
    dom := htmlp.parse(markup)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 800)
    result := make(map[string]Rect, context.temp_allocator)
    fga_collect(root, &result)
    return result
}

@(private="file")
fga_collect :: proc(b: ^Box, result: ^map[string]Rect) {
    if b == nil do return
    if b.node != nil {
        if id, ok := b.node.attrs["id"]; ok { result[strings.clone(id, context.temp_allocator)] = Rect{b.x,b.y,b.w,b.h} }
    }
    for c in b.children do fga_collect(c, result)
}

@(private="file")
fga_eq :: proc(t: ^testing.T, got, want: f32) {
    testing.expectf(t, abs(got-want) < 0.02, "expected %v, got %v", want, got)
}

@(test)
fga_flex_shrink_uses_inner_row_basis :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px"><div id="a" style="flex:0 1 100px;min-width:0;padding:0 50px;height:10px"></div><div id="b" style="flex:0 1 100px;min-width:0;height:10px"></div></div></body>`)
    fga_eq(t,r["a"].w,150); fga_eq(t,r["b"].w,50); fga_eq(t,r["b"].x,150)
}

@(test)
fga_flex_shrink_uses_inner_column_basis :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:100px;height:200px"><div id="a" style="flex:0 1 100px;min-height:0;padding:50px 0"></div><div id="b" style="flex:0 1 100px;min-height:0"></div></div></body>`)
    fga_eq(t,r["a"].h,150); fga_eq(t,r["b"].h,50); fga_eq(t,r["b"].y,150)
}

@(test)
fga_flex_shrink_border_box_and_padding_floor :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:150px"><div id="a" style="box-sizing:border-box;flex:0 1 100px;min-width:0;padding:0 20px;height:10px"></div><div id="b" style="flex:0 1 100px;min-width:0;height:10px"></div></div><div style="display:flex;width:50px"><div id="floor" style="box-sizing:border-box;flex:0 1 0px;min-width:0;padding:0 40px;height:10px"></div><div id="after" style="width:10px;height:10px;flex:none"></div></div></body>`)
    fga_eq(t,r["a"].w,81.25); fga_eq(t,r["b"].w,68.75)
    fga_eq(t,r["floor"].w,80); fga_eq(t,r["after"].x,80)
}

@(test)
fga_flex_column_main_auto_margins :: proc(t: ^testing.T) {
    for reverse in 0 ..< 2 {
        dir := reverse == 1 ? "column-reverse" : "column"
        r := fga_geometry(strings.concatenate({`<body style="margin:0"><div style="display:flex;flex-direction:`,dir,`;width:100px;height:200px;justify-content:center;gap:10px"><div id="a" style="height:20px;flex:none"></div><div id="b" style="height:30px;flex:none;margin-top:auto"></div></div></body>`},context.temp_allocator))
        fga_eq(t,r["a"].y,reverse == 1 ? 180 : 0)
        fga_eq(t,r["b"].y,reverse == 1 ? 140 : 170)
    }
}

@(test)
fga_flex_row_cross_auto_margins :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px;height:100px;align-items:center"><div id="a" style="width:20px;height:20px;margin-top:auto"></div><div id="b" style="width:20px;height:20px;margin-bottom:auto"></div><div id="c" style="width:20px;height:20px;margin:auto 0"></div><div id="d" style="width:20px;margin-top:auto"><div style="height:30px"></div></div></div></body>`)
    fga_eq(t,r["a"].y,80); fga_eq(t,r["b"].y,0); fga_eq(t,r["c"].y,40)
    fga_eq(t,r["d"].y,70); fga_eq(t,r["d"].h,30)
}

@(test)
fga_flex_column_cross_auto_margins :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:200px;height:100px"><div id="a" style="width:20px;height:10px;margin-left:auto"></div><div id="b" style="width:20px;height:10px;margin-right:auto"></div><div id="c" style="height:10px;margin:0 auto"><div style="width:40px"></div></div></div></body>`)
    fga_eq(t,r["a"].x,180); fga_eq(t,r["b"].x,0)
    fga_eq(t,r["c"].x,80); fga_eq(t,r["c"].w,40)
}

@(test)
fga_flex_stretch_can_shrink_cross_size :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:100px;height:40px"><div id="a" style="width:20px"><div style="height:100px"></div></div><div id="b" style="width:20px;min-height:60px"><div style="height:100px"></div></div></div></body>`)
    fga_eq(t,r["a"].h,40); fga_eq(t,r["b"].h,60)
}

@(test)
fga_grid_maximize_columns_freezes_growth_limits :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:240px;grid-template-columns:minmax(20px,60px) minmax(80px,300px)"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    fga_eq(t,r["a"].w,60); fga_eq(t,r["b"].w,180); fga_eq(t,r["b"].x,60)
}

@(test)
fga_grid_maximize_rows_freezes_growth_limits :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:240px;grid-template-rows:minmax(20px,60px) minmax(80px,300px)"><div id="a"></div><div id="b"></div></div></body>`)
    fga_eq(t,r["a"].h,60); fga_eq(t,r["b"].h,180); fga_eq(t,r["b"].y,60)
}

@(test)
fga_grid_only_auto_maxima_stretch :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:200px;height:200px;grid-template-columns:min-content auto;grid-template-rows:min-content auto"><div id="a"><div style="width:20px;height:30px"></div></div><div></div><div></div><div id="b"></div></div></body>`)
    fga_eq(t,r["a"].w,20); fga_eq(t,r["a"].h,30)
    fga_eq(t,r["b"].x,20); fga_eq(t,r["b"].w,180)
    fga_eq(t,r["b"].y,30); fga_eq(t,r["b"].h,170)
}

@(test)
fga_grid_item_margin_box_alignment :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:200px;height:100px"><div id="a" style="margin:10px 20px"></div></div><div style="display:grid;width:200px;height:100px;justify-items:end;align-items:center"><div id="b" style="width:40px;height:20px;margin:10px 20px"></div></div></body>`)
    fga_eq(t,r["a"].x,20); fga_eq(t,r["a"].y,10); fga_eq(t,r["a"].w,160); fga_eq(t,r["a"].h,80)
    fga_eq(t,r["b"].x,140); fga_eq(t,r["b"].y,140)
}

@(test)
fga_grid_auto_margins_precede_alignment :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:200px;height:100px;justify-items:start;align-items:end"><div id="a" style="width:40px;height:20px;margin:auto"></div></div><div style="display:grid;width:200px;height:100px"><div id="b" style="margin-left:auto;margin-top:auto"><div style="width:30px;height:10px"></div></div></div></body>`)
    fga_eq(t,r["a"].x,80); fga_eq(t,r["a"].y,40)
    fga_eq(t,r["b"].x,170); fga_eq(t,r["b"].y,190); fga_eq(t,r["b"].w,30); fga_eq(t,r["b"].h,10)
}

@(test)
fga_flex_fractional_shrink_and_freeze_with_padding :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px"><div id="a" style="flex:0 .25 100px;min-width:0;padding:0 50px;height:10px"></div><div id="b" style="flex:0 .25 100px;min-width:0;height:10px"></div></div><div style="display:flex;width:200px"><div id="c" style="flex:0 1 200px;min-width:180px;box-sizing:border-box;padding:0 50px;height:10px"></div><div id="d" style="flex:0 1 100px;min-width:0;height:10px"></div></div></body>`)
    fga_eq(t,r["a"].w,175); fga_eq(t,r["b"].w,75)
    fga_eq(t,r["c"].w,180); fga_eq(t,r["d"].w,20)
}

@(test)
fga_flex_percentage_edges_use_container_width :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px"><div id="a" style="flex:0 1 100px;min-width:0;padding:0 10%;height:10px"></div><div id="b" style="flex:0 1 100px;min-width:0;height:10px"></div></div><div style="display:flex;flex-direction:column;width:200px;height:200px"><div id="c" style="flex:0 1 100px;min-height:0;padding:5% 0"></div><div id="d" style="flex:0 1 100px;min-height:0"></div></div></body>`)
    fga_eq(t,r["a"].w,120); fga_eq(t,r["b"].w,80); fga_eq(t,r["b"].x,120)
    fga_eq(t,r["c"].h,110); fga_eq(t,r["d"].h,90)
}

@(test)
fga_flex_wrapped_column_auto_margins_are_per_line :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;flex-flow:column wrap;width:100px;height:100px;align-content:flex-start"><div id="a" style="width:20px;height:60px;margin-top:auto"></div><div id="b" style="width:30px;height:60px;margin-top:auto"></div></div></body>`)
    fga_eq(t,r["a"].y,40); fga_eq(t,r["b"].x,20); fga_eq(t,r["b"].y,40)
}

@(test)
fga_flex_auto_cross_overflow_and_baseline :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px;height:100px;align-items:center"><div id="a" style="width:20px;height:140px;margin-top:auto"></div><div id="b" style="width:20px;height:140px;margin-bottom:auto"></div></div><div style="display:flex;width:200px;height:100px;align-items:baseline"><div id="c" style="width:20px;height:20px"></div><div id="d" style="width:20px;height:80px;margin-top:auto"></div></div></body>`)
    fga_eq(t,r["a"].y,0); fga_eq(t,r["b"].y,0)
    fga_eq(t,r["c"].y,100); fga_eq(t,r["d"].y,120)
}

@(test)
fga_grid_intrinsic_maxima_grow_equally :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:240px;grid-template-columns:auto auto"><div id="a" style="display:flex;flex-wrap:wrap"><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div></div><div id="b" style="display:flex;flex-wrap:wrap"><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div><div style="width:50px;height:10px;flex:none"></div></div></div></body>`)
    fga_eq(t,r["a"].w,100); fga_eq(t,r["b"].w,140); fga_eq(t,r["b"].x,100)
}

@(test)
fga_grid_fixed_percent_maxima_and_gaps :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:250px;column-gap:10px;grid-template-columns:minmax(20px,60px) minmax(80px,300px)"><div id="a" style="height:10px"></div><div id="b"></div></div><div style="display:grid;width:200px;height:200px;grid-template-columns:minmax(20px,30%) minmax(0,80%);grid-template-rows:minmax(20px,30%) minmax(0,80%)"><div id="c"></div><div></div><div></div><div id="d"></div></div></body>`)
    fga_eq(t,r["a"].w,60); fga_eq(t,r["b"].w,180); fga_eq(t,r["b"].x,70)
    fga_eq(t,r["c"].w,60); fga_eq(t,r["c"].h,60)
    fga_eq(t,r["d"].w,140); fga_eq(t,r["d"].h,140); fga_eq(t,r["d"].y,70)
}

@(test)
fga_grid_intrinsic_rows_with_zero_minimum :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:100px;grid-template-columns:50px 50px;grid-template-rows:minmax(0,1fr) minmax(0,2fr);row-gap:10px"><div style="grid-column:1;grid-row:1 / span 2"><div style="height:310px"></div></div><div id="a" style="grid-column:2;grid-row:1"></div><div id="b" style="grid-column:2;grid-row:2"></div></div></body>`)
    fga_eq(t,r["g"].h,310); fga_eq(t,r["a"].h,100); fga_eq(t,r["b"].h,200); fga_eq(t,r["b"].y,110)
}

@(test)
fga_grid_place_content_start_disables_stretch :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:200px;height:100px;place-content:start;grid-template-columns:auto auto;grid-template-rows:auto auto"><div style="width:20px;height:10px"></div><div></div><div></div><div id="a"></div></div><div style="display:grid;width:200px;height:100px;grid-template-rows:fit-content(50px) auto;grid-template-columns:fit-content(50px) auto"><div id="b"><div style="width:20px;height:10px"></div></div><div></div><div></div><div id="c"></div></div></body>`)
    fga_eq(t,r["a"].x,20); fga_eq(t,r["a"].y,10); fga_eq(t,r["a"].w,0); fga_eq(t,r["a"].h,0)
    fga_eq(t,r["b"].w,20); fga_eq(t,r["b"].h,10)
    fga_eq(t,r["c"].w,180); fga_eq(t,r["c"].h,90)
}

@(test)
fga_grid_auto_margins_overflow_at_start :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:50px;grid-template-columns:100px;grid-template-rows:50px;align-items:end;justify-items:center"><div id="a" style="width:150px;height:80px;margin:auto"></div></div></body>`)
    fga_eq(t,r["a"].x,0); fga_eq(t,r["a"].y,0); fga_eq(t,r["a"].w,150); fga_eq(t,r["a"].h,80)
}

@(test)
fga_flex_column_empty_content_minimum_control :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:100px;height:150px"><div id="a" style="height:100px;padding:50px 0"></div></div></body>`)
    // Empty content does not make the preferred content height an automatic floor.
    fga_eq(t,r["a"].h,150)
}

@(test)
fga_flex_stretch_reflows_height_dependent_contents :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;width:200px;height:80px"><div style="width:100px"><div id="a" style="height:50%;padding:0"></div></div><div style="display:flex;width:100px;align-items:center"><div id="b" style="width:20px;height:20px"></div></div></div></body>`)
    fga_eq(t,r["a"].h,40); fga_eq(t,r["b"].y,30)
}

@(test)
fga_flex_definite_stretch_has_linear_layout_calls :: proc(t: ^testing.T) {
    markup := strings.builder_make(context.temp_allocator)
    strings.write_string(&markup,`<body style="margin:0"><div style="display:flex;width:200px;height:100px">`)
    for _ in 0 ..< 20 do strings.write_string(&markup,`<div style="display:flex;flex:1">`)
    strings.write_string(&markup,`<div id="a" style="width:20px;height:10px;align-self:center"></div>`)
    for _ in 0 ..< 21 do strings.write_string(&markup,`</div>`)
    strings.write_string(&markup,`</body>`)
    r := fga_geometry(strings.to_string(markup))
    fga_eq(t,r["a"].y,45)
    testing.expectf(t,g_layout_calls < 200,"nested definite stretch performed %v layout calls",g_layout_calls)
}

@(test)
fga_flex_column_cross_margins_affect_natural_basis :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:100px;height:100px"><div id="a" style="display:flex;flex-wrap:wrap;flex:none;margin:0 10px"><div style="width:50px;height:20px;flex:none"></div><div style="width:50px;height:20px;flex:none"></div></div><div id="b" style="height:60px;flex:none"></div></div></body>`)
    fga_eq(t,r["a"].x,10); fga_eq(t,r["a"].w,80); fga_eq(t,r["a"].h,40); fga_eq(t,r["b"].y,40)
}

@(test)
fga_grid_percentage_edges_use_grid_area :: proc(t: ^testing.T) {
    r := fga_geometry(`<body style="margin:0"><div style="display:grid;width:200px;height:100px;grid-template-columns:100px 100px;grid-template-rows:100px"><div id="a" style="margin:10%;padding:10%"><div id="b" style="width:50%;height:50%"></div></div></div></body>`)
    fga_eq(t,r["a"].x,10); fga_eq(t,r["a"].y,10); fga_eq(t,r["a"].w,80); fga_eq(t,r["a"].h,80)
    fga_eq(t,r["b"].w,30); fga_eq(t,r["b"].h,30)
}
