package ui

import "core:strings"

css_value_font_family :: proc(v: string) -> bool {
    for family in css_value_commas(v) {
        if css_value_string(family) do continue
        parts := split_top_level(family)
        if len(parts) == 0 do return false
        for p in parts do if !css_value_ident(p) do return false
        // Generic families are single keywords, never part of an unquoted name.
        if len(parts) > 1 {
            for p in parts do if css_value_keyword(p, "serif sans-serif monospace cursive fantasy system-ui ui-serif ui-sans-serif ui-monospace ui-rounded emoji math fangsong") do return false
        }
    }
    return true
}

css_value_font :: proc(v: string) -> bool {
    if css_value_keyword(v, "caption icon menu message-box small-caption status-bar") do return true
    groups := css_value_slashes(v)
    if len(groups) > 2 do return false
    parts := split_top_level(groups[0])
    seen: [4]bool
    normals, size_at := 0, -1
    for p, i in parts {
        if valid, _ := css_value_valid("font-size", p); valid && !css_value_keyword(p, "initial inherit unset revert revert-layer") {
            size_at = i; break
        }
        if p == "normal" { normals += 1; continue }
        slot := -1
        if p == "italic" || p == "oblique" { slot = 0 }
        else if p == "small-caps" { slot = 1 }
        else if css_value_keyword(p, "ultra-condensed extra-condensed condensed semi-condensed semi-expanded expanded extra-expanded ultra-expanded") { slot = 3 }
        else if ok, _ := css_value_valid("font-weight", p); ok { slot = 2 }
        if slot < 0 || seen[slot] do return false
        seen[slot] = true
    }
    if size_at < 0 do return false
    used := normals
    for b in seen do if b do used += 1
    if used > 4 do return false
    if len(groups) == 1 {
        return css_value_font_family(strings.join(parts[size_at+1:], " ", context.temp_allocator))
    }
    if size_at != len(parts)-1 do return false
    rest := split_top_level(groups[1])
    if len(rest) < 2 || css_value_keyword(rest[0], "initial inherit unset revert revert-layer") do return false
    if valid, _ := css_value_valid("line-height", rest[0]); !valid do return false
    return css_value_font_family(strings.join(rest[1:], " ", context.temp_allocator))
}
