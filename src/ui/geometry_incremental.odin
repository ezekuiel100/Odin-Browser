package ui

// Disable only subtree geometry reuse for controlled A/B runs. The same box
// builder, styles, layout algorithms and root cache are used in both versions.
GEOMETRY_REUSE :: #config(GEOMETRY_REUSE, true)

Geometry_Environment :: struct {
    w, h, viewport_w, viewport_h, zoom: f32,
    resources: u64,
    dark: bool,
}

Geometry_Inputs :: struct {
    constraints: [4]f32, // available width, imposed width/height, containing height
    sizes: [6]f32,      // parent-resolved limits can change without a style change
    edges: [12]f32,
    has_sizes: [6]bool,
}

Geometry_Memo :: struct {
    valid, safe: bool,
    translate_integral: [2]bool,
    environment: Geometry_Environment,
    inputs: Geometry_Inputs,
    size: [3]f32,
    content_offset, origin_offset: [2]f32,
    boxes: int,
}

Geometry_Stats :: struct {
    requests, reflowed, hits, skipped_boxes: int,
}

Geometry_Pass :: struct {
    environment: Geometry_Environment,
    reuse, record: bool,
    stats: Geometry_Stats,
}
@(thread_local) g_geometry_pass: ^Geometry_Pass

geometry_environment :: proc(w, h: f32) -> Geometry_Environment {
    return {w=w,h=h,viewport_w=g_viewport_w,viewport_h=g_viewport_h,zoom=g_zoom,
            resources=g_geometry_resources,dark=g_prefers_dark}
}

geometry_inputs :: proc(b: ^Box, avail_w, force_w, force_h, cb_h: f32) -> Geometry_Inputs {
    return {
        constraints={avail_w,force_w,force_h,cb_h},
        sizes={b.width,b.height,b.minw,b.maxw,b.minh,b.maxh},
        has_sizes={b.has_width,b.has_height,b.has_minw,b.has_maxw,b.has_minh,b.has_maxh},
        edges={b.margin[0],b.margin[1],b.margin[2],b.margin[3],
               b.padding[0],b.padding[1],b.padding[2],b.padding[3],
               b.border_w[0],b.border_w[1],b.border_w[2],b.border_w[3]},
    }
}

// A transferred tree is clean, but its parent may supply different constraints
// or have resized the box after its last call (flex stretch, for example).
// Compare values directly: a hash collision must never hide necessary layout.
geometry_try_reuse :: proc(b: ^Box, inputs: Geometry_Inputs, x, y: f32) -> (hit: bool, dx, dy: f32) {
    p := g_geometry_pass
    if p == nil { b.geometry_memo.valid = false; return }
    p.stats.requests += 1
    m := &b.geometry_memo
    size := [3]f32{b.w,b.h,b.content_w}
    offset := [2]f32{b.content_x-b.x,b.content_y-b.y}
    if GEOMETRY_REUSE && p.reuse && p.record && b.geometry_retained && m.valid && m.safe &&
       m.environment == p.environment && m.inputs == inputs &&
       m.size == size && m.content_offset == offset {
        target := [2]f32{x+m.origin_offset[0],y+m.origin_offset[1]}
        origin := [2]f32{b.x,b.y}
        for axis in 0 ..< 2 {
            // Repeated fractional additions can drift from a fresh f32 layout.
            // Stationary results remain reusable; moving axes require exact,
            // bounded integral geometry throughout the translated subtree.
            if target[axis] != origin[axis] && !(m.translate_integral[axis] &&
                geometry_integral(target[axis]) && geometry_integral_axis(b,axis)) {
                p.stats.reflowed += 1
                return
            }
        }
        p.stats.hits += 1
        p.stats.skipped_boxes += m.boxes
        return true, target[0]-b.x, target[1]-b.y
    }
    p.stats.reflowed += 1
    return
}

geometry_integral :: proc(v: f32) -> bool {
    // The bound leaves headroom for exact integer additions in f32. Test the
    // range first, so infinities/NaNs are never converted to an integer.
    return abs(v) <= 1_000_000 && v == f32(i32(v))
}

geometry_integral_axis :: proc(b: ^Box, axis: int) -> bool {
    if len(b.inlines) > 0 do return false // font/baseline arithmetic is fractional
    if axis == 0 {
        if !geometry_integral(b.x) || !geometry_integral(b.content_x) || !geometry_integral(b.w) || !geometry_integral(b.content_w) do return false
    } else {
        if !geometry_integral(b.y) || !geometry_integral(b.content_y) || !geometry_integral(b.h) do return false
    }
    for side := axis == 0 ? 1 : 0; side < 4; side += 2 {
        if !geometry_integral(b.margin[side]) || !geometry_integral(b.padding[side]) || !geometry_integral(b.border_w[side]) do return false
    }
    if b.is_flex || b.is_grid do return geometry_integral(axis == 0 ? b.gap : b.row_gap)
    return true
}

// These layouts have additional parent-owned state or external positioning.
// Their own geometry stays conservative; independent safe descendants/siblings
// can still reuse their geometry when reached with unchanged inputs.
geometry_safe_box :: proc(b: ^Box) -> bool {
    return b.pos != .Absolute && b.pos != .Fixed && !b.reparented &&
           b.float == .None && !b.is_table && !b.is_multicol &&
           b.writing_mode == .Horizontal && !b.grid_sub_cols && !b.grid_sub_rows &&
           !b.container_inline && !b.has_offset_path
}

geometry_store :: proc(b: ^Box, inputs: Geometry_Inputs, x, y: f32) {
    p := g_geometry_pass
    if p == nil || !p.record { b.geometry_memo = {}; return }
    safe := geometry_safe_box(b)
    integral := [2]bool{geometry_integral_axis(b,0),geometry_integral_axis(b,1)}
    count := 1
    for c in b.children {
        safe = safe && c.geometry_memo.safe
        count += c.geometry_memo.boxes
        for axis in 0 ..< 2 do integral[axis] = integral[axis] && c.geometry_memo.translate_integral[axis] && geometry_integral_axis(c,axis)
    }
    for it in b.inlines do if it.box != nil {
        // Inline atoms use local coordinates and are not translated with b.
        safe = safe && it.box.geometry_memo.safe
        count += it.box.geometry_memo.boxes
    }
    b.geometry_memo = {
        valid=true,safe=safe,translate_integral=integral,environment=p.environment,inputs=inputs,
        size={b.w,b.h,b.content_w},
        content_offset={b.content_x-b.x,b.content_y-b.y},
        origin_offset={b.x-x,b.y-y},boxes=count,
    }
}

geometry_inherit :: proc(root, old: ^Box) {
    if root == nil || old == nil || !old.geometry_valid do return
    root.geometry_environment = old.geometry_environment
    root.geometry_incremental = true
}
