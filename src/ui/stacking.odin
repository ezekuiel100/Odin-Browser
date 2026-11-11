package ui

// CSS 2.2 Appendix E: contexts belong to their nearest ancestor context,
// independently of the containing block used to compute their geometry.
import im "../../vendor/imgui"

Stacking_Clip :: struct {
    min, max: im.Vec2,
    parent: int,
    box: ^Box,
}
Stacking_Entry :: struct {
    box: ^Box,
    ox, oy: f32,
    z: int,
    clip: int,
    origin: im.Vec2,
}
Stacking_Scope :: struct {
    deferred: map[^Box]bool,
    entries: [dynamic]Stacking_Entry,
    clips: [dynamic]Stacking_Clip,
}

creates_stacking_context :: proc(b: ^Box) -> bool {
    return ((b.pos != .Static || b.stacking_item) && b.z_index_set) ||
           b.pos == .Fixed || b.pos == .Sticky ||
           b.opacity < 1 || b.n_filters > 0 || b.n_backdrop > 0 ||
           b.blend_mode != .Normal || b.isolate || b.stacking_hint ||
           b.has_transform || b.has_xform_matrix ||
           b.clip_path.kind != .None || b.mask_grad.active ||
           stacking_animation_context(b)
}

// Offsets must match paint_box, including sticky and viewport-fixed boxes.
stacking_offset :: proc(b: ^Box, ox, oy: f32) -> (x, y: f32) {
    dx, dy := animation_translation_delta(b)
    x = ox + b.rel_dx + dx; y = oy + b.rel_dy + dy
    if b.pos == .Fixed {
        y += im.GetScrollY()
    } else if b.pos == .Sticky && b.inset_has[0] && !b.inset_pct[0] {
        dy := im.GetScrollY() + b.inset[0] - (b.y + y)
        if dy > 0 do y += min(dy, b.sticky_max_dy)
    }
    return
}

// Clips are stored in layout coordinates. Each deferred entry restores its
// ancestor clips even though its ancestors have already finished painting.
collect_stacking :: proc(scope: ^Stacking_Scope, b: ^Box, ox, oy: f32, clip: int, origin: im.Vec2 = {}) {
    own_clip := clip
    if b.overflow_hidden {
        big :: f32(1e6)
        own_clip = len(scope.clips)
        append(&scope.clips, Stacking_Clip{
            {b.ovf_clip_x ? b.x + ox + b.border_w[3] : -big,
             b.ovf_clip_y ? b.y + oy + b.border_w[0] : -big},
            {b.ovf_clip_x ? b.x + ox + b.w - b.border_w[1] : big,
             b.ovf_clip_y ? b.y + oy + b.h - b.border_w[2] : big}, clip, b})
    }
    child_oy := b.overflow_scroll ? oy - b.scroll_y : oy
    for child in stacking_children(b) {
        if child.inline_parent_effect != nil do continue // painted by its inline opacity scope
        cc := overflow_escapes(b, child) ? clip : own_clip
        cx, cy := ox, child_oy
        if child.pos == .Absolute { cx = origin.x; cy = origin.y }
        if child.pos == .Fixed { cx = origin.x; cy = origin.y }
        collect_stacking_child(scope, child, cx, cy, cc, origin)
    }
    for it in b.inlines {
        if it.kind == .InlineBox && it.box != nil && it.effect == nil {
            collect_stacking_child(scope, it.box, b.content_x + ox + it.x, b.content_y + child_oy + it.y, own_clip, {b.content_x + ox + it.x, b.content_y + child_oy + it.y})
        }
    }
}

collect_stacking_child :: proc(scope: ^Stacking_Scope, b: ^Box, ox, oy: f32, clip: int, origin: im.Vec2 = {}) {
    real_context := stacking_context_at(b, ox, oy)
    if real_context || b.pos != .Static {
        z := (b.pos != .Static || b.stacking_item) && b.z_index_set ? b.z_index : 0
        append(&scope.entries, Stacking_Entry{b, ox, oy, z, clip, origin})
        scope.deferred[b] = true
    }
    // auto-positioned boxes are painted atomically, but their positioned
    // descendants still participate in this scope. Explicit zero is a barrier.
    if !real_context {
        x, y := stacking_offset(b, ox, oy)
        collect_stacking(scope, b, x, y, clip, origin)
    }
}

sort_stacking :: proc(entries: []Stacking_Entry) {
    if len(entries) < 2 do return
    // Stable merge sort: a context can contain thousands of descendants.
    scratch := make([]Stacking_Entry, len(entries), context.temp_allocator)
    defer delete(scratch, context.temp_allocator)
    for width := 1; width < len(entries); width *= 2 {
        for left := 0; left < len(entries); left += 2 * width {
            mid := min(left + width, len(entries))
            right := min(left + 2 * width, len(entries))
            i, j := left, mid
            for k in left ..< right {
                if i < mid && (j >= right || entries[i].z <= entries[j].z) {
                    scratch[k] = entries[i]; i += 1
                } else {
                    scratch[k] = entries[j]; j += 1
                }
            }
        }
        copy(entries, scratch)
    }
}

paint_stacking :: proc(pt: ^Painter, s: ^State, scope: ^Stacking_Scope, negative: bool, sx, sy, eff: f32, in_xform: bool) {
    for entry in scope.entries {
        if (entry.z < 0) != negative do continue
        // Restore the same rounded clips as normal-flow children. Layers must
        // close in reverse order, even when rectangular clips are interleaved.
        opened := make([dynamic]bool, 0, 4, context.temp_allocator)
        for c := entry.clip; c >= 0; c = scope.clips[c].parent {
            rect := scope.clips[c]
            rounded := rounded_overflow_clip(rect.box)
            emit_overflow_clip(pt, rect.box, {rect.min.x + sx, rect.min.y + sy}, {rect.max.x + sx, rect.max.y + sy}, rounded)
            append(&opened, rounded)
        }
        paint_box(pt, s, entry.box, entry.ox, entry.oy, eff, in_xform, scope, true, entry.origin)
        for i := len(opened)-1; i >= 0; i -= 1 do end_overflow_clip(pt, opened[i])
    }
}

stacking_animation_context :: proc(b: ^Box) -> bool {
    for &p in b.animations {
        if !p.anim.active do continue
        for i in 0 ..< p.anim.n {
            stop := p.anim.stops[i]
            if stop.has_opacity || stop.has_rot || stop.has_scale do return true
        }
    }
    return false
}

stacking_children :: proc(b: ^Box) -> []^Box {
    if !b.is_flex && !b.is_grid do return b.children[:]
    kids := make([]^Box, len(b.children), context.temp_allocator)
    copy(kids, b.children[:])
    for i in 1 ..< len(kids) {
        key := kids[i]
        j := i - 1
        for j >= 0 && kids[j].order > key.order {
            kids[j+1] = kids[j]; j -= 1
        }
        kids[j+1] = key
    }
    return kids
}

stacking_context_at :: proc(b: ^Box, ox, oy: f32) -> bool {
    if creates_stacking_context(b) do return true
    if b.hover.active && (b.hover.has_opacity || b.hover.has_transform) {
        x, y := stacking_offset(b, ox, oy)
        im.SetCursorPos({b.x + x, b.y + y})
        p := im.GetCursorScreenPos()
        if im.IsMouseHoveringRect(p, {p.x + b.w, p.y + b.h}) && !b.pe_none {
            if b.hover.has_transform || (b.hover.has_opacity && b.hover.opacity < 1) do return true
        }
    }
    if st, ok := g_trans[b.node]; ok && st.init {
        if b.trans[.Opacity].on && st.opacity.prog < 1 && (st.opacity.start < 1 || st.opacity.tgt < 1) do return true
        if b.trans[.Transform].on && (st.rot.prog < 1 || st.sx.prog < 1 || st.sy.prog < 1) do return true
    }
    return false
}
