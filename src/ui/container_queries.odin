package ui

import "core:strings"
import "base:runtime"
import css "../css"
import dom "../dom"

// Measurements are content-box sizes. Absence is distinct from zero. Retained
// maps use the heap, never a test/frame allocator that may already be recycled.
@(thread_local) g_container_w, g_container_h: map[^dom.Node]f32
@(thread_local) g_container_used, g_container_h_used: map[^dom.Node]f32
@(thread_local) g_container_dirty: bool

container_w_clear :: proc() {
    clear(&g_container_w); clear(&g_container_h)
    clear(&g_container_used); clear(&g_container_h_used)
    g_container_dirty = false
}

container_rules_present :: proc(rules: []css.Rule) -> bool {
    for r in rules do if r.cq_active do return true
    return false
}

container_size_record :: proc(n: ^dom.Node, w, h: f32, track_width := true, track_height := true) {
    if n == nil do return
    if g_container_w == nil do g_container_w = make(map[^dom.Node]f32, runtime.heap_allocator())
    if g_container_h == nil do g_container_h = make(map[^dom.Node]f32, runtime.heap_allocator())
    // Do not quantize: a fraction of a pixel can cross a strict query boundary.
    old_w, had_w := g_container_w[n]
    old_h, had_h := g_container_h[n]
    if !had_w || old_w != w || !had_h || old_h != h {
        g_container_w[n] = w; g_container_h[n] = h
        used_w, had_used_w := g_container_used[n]
        used_h, had_used_h := g_container_h_used[n]
        if (track_width && (!had_w || old_w != w) && (!had_used_w || used_w != w)) ||
            (track_height && (!had_h || old_h != h) && (!had_used_h || used_h != h)) { g_container_dirty = true }
    }
}

// Compatibility for callers/tests measuring only width.
container_w_record :: proc(n: ^dom.Node, w: f32) { container_size_record(n, w, g_container_h[n]) }

CQ_Truth :: enum { Unknown, False, True }

cq_compare :: proc(a, b: f64, cmp: css.Container_Compare) -> bool {
    switch cmp {
    case .Lt: return a < b
    case .Le: return a <= b
    case .Eq: return a == b
    case .Ge: return a >= b
    case .Gt: return a > b
    case .Boolean: return a != 0
    }
    return false
}

cq_length :: proc(value: string, c: Computed) -> (f64, bool) {
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if !css_value_length(v, true, false) do return 0, false
    return container_length_parse(v, c)
}

cq_test_atom :: proc(n: css.Container_Node, c: Computed, w, h: f32) -> CQ_Truth {
    if n.feature == .Unknown do return .Unknown
    // Comparing ratios by cross multiplication would turn 0/0 into equality
    // with every finite ratio. Division is undefined for this measured box.
    if n.feature == .Ratio && w == 0 && h == 0 do return .False
    actual: f64
    switch n.feature {
    case .Width: actual = f64(w)
    case .Height: actual = f64(h)
    case .Inline: actual = f64(c.writing_mode == .Horizontal ? w : h)
    case .Block: actual = f64(c.writing_mode == .Horizontal ? h : w)
    case .Orientation:
        if n.cmp == .Boolean do return .True
        value := strings.to_lower(n.value, context.temp_allocator)
        if value != "landscape" && value != "portrait" do return .Unknown
        matches := value == "landscape" ? w > h : h >= w
        return matches ? .True : .False
    case .Ratio:
    case .Unknown: return .Unknown
    }
    if n.cmp == .Boolean {
        if n.feature == .Ratio do actual = f64(w)
        return actual != 0 ? .True : .False
    }
    for value, i in ([]string{n.value, n.value2}) {
        if i == 1 && value == "" do break
        cmp := i == 0 ? n.cmp : n.cmp2
        if n.feature == .Ratio {
            parts := css_value_slashes(value)
            if len(parts) < 1 || len(parts) > 2 do return .Unknown
            a, ok_a := css_number(strings.trim_space(parts[0]))
            b: f64 = 1
            ok_b := true
            if len(parts) == 2 do b, ok_b = css_number(strings.trim_space(parts[1]))
            if !ok_a || !ok_b || a < 0 || b < 0 do return .Unknown
            if a == 0 && b == 0 do a = 1
            if !cq_compare(f64(w)*b, f64(h)*a, cmp) do return .False
        } else {
            length, ok := cq_length(value, c)
            if !ok do return .Unknown
            if !cq_compare(actual, length, cmp) do return .False
        }
    }
    return .True
}

cq_evaluate :: proc(q: css.Container_Query, c: Computed, w, h: f32) -> bool {
    if !q.valid || q.root < 0 || q.root >= len(q.nodes) do return false
    results := make([]CQ_Truth, len(q.nodes), context.temp_allocator)
    for n, i in q.nodes {
        result := CQ_Truth.Unknown
        switch n.op {
        case .Unknown:
        case .Feature: result = cq_test_atom(n, c, w, h)
        case .Not:
            if results[n.left] == .True { result = .False }
            else if results[n.left] == .False { result = .True }
        case .And:
            a, b := results[n.left], results[n.right]
            if a == .False || b == .False { result = .False }
            else if a == .True && b == .True { result = .True }
        case .Or:
            a, b := results[n.left], results[n.right]
            if a == .True || b == .True { result = .True }
            else if a == .False && b == .False { result = .False }
        }
        results[i] = result
    }
    return results[q.root] == .True
}

cq_container_eligible :: proc(c: Computed, q: css.Container_Query) -> bool {
    if !c.container_inline || c.display_none || c.display_contents do return false
    if q.name != "" {
        found := false
        for name in split_top_level(c.container_name) do if name == q.name do found = true
        if !found do return false
    }
    if !c.container_size {
        if .Block in q.axes do return false
        if c.writing_mode == .Horizontal && .Height in q.axes do return false
        if c.writing_mode != .Horizontal && .Width in q.axes do return false
    }
    return true
}

container_query_matches :: proc(q: css.Container_Query, n: ^dom.Node, styles: ^map[^dom.Node]Computed) -> bool {
    if !q.valid do return false
    for p := n.parent; p != nil; p = p.parent {
        c, found := styles[p]
        if !found || !cq_container_eligible(c, q) do continue
        // Selection precedes evaluation: do not try a more distant ancestor
        // just because the closest eligible container failed its condition.
        w, has_w := g_container_w[p]
        h, has_h := g_container_h[p]
        if !has_w || !has_h do return false
        if g_container_used == nil do g_container_used = make(map[^dom.Node]f32, runtime.heap_allocator())
        if g_container_h_used == nil do g_container_h_used = make(map[^dom.Node]f32, runtime.heap_allocator())
        g_container_used[p] = w; g_container_h_used[p] = h
        return cq_evaluate(q, c, w, h)
    }
    return false
}

container_matches :: proc(r: css.Rule, n: ^dom.Node, styles: ^map[^dom.Node]Computed) -> bool {
    if styles == nil || n == nil do return false
    matched := false
    for q, i in r.cq_queries {
        if i > 0 && !q.or_previous {
            if !matched do return false
            matched = false
        }
        if !matched do matched = container_query_matches(q, n, styles)
    }
    return matched
}

css_value_container :: proc(prop, raw: string) -> (bool, bool) {
    v := strings.trim_space(raw)
    switch prop {
    case "container-type": return css_value_keyword(strings.to_lower(v, context.temp_allocator), "normal inline-size size"), true
    case "container-name":
        if strings.equal_fold(v, "none") do return true, true
        names := split_top_level(v)
        if len(names) == 0 do return false, true
        for name in names do if !css.container_name_valid(name) do return false, true
        return true, true
    case "container":
        groups := css_value_slashes(v)
        if len(groups) > 2 do return false, true
        valid, _ := css_value_container("container-name", groups[0])
        if !valid do return false, true
        if len(groups) == 2 do return css_value_container("container-type", groups[1])
        return true, true
    }
    return true, false
}

// An outer query may change the size/type/name of an inner query container.
// Settle the dependency chain, rather than assuming two passes are sufficient.
CONTAINER_MAX_PASSES :: 32

settle_container_tree :: proc(root: ^dom.Node, rules: ^[dynamic]css.Rule, keys: []css.Keyframe_Set,
    styles: ^map[^dom.Node]Computed, layout: ^^Box, base_url: string, w, h: f32, page_bg: ^u32 = nil) {
    if !container_rules_present(rules[:]) do return
    last_inputs: u64
    have_inputs := false
    for _ in 0..<CONTAINER_MAX_PASSES {
        ensure_tab_geometry(layout^, w, h)
        if !g_container_dirty do break
        inputs := container_inputs_fingerprint(styles^)
        // Flex/grid may measure a provisional size before imposing the final
        // one. A transient measurement must not cause repeated full rebuilds.
        if have_inputs && inputs == last_inputs { g_container_dirty = false; break }
        last_inputs = inputs; have_inputs = true
        g_container_dirty = false
        fresh, bg := compute_styles(root, rules, w, h, keys)
        next := build_layout(root, fresh, base_url)
        animation_restore_tree(next, layout^)
        scroll_restore_tree(next, layout^)
        free_layout(layout^); free_styles(styles^)
        layout^ = next; styles^ = fresh
        if page_bg != nil do page_bg^ = bg
    }
    ensure_tab_geometry(layout^, w, h)
}
