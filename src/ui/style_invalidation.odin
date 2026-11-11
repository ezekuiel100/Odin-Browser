package ui

import "core:reflect"
import "core:strings"
import dom "../dom"
import css "../css"

// Mark the changed subtree (selectors and inherited values can affect any
// descendant), plus its path to the root so variables are reconstructed by
// the ordinary cascade. Unchanged sibling subtrees keep their Computed values.
mark_style_subtree :: proc(n: ^dom.Node, dirty: ^map[^dom.Node]bool) {
    dirty[n] = true
    for c in n.children do mark_style_subtree(c, dirty)
}

plan_style_invalidation :: proc(n: ^dom.Node, old: map[^dom.Node]Computed, dirty: ^map[^dom.Node]bool) -> bool {
    c, ok := old[n]
    // Structural edits can invalidate nth/empty, counters, and layout inputs.
    if !ok || c.style_kids_ver != n.kids_ver do return false
    if c.counter_reset_raw != "" || c.counter_increment_raw != "" || c.counter_set_raw != "" || c.quotes_raw != "" do return false
    if c.before != nil && c.before.content_has_counter do return false
    if c.after != nil && c.after.content_has_counter do return false
    if c.style_fp != dom.style_fingerprint(n) {
        // Text can change dir=auto on ancestors and their other descendants.
        if n.kind != .Element do return false
        mark_style_subtree(n, dirty)
        for p := n.parent; p != nil; p = p.parent do dirty[p] = true
    }
    for child in n.children do if !plan_style_invalidation(child, old, dirty) do return false
    return true
}

// These selectors have dependencies outside the changed subtree. Until a
// reverse dependency index exists, use the full cascade for such sheets.
selector_cross_dependencies :: proc(s: css.Selector) -> bool {
    for c in s.combs do if c == .Adjacent || c == .Sibling do return true
    for p in s.parts {
        if len(p.has) > 0 || len(p.nth_filter) > 0 || p.empty_req || p.dir_req != .None do return true
        for q in p.nots do if selector_cross_dependencies(q) do return true
        for q in p.ors do if selector_cross_dependencies(q) do return true
    }
    return false
}

style_cross_dependencies :: proc(rules: []css.Rule) -> bool {
    for r in rules {
        if r.cq_active do return true
        for s in r.selectors do if selector_cross_dependencies(s) do return true
        for prop, val in r.decls {
            if strings.has_prefix(prop, "counter-") || strings.contains(val, "counter(") ||
                strings.contains(val, "counters(") || prop == "quotes" { return true }
        }
    }
    return false
}

reuse_style_subtree :: proc(n: ^dom.Node, old: map[^dom.Node]Computed, fresh: ^map[^dom.Node]Computed) {
    fresh[n] = old[n]
    for c in n.children do reuse_style_subtree(c, old, fresh)
}

// Deliberately small paint whitelist: every other field, including new fields
// added to Computed, conservatively requires layout. Compare fields rather
// than raw bytes (padding and owned pointer addresses are not CSS values).
styles_paint_only :: proc(old, fresh: map[^dom.Node]Computed, dirty: map[^dom.Node]bool) -> bool {
    for n in dirty {
        a, ok := old[n]
        if !ok do return false
        b := fresh[n]
        if a.style_layout_fp != b.style_layout_fp do return false
        a.style_fp = b.style_fp
        a.bg = b.bg; a.has_bg = b.has_bg; a.bg_canvas = b.bg_canvas
        a.opacity = b.opacity; a.cursor = b.cursor
        if !reflect.equal(a, b, true) do return false
    }
    return true
}

paint_changed :: proc(a, b: Computed) -> bool {
    return a.bg != b.bg || a.has_bg != b.has_bg || a.bg_canvas != b.bg_canvas || a.opacity != b.opacity || a.cursor != b.cursor
}

// Inline elements can be represented by text runs/effect records instead of
// boxes. Keep their existing layout path until those records can be patched.
paint_boxes_available :: proc(root: ^Box, old, fresh: map[^dom.Node]Computed, dirty: map[^dom.Node]bool) -> bool {
    counts := make(map[^dom.Node]int, context.temp_allocator)
    count :: proc(b: ^Box, counts: ^map[^dom.Node]int) {
        if b == nil do return
        counts[b.node] += 1
        for c in b.children do count(c, counts)
        for it in b.inlines do if it.box != nil do count(it.box, counts)
    }
    count(root, &counts)
    for n in dirty do if paint_changed(old[n], fresh[n]) && counts[n] != 1 do return false
    return true
}

refresh_box_paint :: proc(b: ^Box, old, styles: map[^dom.Node]Computed, dirty: map[^dom.Node]bool) {
    if b == nil do return
    if dirty[b.node] && paint_changed(old[b.node], styles[b.node]) {
        c := styles[b.node]
        b.bg = c.bg; b.has_bg = c.has_bg; b.bg_canvas = c.bg_canvas
        b.opacity = c.opacity; b.cursor = c.cursor
    }
    for child in b.children do refresh_box_paint(child, old, styles, dirty)
    for it in b.inlines do if it.box != nil do refresh_box_paint(it.box, old, styles, dirty)
}
