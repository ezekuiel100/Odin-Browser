package ui

import im "../../vendor/imgui"
import dompkg "../dom"

// Inline elements keep word-level wrapping. Their paint scopes survive flattening
// and word splitting, so overlapping descendants are composited as one group.
Inline_Effect :: struct {
    parent: ^Inline_Effect,
    absolutes: [dynamic]^Box, // borrowed; boxes remain owned by the layout tree
    node: ^dompkg.Node,
    opacity, hover_opacity: f32,
    has_hover, hovering: bool,
}


inline_effect_child :: proc(effect, parent: ^Inline_Effect) -> ^Inline_Effect {
    if effect == parent do return nil
    current := effect
    for current != nil && current.parent != parent do current = current.parent
    return current
}

inline_effect_alpha :: proc(effect: ^Inline_Effect) -> f32 {
    return effect.has_hover && effect.hovering ? effect.hover_opacity : effect.opacity
}

paint_inline :: proc(pt: ^Painter, s: ^State, b: ^Box, ox, oy: f32, opa: f32 = 1,
                     over_color: u32 = 0, over_t: f32 = 0, in_xform := false,
                     box_deco: Deco = {}, box_deco_on := false, scope: ^Stacking_Scope = nil) {
    for effect in b.inline_effects {
        effect.hovering = false
        if !effect.has_hover do continue
        im.SetCursorPos({b.content_x + ox, b.content_y + oy})
        cs := im.GetCursorScreenPos()
        for it in b.inlines {
            if it.hidden || it.invisible do continue
            for e := it.effect; e != nil; e = e.parent {
                if e == effect && x_mouse_rect(b,
                    {cs.x + it.x, cs.y + it.y}, {cs.x + it.x + it.w, cs.y + it.y + it.h}) {
                    effect.hovering = true
                }
            }
        }
    }
    paint_inline_scope(pt, s, b, ox, oy, opa, over_color, over_t, in_xform,
                       box_deco, box_deco_on, scope, nil)
}

paint_inline_scope :: proc(pt: ^Painter, s: ^State, b: ^Box, ox, oy, opa: f32,
                           over_color: u32, over_t: f32, in_xform: bool,
                           box_deco: Deco, box_deco_on: bool, scope: ^Stacking_Scope,
                           parent: ^Inline_Effect) {
    // Fast path for the overwhelmingly common line without opacity scopes.
    has_effect := false
    for it in b.inlines do if it.effect != parent { has_effect = true; break }
    if !has_effect {
        paint_inline_content(pt, s, b, ox, oy, opa, over_color, over_t,
                             in_xform, box_deco, box_deco_on, scope)
        paint_inline_scope_absolutes(pt, s, parent, ox, oy, opa, in_xform, scope)
        return
    }
    for i := 0; i < len(b.inlines); {
        effect := inline_effect_child(b.inlines[i].effect, parent)
        j := i + 1
        for j < len(b.inlines) && inline_effect_child(b.inlines[j].effect, parent) == effect do j += 1
        part := b^
        part.inlines = make([dynamic]Inline_Item, j-i, context.temp_allocator)
        copy(part.inlines[:], b.inlines[i:j])
        if effect == nil {
            paint_inline_content(pt, s, &part, ox, oy, opa, over_color, over_t,
                                 in_xform, box_deco, box_deco_on, scope)
        } else if alpha := inline_effect_alpha(effect); alpha > 0 {
            if alpha < 1 do emit(pt, PC_LayerBegin{opacity = alpha, node = rawptr(effect.node)})
            paint_inline_scope(pt, s, &part, ox, oy, opa, over_color, over_t,
                               in_xform, box_deco, box_deco_on, scope, effect)
            if alpha < 1 do emit(pt, PC_LayerEnd{})
        }
        delete(part.inlines)
        i = j
    }
    paint_inline_scope_absolutes(pt, s, parent, ox, oy, opa, in_xform, scope)
}

paint_inline_absolute :: proc(pt: ^Painter, s: ^State, b: ^Box, effect: ^Inline_Effect,
                              ox, oy, opa: f32, in_xform: bool, scope: ^Stacking_Scope,
                              stacked: bool, abs_origin: im.Vec2) {
    if effect == nil {
        paint_box(pt, s, b, ox, oy, opa, in_xform, scope, stacked, abs_origin)
        return
    }
    alpha := inline_effect_alpha(effect)
    if alpha <= 0 do return
    if alpha < 1 do emit(pt, PC_LayerBegin{opacity = alpha, node = rawptr(effect.node)})
    paint_inline_absolute(pt, s, b, effect.parent, ox, oy, opa, in_xform, scope, stacked, abs_origin)
    if alpha < 1 do emit(pt, PC_LayerEnd{})
}

// Positioned descendants belong to the same opacity group, including overlap
// with the inline background. They must not be composited a second time outside it.
paint_inline_scope_absolutes :: proc(pt: ^Painter, s: ^State, effect: ^Inline_Effect,
                                     ox, oy, opa: f32, in_xform: bool, scope: ^Stacking_Scope) {
    if effect == nil do return
    for child in effect.absolutes {
        child.inline_parent_effect = nil
        paint_box(pt, s, child, ox, oy, opa, in_xform, scope, true)
        child.inline_parent_effect = effect
    }
}
