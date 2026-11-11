package ui

// Main-thread resource deliveries invalidate all roots, including inactive tabs.
g_geometry_resources: u64

// A new box tree starts invalid. Paint-only style updates retain this stamp.
// Manual resize currently uses a mutable global map: conservatively lay out
// while it has entries until that map has a mutation version of its own.
ensure_tab_geometry :: proc(root: ^Box, w, h: f32) -> bool {
    if root == nil do return false
    if root.geometry_valid && root.geometry_w == w && root.geometry_h == h &&
        root.geometry_resources == g_geometry_resources && len(g_resize) == 0 {
        return false
    }
    layout_box(root, 0, 0, w)
    page := Rect{0, 0, w, h}
    layout_absolutes(root, page, page)
    root.geometry_w, root.geometry_h = w, h
    root.geometry_resources = g_geometry_resources
    root.geometry_valid = true
    return true
}
