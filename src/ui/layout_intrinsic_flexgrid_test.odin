package ui

import "core:testing"
import "core:strings"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// Deterministic lengths: exercise the full style/build/layout pipeline without fonts.
@(private="file")
intrinsic_geometry :: proc(html: string) -> map[string]Rect {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 800)
    result := make(map[string]Rect, context.temp_allocator)
    intrinsic_collect(root, &result)
    return result
}

@(private="file")
intrinsic_collect :: proc(b: ^Box, result: ^map[string]Rect) {
    if b == nil do return
    if b.node != nil {
        if id, ok := b.node.attrs["id"]; ok { result[strings.clone(id, context.temp_allocator)] = Rect{b.x, b.y, b.w, b.h} }
    }
    for c in b.children do intrinsic_collect(c, result)
}

@(private="file")
intrinsic_expect :: proc(t: ^testing.T, actual, expected: f32) {
    testing.expectf(t, abs(actual-expected) < 0.02, "expected %v, got %v", expected, actual)
}

@(test)
test_intrinsic_flex_auto_basis_grow :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;width:400px"><div id="a" style="flex-grow:1"><div style="width:100px;height:10px"></div></div><div id="b" style="flex-grow:1"><div style="width:200px;height:10px"></div></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 150)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 250)
}

@(test)
test_intrinsic_flex_fractional_grow :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;width:400px;justify-content:flex-end"><div id="a" style="flex:0.25 1 100px;min-width:0;height:10px"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 175)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].x, 225)
}

@(test)
test_intrinsic_flex_fractional_shrink :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;width:100px"><div id="a" style="flex:0 0.25 200px;min-width:0;height:10px"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 175)
}

@(test)
test_intrinsic_flex_wrap_hypothetical_min :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap;width:150px;align-content:flex-start"><div id="a" style="flex:1 1 0px;min-width:100px;height:10px"></div><div id="b" style="flex:1 1 0px;min-width:100px;height:10px"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 150)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 150)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].y, 10)
}

@(test)
test_intrinsic_flex_wrap_hypothetical_max :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap;width:150px"><div id="a" style="flex:0 1 200px;max-width:60px;height:10px"></div><div id="b" style="flex:0 1 200px;max-width:60px;height:10px"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 60)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 60)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].x, 60)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].y, 0)
}

@(test)
test_intrinsic_grid_fr_floor_redistributes :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:300px;grid-template-columns:minmax(200px,1fr) 1fr"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 200)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].x, 200)
}

@(test)
test_intrinsic_grid_fractional_fr :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:400px;grid-template-columns:minmax(0,0.25fr) minmax(0,0.25fr)"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].x, 100)
}

@(test)
test_intrinsic_grid_intrinsic_fr_ratio :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:max-content;grid-template-columns:1fr 2fr;gap:10px"><div id="a"><div style="width:100px;height:10px"></div></div><div id="b"><div style="width:100px;height:10px"></div></div></div></body>`)
    testing.expect(t, "g" in r)
    intrinsic_expect(t, r["g"].w, 310)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 200)
}

@(test)
test_intrinsic_grid_intrinsic_fr_span :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:max-content;grid-template-columns:1fr 2fr;gap:10px"><div id="a" style="grid-column:span 2"><div style="width:310px;height:10px"></div></div></div></body>`)
    testing.expect(t, "g" in r)
    intrinsic_expect(t, r["g"].w, 310)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 310)
}

@(test)
test_intrinsic_grid_fr_floor_with_gap :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:300px;gap:20px;grid-template-columns:minmax(200px,1fr) 2fr"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 200)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 80)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].x, 220)
}

@(test)
test_intrinsic_flex_explicit_zero_basis_control :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;width:400px"><div id="a" style="flex:1;min-width:0"><div style="width:100px;height:10px"></div></div><div id="b" style="flex:1;min-width:0"><div style="width:200px;height:10px"></div></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 200)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 200)
}

@(test)
test_intrinsic_grid_fixed_overflow_control :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:100px;grid-template-columns:200px minmax(0,1fr)"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 200)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 0)
}

@(test)
test_intrinsic_grid_row_fr_floor :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:300px;grid-template-rows:minmax(200px,1fr) 1fr"><div id="a"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].h, 200)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].h, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].y, 200)
}

@(test)
test_intrinsic_grid_row_fractional_fr :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:100px;height:400px;grid-template-rows:minmax(0,0.25fr) minmax(0,0.25fr)"><div id="a"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].h, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].h, 100)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].y, 100)
}

@(test)
test_intrinsic_grid_fr_percent_floor :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:grid;width:400px;gap:20px;grid-template-columns:minmax(75%,1fr) 1fr"><div id="a" style="height:10px"></div><div id="b"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 300)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 80)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].x, 320)
}

@(test)
test_intrinsic_flex_fractional_freeze :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;width:400px"><div id="a" style="flex:0.25 1 0px;max-width:50px;height:10px"></div><div id="b" style="flex:0.25 1 0px;height:10px"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 50)
    testing.expect(t, "b" in r)
    intrinsic_expect(t, r["b"].w, 100)
}

@(test)
test_intrinsic_flex_column_fractional_grow :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:100px;height:400px"><div id="a" style="flex:0.25 1 100px;min-height:0"></div></div></body>`)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].h, 175)
}

@(test)
test_intrinsic_flex_intrinsic_out_of_flow_gap :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div id="g" style="display:flex;width:max-content;gap:10px"><div style="width:100px;height:10px"></div><div style="position:absolute;width:200px;height:10px"></div></div></body>`)
    testing.expect(t, "g" in r)
    intrinsic_expect(t, r["g"].w, 100)
}

@(test)
test_intrinsic_grid_intrinsic_span_with_base :: proc(t: ^testing.T) {
    r := intrinsic_geometry(`<body style="margin:0"><div id="g" style="display:grid;width:max-content;grid-template-columns:1fr 2fr;gap:10px"><div style="grid-column:1"><div style="width:100px;height:10px"></div></div><div id="a" style="grid-column:span 2"><div style="width:310px;height:10px"></div></div></div></body>`)
    testing.expect(t, "g" in r)
    intrinsic_expect(t, r["g"].w, 310)
    testing.expect(t, "a" in r)
    intrinsic_expect(t, r["a"].w, 310)
}
