package ui

import "core:math"
import im "../../vendor/imgui"

// The image is clipped at its content edge. Resolve percentages against each
// axis of the border box, normalize overlapping radii, then subtract the inset.
Image_Rounding :: struct { rx, ry: [4]f32 }

image_rounding :: proc(w, h: f32, radius: [4]f32, pct: [4]bool, inset: [4]f32 = {}) -> Image_Rounding {
    r: Image_Rounding
    for i in 0..<4 {
        r.rx[i] = max(0, pct[i] ? radius[i] * w : radius[i])
        r.ry[i] = max(0, pct[i] ? radius[i] * h : radius[i])
    }
    // f64 avoids overflow when Tailwind's rounded-full uses ~FLT_MAX.
    scale: f64 = 1
    sums := [4]f64{f64(r.rx[0])+f64(r.rx[1]), f64(r.rx[3])+f64(r.rx[2]), f64(r.ry[0])+f64(r.ry[3]), f64(r.ry[1])+f64(r.ry[2])}
    for sum, i in sums {
        if sum > 0 do scale = min(scale, f64(i < 2 ? w : h) / sum)
    }
    for i in 0..<4 {
        r.rx[i] = max(0, f32(f64(r.rx[i]) * scale) - inset[i == 0 || i == 3 ? 3 : 1])
        r.ry[i] = max(0, f32(f64(r.ry[i]) * scale) - inset[i < 2 ? 0 : 2])
        if r.rx[i] == 0 || r.ry[i] == 0 { r.rx[i] = 0; r.ry[i] = 0 }
    }
    return r
}

image_has_rounding :: proc(r: Image_Rounding) -> bool {
    for i in 0..<4 do if r.rx[i] > 0 && r.ry[i] > 0 do return true
    return false
}

// Clockwise convex outline, intersected with the visible image rectangle. This
// keeps cover/contain and viewport clipping independent of the rounded shape.
image_round_polygon :: proc(p0, p1: im.Vec2, r: Image_Rounding, lo, hi: im.Vec2, out: ^[160]im.Vec2) -> int {
    if hi.x <= lo.x || hi.y <= lo.y do return 0
    a, b: [160]im.Vec2
    n := 0
    for i in 0..<4 {
        rx, ry := r.rx[i], r.ry[i]
        cx := i == 0 || i == 3 ? p0.x + rx : p1.x - rx
        cy := i < 2 ? p0.y + ry : p1.y - ry
        steps := rx > 0 && ry > 0 ? clamp(int(math.ceil(math.sqrt(max(rx, ry)))), 4, 32) : 0
        for k in 0..=steps {
            angle := f32(math.PI) + f32(i) * f32(math.PI/2) + (steps > 0 ? f32(k)/f32(steps) * f32(math.PI/2) : 0)
            p := im.Vec2{cx + rx * math.cos(angle), cy + ry * math.sin(angle)}
            if n == 0 || abs(p.x-a[n-1].x) + abs(p.y-a[n-1].y) > 0.001 { a[n] = p; n += 1 }
        }
    }
    if n > 1 && abs(a[0].x-a[n-1].x) + abs(a[0].y-a[n-1].y) < 0.001 do n -= 1
    // Sutherland-Hodgman: clip against left/right/top/bottom.
    for edge in 0..<4 {
        if n < 3 do return 0
        m := 0
        prev := a[n-1]
        bound := edge == 0 ? lo.x : edge == 1 ? hi.x : edge == 2 ? lo.y : hi.y
        pv := edge < 2 ? prev.x : prev.y
        pin := edge == 0 || edge == 2 ? pv >= bound : pv <= bound
        for j in 0..<n {
            cur := a[j]
            cv := edge < 2 ? cur.x : cur.y
            cin := edge == 0 || edge == 2 ? cv >= bound : cv <= bound
            if cin != pin {
                t := (bound-pv)/(cv-pv)
                b[m] = {prev.x+(cur.x-prev.x)*t, prev.y+(cur.y-prev.y)*t}; m += 1
            }
            if cin { b[m] = cur; m += 1 }
            prev = cur; pv = cv; pin = cin
        }
        a = b; n = m
    }
    // Clipping through an existing vertex can produce duplicates. Remove them
    // before ImGui builds the antialiased normals.
    m := 0
    for j in 0..<n {
        if m == 0 || abs(a[j].x-out[m-1].x) + abs(a[j].y-out[m-1].y) > 0.001 {
            out[m] = a[j]; m += 1
        }
    }
    if m > 1 && abs(out[0].x-out[m-1].x) + abs(out[0].y-out[m-1].y) < 0.001 do m -= 1
    return m
}

draw_image_rounded :: proc(dl: ^im.DrawList, tex: im.TextureID, p0, p1: im.Vec2, ix0, iy0, ix1, iy1: f32, tint: u32, cmin, cmax: im.Vec2, r: Image_Rounding) {
    if ix1 <= ix0 || iy1 <= iy0 do return
    lo := im.Vec2{max(p0.x, ix0, cmin.x), max(p0.y, iy0, cmin.y)}
    hi := im.Vec2{min(p1.x, ix1, cmax.x), min(p1.y, iy1, cmax.y)}
    points: [160]im.Vec2
    n := image_round_polygon(p0, p1, r, lo, hi, &points)
    if n < 3 do return
    im.DrawList_PushTextureID(dl, tex)
    start := int(dl.VtxBuffer.Size)
    im.DrawList_AddConvexPolyFilled(dl, &points[0], i32(n), tint)
    verts := ([^]im.DrawVert)(dl.VtxBuffer.Data)
    for i in start..<int(dl.VtxBuffer.Size) {
        verts[i].uv = {clamp((verts[i].pos.x-ix0)/(ix1-ix0), 0, 1), clamp((verts[i].pos.y-iy0)/(iy1-iy0), 0, 1)}
    }
    im.DrawList_PopTextureID(dl)
}
