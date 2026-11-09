package ui

import "core:math"
import im "../../vendor/imgui"

// A single ring: sides meet at shared vertices, never overlap translucent ink.
// Inner corner ellipses account for the two adjacent border widths separately.
paint_border_ring :: proc(dl: ^im.DrawList, p: im.Vec2, b: ^Box, cols: [4]u32, eff, radius: f32, flags: im.DrawFlags) {
    w, h := b.w, b.h
    if w <= 0 || h <= 0 do return
    t, r, bot, l := b.border_w[0], b.border_w[1], b.border_w[2], b.border_w[3]
    // Collapse the inner rectangle without reversing its edges.
    sx := min(1, w / max(l + r, 0.001))
    sy := min(1, h / max(t + bot, 0.001))
    l *= sx; r *= sx; t *= sy; bot *= sy
    rad := min(radius, min(w, h) * 0.5)
    bits := [4]im.DrawFlags{im.DrawFlags_RoundCornersTopLeft, im.DrawFlags_RoundCornersTopRight, im.DrawFlags_RoundCornersBottomRight, im.DrawFlags_RoundCornersBottomLeft}
    outer: [100]im.Vec2
    inner: [100]im.Vec2
    colors: [100]u32
    n := 0
    // Clockwise corners, 24 segments each; index 12 is the color join.
    for c in 0 ..< 4 {
        cr := rad
        if flags != 0 && flags & bits[c] == 0 do cr = 0
        left := c == 0 || c == 3
        top := c < 2
        bx := left ? l : r
        by := top ? t : bot
        rx := max(0, cr - bx); ry := max(0, cr - by)
        cx := left ? cr : w - cr
        cy := top ? cr : h - cr
        ix := left ? l + rx : w - r - rx
        iy := top ? t + ry : h - bot - ry
        count := cr > 0 ? 25 : 1
        for sample in 0 ..< count {
            j := cr > 0 ? sample : 24
            a := (f32(c) * 90 + 180 + f32(j) * 3.75) * (math.PI / 180)
            co, si := math.cos(a), math.sin(a)
            outer[n] = {p.x + cx + cr * co, p.y + cy + cr * si}
            inner[n] = {p.x + ix + rx * co, p.y + iy + ry * si}
            side := j < 12 ? (c + 3) % 4 : c
            colors[n] = col_o(cols[side], eff)
            n += 1
        }
    }
    uv := im.GetFontTexUvWhitePixel()
    im.DrawList_PrimReserve(dl, i32(n * 6), i32(n * 4))
    for i in 0 ..< n {
        j := (i + 1) % n
        idx := u32(dl._VtxCurrentIdx)
        im.DrawList_PrimWriteVtx(dl, outer[i], uv, colors[i])
        im.DrawList_PrimWriteVtx(dl, outer[j], uv, colors[i])
        im.DrawList_PrimWriteVtx(dl, inner[j], uv, colors[i])
        im.DrawList_PrimWriteVtx(dl, inner[i], uv, colors[i])
        indices := [6]u32{0, 1, 2, 0, 2, 3}
        for k in indices do im.DrawList_PrimWriteIdx(dl, im.DrawIdx(idx + k))
    }
}
