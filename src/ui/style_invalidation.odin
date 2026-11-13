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

// Why a restyle took the path it took. Everything from `Full_Initial` on runs
// the whole cascade; the UIPROF report counts them to show which one dominates.
Restyle_Reason :: enum u8 {
    Noop,            // nothing dirty
    Incremental,     // dirty subtrees only
    Full_Initial,    // no previous styles / rules just parsed
    Full_Env,        // zoom, viewport or color scheme changed
    Full_CQ,         // container queries active
    Full_New_Node,   // node without previous Computed
    Full_Structure,  // child list changed (kids_ver)
    Full_Counter,    // counters/quotes involved
    Full_Text,       // text node changed
    Full_Cross_Sel,  // sheet has sibling/:has/nth/empty/dir selectors
}

// What in the sheet makes one node's style depend on nodes OUTSIDE its own
// ancestor chain. Each one widens the region a change has to recompute:
//   Sibling  `+`/`~`: a node's change reaches its LATER SIBLINGS (and their
//            subtrees) → recompute the parent's subtree.
//   Nth_Of   `:nth-child(… of S)`: position counts siblings MATCHING S → same.
//   Empty    `:empty`: a child-list/text change flips the PARENT's match.
//   Has      `:has()`: reaches ANCESTORS and their other descendants → full.
//   Counter  counters/quotes run in document order → full.
// Plain `:nth-child`/`:first-child` depend only on the child list, which is
// already covered by recomputing the subtree of the node whose children changed.
Sheet_Dep :: enum u8 { Sibling, Nth_Of, Empty, Has, Counter }
Sheet_Deps :: bit_set[Sheet_Dep]

selector_deps :: proc(s: css.Selector, out: ^Sheet_Deps, depth := 0) {
    if depth > 8 do return
    for c in s.combs do if c == .Adjacent || c == .Sibling do out^ += {.Sibling}
    for p in s.parts {
        if len(p.has) > 0 do out^ += {.Has}
        if len(p.nth_filter) > 0 do out^ += {.Nth_Of}
        if p.empty_req do out^ += {.Empty}
        for q in p.nots do selector_deps(q, out, depth + 1)
        for q in p.ors do selector_deps(q, out, depth + 1)
        for q in p.nth_filter do selector_deps(q, out, depth + 1)
    }
}

style_deps :: proc(rules: []css.Rule) -> (deps: Sheet_Deps) {
    for r in rules {
        for s in r.selectors do selector_deps(s, &deps)
        for prop, val in r.decls {
            if strings.has_prefix(prop, "counter-") || strings.contains(val, "counter(") ||
                strings.contains(val, "counters(") || prop == "quotes" { deps += {.Counter} }
        }
    }
    return
}

Style_Plan :: struct {
    old:         map[^dom.Node]Computed,
    dirty:       ^map[^dom.Node]bool,
    // Every node of the CURRENT tree. Entries of `old` missing here belong to
    // removed nodes: restyle_tab frees and drops them (they would otherwise
    // live forever in the incremental map — and a new node allocated at a
    // freed address would inherit the dead node's Computed).
    live:        ^map[^dom.Node]bool,
    deps:        Sheet_Deps,
    need_layout: bool, // structure/text changed: boxes must be rebuilt even if styles match
}

// Mark the subtree as dirty AND live (callers skip already-live nodes, so the
// walk does not re-plan inside a region that is recomputed anyway).
@(private="file")
plan_mark :: proc(n: ^dom.Node, p: ^Style_Plan) {
    mark_live :: proc(n: ^dom.Node, p: ^Style_Plan) {
        p.dirty[n] = true
        p.live[n] = true
        for c in n.children do mark_live(c, p)
    }
    mark_live(n, p)
    for a := n.parent; a != nil; a = a.parent do p.dirty[a] = true
}

// The direction of a `dir=auto` element comes from its TEXT (first strong
// character), so any change under it can flip the direction of its whole
// subtree. Widen to the topmost such ancestor.
@(private="file")
dir_auto_root :: proc(n: ^dom.Node) -> ^dom.Node {
    top := n
    if SABOTAGE_DIRAUTO do return top
    for a := n; a != nil; a = a.parent {
        if a.kind != .Element do continue
        if d, ok := a.attrs["dir"]; ok && strings.equal_fold(d, "auto") do top = a
    }
    return top
}

plan_style_invalidation :: proc(n: ^dom.Node, p: ^Style_Plan) -> Restyle_Reason {
    // Inside a region already marked for recompute, change detection is moot —
    // but the COUNTER check below still runs for every node (counters run in
    // document order and are not confined to the region).
    covered := n in p.live^
    p.live[n] = true
    c, ok := p.old[n]
    if ok {
        if c.counter_reset_raw != "" || c.counter_increment_raw != "" || c.counter_set_raw != "" || c.quotes_raw != "" do return .Full_Counter
        if c.before != nil && c.before.content_has_counter do return .Full_Counter
        if c.after != nil && c.after.content_has_counter do return .Full_Counter
    } else if !covered {
        // A new node always has a parent whose child list changed, and that
        // branch covers it first; uncovered = root without previous styles.
        return .Full_New_Node
    } else if .Counter in p.deps {
        return .Full_Counter // a NEW node may start counting: its old Computed does not exist
    }
    if covered {
        for child in n.children {
            if r := plan_style_invalidation(child, p); r != .Incremental do return r
        }
        return .Incremental
    }
    sibling_deps := (p.deps & {.Sibling, .Nth_Of}) != {}
    if c.style_kids_ver != n.kids_ver {
        // Child list changed: new/removed/moved children, their siblings'
        // positions (nth, +, ~) and everything below them live in n's subtree.
        // ALL children are recomputed, not only the new ones — that is what
        // makes a node reusing a dead node's address safe.
        if .Has in p.deps do return .Full_Structure
        target := n
        // n's own `:empty` may flip, and with +/~ that reaches n's siblings.
        if .Empty in p.deps && sibling_deps && n.parent != nil do target = n.parent
        plan_mark(dir_auto_root(target), p)
        p.need_layout = true
        // fall through: the children are now covered, the walk below only
        // runs their counter checks
    } else if c.style_fp != dom.style_fingerprint(n) {
        if n.kind != .Element {
            // Text changed: no selector reads text except through `:empty`
            // (of the parent) and `dir=auto`; layout must be rebuilt anyway.
            if .Has in p.deps do return .Full_Text
            target := n
            if .Empty in p.deps && n.parent != nil {
                target = n.parent
                if sibling_deps && target.parent != nil do target = target.parent
            }
            plan_mark(dir_auto_root(target), p)
            p.need_layout = true
        } else {
            // Attributes/class changed: selectors and inherited values reach the
            // subtree; with +/~ (or nth-of) also the later siblings.
            if .Has in p.deps do return .Full_Cross_Sel
            target := n
            if sibling_deps && n.parent != nil && !SABOTAGE_SIB do target = n.parent
            plan_mark(dir_auto_root(target), p)
        }
    }
    for child in n.children {
        if r := plan_style_invalidation(child, p); r != .Incremental do return r
    }
    return .Incremental
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
