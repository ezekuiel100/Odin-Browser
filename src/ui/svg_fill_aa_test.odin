package ui

import "core:testing"
import "core:fmt"
import htmlp "../html"
import dompkg "../dom"

@(private="file")
svg_aa_record :: proc(paths: string, attrs: string = "", offset: f32 = 0) -> Painter {
    doc := htmlp.parse(fmt.tprintf(`<svg viewBox="0 0 8 8" %s>%s</svg>`, attrs, paths))
    defer dompkg.free_tree(doc)
    pt: Painter
    paint_svg_node(&pt, dompkg.find_first(doc, "svg"), 0, {offset, offset}, 8, 8, 1)
    return pt
}

// Read the actual paint tape: each destination pixel must be composited once,
// including translucent edge pixels and pixels adjacent to holes.
@(private="file")
svg_aa_alpha :: proc(t: ^testing.T, pt: ^Painter, x, y: f32) -> f32 {
    result: f32 = 0
    hits := 0
    for cmd in pt.cmds {
        #partial switch v in cmd {
        case PC_RectFilled:
            if x >= v.p0.x && x < v.p1.x && y >= v.p0.y && y < v.p1.y {
                result = f32(v.col >> 24); hits += 1
            }
        case PC_RectMulti:
            if x >= v.p0.x && x < v.p1.x && y >= v.p0.y && y < v.p1.y {
                // These tests use opaque gradient stops, so all four alphas agree.
                result = f32(v.c_ul >> 24); hits += 1
            }
        }
    }
    testing.expectf(t, hits <= 1, "pixel (%v,%v) painted %v times", x, y, hits)
    return result
}

@(test)
svg_fill_aa_diagonal_and_translucent_edges :: proc(t: ^testing.T) {
    pt := svg_aa_record(`<path d="M0 0H8L0 8Z" fill="red" fill-opacity="0.5"/>`)
    defer delete(pt.cmds)
    testing.expect_value(t, svg_aa_alpha(t, &pt, 2.5, 2.5), f32(127))
    edge := svg_aa_alpha(t, &pt, 3.5, 4.5)
    testing.expectf(t, edge >= 63 && edge <= 64, "half-covered half-opaque pixel: %v", edge)
    testing.expect_value(t, svg_aa_alpha(t, &pt, 6.5, 6.5), f32(0))
}

@(test)
svg_fill_aa_holes_and_nonzero_winding :: proc(t: ^testing.T) {
    path :: `<path d="M0 0H8V8H0Z M2.5 2H6V6H2.5Z"/>`
    pt := svg_aa_record(path, `fill-rule="evenodd"`)
    defer delete(pt.cmds)
    testing.expect_value(t, svg_aa_alpha(t, &pt, 3.5, 3.5), f32(0))
    testing.expect_value(t, svg_aa_alpha(t, &pt, 1.5, 3.5), f32(255))
    edge := svg_aa_alpha(t, &pt, 2.5, 3.5)
    testing.expectf(t, edge >= 127 && edge <= 128, "hole boundary has partial coverage: %v", edge)
    nz := svg_aa_record(path, `fill-rule="nonzero"`)
    defer delete(nz.cmds)
    testing.expect_value(t, svg_aa_alpha(t, &nz, 3.5, 3.5), f32(255))
}

@(test)
svg_fill_aa_fractional_origin_and_gradient :: proc(t: ^testing.T) {
    pt := svg_aa_record(`<path d="M0 0H4V4H0Z"/>`, "", 0.25)
    defer delete(pt.cmds)
    corner := svg_aa_alpha(t, &pt, 0.5, 0.5)
    testing.expectf(t, corner >= 142 && corner <= 144, "quarter-pixel origin covers 9/16 of corner: %v", corner)
    grad := svg_aa_record(`<defs><linearGradient id="aa"><stop stop-color="red"/>
        <stop offset="1" stop-color="blue"/></linearGradient></defs>
        <path d="M0 0H8L0 8Z" fill="url(#aa)" fill-opacity="0.5"/>`)
    defer delete(grad.cmds)
    testing.expect_value(t, svg_aa_alpha(t, &grad, 2.5, 2.5), f32(127))
    edge := svg_aa_alpha(t, &grad, 3.5, 4.5)
    testing.expectf(t, edge >= 63 && edge <= 64, "gradient coverage also multiplies opacity once: %v", edge)
}

@(test)
svg_fill_aa_respects_crisp_edges :: proc(t: ^testing.T) {
    pt := svg_aa_record(`<path d="M0 0H8L0 8Z"/>`, `shape-rendering="crispEdges"`)
    defer delete(pt.cmds)
    for cmd in pt.cmds {
        if v, ok := cmd.(PC_RectFilled); ok do testing.expect_value(t, v.col >> 24, u32(255))
    }
}
