package ui

import dom "../dom"

// Entries point to ownership slots in the OLD tree, never to the DOM itself.
// Taking a subtree clears that slot before the old tree can be freed.
Layout_Reuse_Entry :: struct {
    box: ^Box,
    slot: ^^Box,
    count: int,
    safe: bool,
}
Layout_Reuse :: struct {
    dirty: map[^dom.Node]bool,
    styles: map[^dom.Node]Computed,
    blocked: map[^dom.Node]bool,
    sources: map[^Inline_Source]bool,
    entries: map[^dom.Node]Layout_Reuse_Entry,
    boxes, roots: int,
}
@(thread_local) g_layout_reuse: ^Layout_Reuse

// Only incremental restyles may use this wrapper. Dirty includes the ancestor
// path, so an unmarked node's DOM/style subtree is entirely unchanged. Global
// font/viewport/sheet invalidations keep using the ordinary complete builder.
build_layout_reusing :: proc(node: ^dom.Node, styles: map[^dom.Node]Computed, base: string, old: ^Box, dirty: map[^dom.Node]bool) -> (root: ^Box, boxes, roots: int) {
    reuse := Layout_Reuse{dirty=dirty, styles=styles, entries=make(map[^dom.Node]Layout_Reuse_Entry, context.temp_allocator), blocked=make(map[^dom.Node]bool,context.temp_allocator), sources=make(map[^Inline_Source]bool,context.temp_allocator)}
    old_root := old
    layout_reuse_index(&old_root, &reuse)
    // Always create a fresh root, including when the caller passes an element
    // rather than a document. Its ownership is held directly by the caller.
    if old != nil && old.node != nil do delete_key(&reuse.entries, old.node)
    previous := g_layout_reuse
    g_layout_reuse = &reuse
    defer { g_layout_reuse = previous }
    root = build_layout(node, styles, base)
    geometry_inherit(root,old)
    return root, reuse.boxes, reuse.roots
}

@(private="file")
layout_reuse_index :: proc(slot: ^^Box, reuse: ^Layout_Reuse, table_context := false) -> (unsafe: bool) {
    b := slot^
    if b == nil do return false
    // border-collapse mutates cell borders, so reflowing retained cells would
    // measure their already-collapsed model. Rebuild the entire table context.
    sensitive_table := table_context || b.is_table
    if sensitive_table do unsafe = true
    // Percent height limits are resolved into mutable has_minh/minh/maxh fields.
    // A later intrinsic pass must start from the original unresolved model.
    if b.has_minh_pct || b.has_maxh_pct do unsafe = true
    // Absolute/fixed boxes can be physically hoisted out of their DOM parent
    // by layout_absolutes. Rebuild both ownership paths instead of retaining
    // an incomplete subtree or a stale anchor into a freed ancestor.
    if b.pos == .Absolute || b.pos == .Fixed {
        unsafe = true
        if b.node != nil && b.node in reuse.styles {
            for ancestor := b.node; ancestor != nil; ancestor = ancestor.parent do reuse.blocked[ancestor] = true
        }
    }
    if b.node != nil && (reuse.dirty[b.node] || b.node not_in reuse.styles) do unsafe = true
    for &child in b.children do if layout_reuse_index(&child, reuse, sensitive_table) do unsafe = true
    for &item in b.inlines {
        if layout_reuse_source_dirty(item.source, reuse) do unsafe = true
        if item.box != nil && layout_reuse_index(&item.box, reuse, sensitive_table) do unsafe = true
    }
    if b.node != nil {
        entry := reuse.entries[b.node]
        entry.count += 1
        entry.box = b
        entry.slot = slot
        entry.safe = !unsafe
        reuse.entries[b.node] = entry
    }
    return
}

@(private="file")
layout_reuse_source_dirty :: proc(source: ^Inline_Source, reuse: ^Layout_Reuse) -> bool {
    if source == nil do return false
    if dirty, known := reuse.sources[source]; known do return dirty
    dirty := source.node != nil && (reuse.dirty[source.node] || source.node not_in reuse.styles)
    if layout_reuse_source_dirty(source.left,reuse) || layout_reuse_source_dirty(source.right,reuse) do dirty = true
    reuse.sources[source] = dirty
    return dirty
}

// Retire every descendant entry as well. A later builder call cannot detach
// part of a subtree that has already become owned by the new tree.
@(private="file")
layout_reuse_retire :: proc(b: ^Box, reuse: ^Layout_Reuse) -> int {
    if b == nil do return 0
    b.geometry_retained = true
    if b.node != nil do delete_key(&reuse.entries, b.node)
    count := 1
    for child in b.children do count += layout_reuse_retire(child, reuse)
    for item in b.inlines do if item.box != nil do count += layout_reuse_retire(item.box, reuse)
    return count
}

layout_reuse_take :: proc(node: ^dom.Node) -> ^Box {
    reuse := g_layout_reuse
    if reuse == nil || reuse.dirty[node] || reuse.blocked[node] do return nil
    // Their construction reads siblings outside the node's DOM subtree:
    // picture sources and ordered-list marker values, respectively.
    if node.tag == "img" || node.tag == "li" do return nil
    // A shadow subtree can render assigned light-DOM nodes outside its DOM
    // ancestry. Rebuild it when its host is dirty, even if the slot itself
    // has not changed. An entirely clean host remains eligible as a unit.
    for ancestor := node; ancestor != nil; ancestor = ancestor.parent {
        if ancestor.tag == "#shadow" && ancestor.parent != nil && reuse.dirty[ancestor.parent] do return nil
    }
    entry, ok := reuse.entries[node]
    // Anonymous boxes and nodes represented by several boxes are rebuilt.
    if !ok || entry.count != 1 || !entry.safe do return nil
    entry.slot^ = nil
    reuse.boxes += layout_reuse_retire(entry.box, reuse)
    reuse.roots += 1
    // Parent-owned context is supplied again by the new builder call site.
    entry.box.inline_parent_effect = nil
    entry.box.stacking_item = false
    return entry.box
}

// A retained box must not borrow transforms from a Computed entry that may
// be replaced. Animation arrays already belong to the box; clone their nested
// transform lists as well, sharing each source at most once within this box.
box_own_transforms :: proc(b: ^Box) {
    copies := make(map[^XList]^XList, context.temp_allocator)
    clone :: proc(src: ^XList, copies: ^map[^XList]^XList, owned: ^[dynamic]^XList) -> ^XList {
        if src == nil do return nil
        if copy, found := copies[src]; found do return copy
        out := new(XList)
        x_copy(out, src)
        copies[src] = out
        append(owned, out)
        return out
    }
    b.xform = clone(b.xform, &copies, &b.owned_xforms)
    b.hover.xform = clone(b.hover.xform, &copies, &b.owned_xforms)
    for &player in b.animations {
        player.anim.underlying.xform = clone(player.anim.underlying.xform, &copies, &b.owned_xforms)
        for &stop in player.anim.stops do stop.xform = clone(stop.xform, &copies, &b.owned_xforms)
    }
}
