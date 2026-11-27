package ui

// Main-thread resource deliveries invalidate all roots, including inactive tabs.
g_geometry_resources: u64

// A new box tree starts invalid. Paint-only style updates retain this stamp.
// Manual resize currently uses a mutable global map: conservatively lay out
// while it has entries until that map has a mutation version of its own.
ensure_tab_geometry :: proc(root: ^Box, w, h: f32) -> bool {
    if root == nil do return false
    environment := geometry_environment(w,h)
    root.geometry_stats = {}
    if root.geometry_valid && root.geometry_environment == environment && len(g_resize) == 0 {
        return false
    }
    pass := Geometry_Pass{environment=environment,record=true,
        reuse=root.geometry_incremental && root.geometry_environment == environment && len(g_resize) == 0}
    previous := g_geometry_pass
    g_geometry_pass = &pass
    defer { g_geometry_pass = previous }
    layout_box(root, 0, 0, w)
    // Out-of-flow placement/hoisting always runs. Its calls cannot publish or
    // reuse normal-flow memos with different ownership/containing blocks.
    pass.record = false
    page := Rect{0, 0, w, h}
    layout_absolutes(root, page, page)
    root.geometry_environment = environment
    root.geometry_valid = true
    root.geometry_incremental = false
    root.geometry_stats = pass.stats
    when UIPROF {
        g_uiprof.geometry_reflowed += pass.stats.reflowed
        g_uiprof.geometry_hits += pass.stats.hits
        g_uiprof.geometry_skipped += pass.stats.skipped_boxes
    }
    return true
}
