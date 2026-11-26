package ui

import "core:strings"
import "core:strconv"
import css "../css"

css_value_grid_line :: proc(v: string) -> bool {
    if v == "auto" do return true
    parts := split_top_level(v)
    if len(parts) < 1 || len(parts) > 3 do return false
    span, number, name := false, false, false
    n := 0
    for p in parts {
        if p == "span" { if span do return false; span = true }
        else if i, ok := strconv.parse_int(p); ok {
            if number || i == 0 do return false
            number = true; n = i
        } else {
            if name || p == "auto" || !css_value_ident(p) do return false
            name = true
        }
    }
    return (!span || number || name) && (!span || !number || n > 0)
}

css_value_grid_breadth :: proc(v: string, flex: bool) -> bool {
    if css_value_keyword(v, "auto min-content max-content") do return true
    if flex && strings.has_suffix(v, "fr") {
        n, ok := css_number(v[:len(v)-2])
        return ok && n >= 0
    }
    return css_value_length(v)
}

css_value_grid_track :: proc(v: string) -> bool {
    if css_value_grid_breadth(v, true) do return true
    open := strings.index_byte(v, '(')
    if open <= 0 || css.token_group_end(v, open) != len(v)-1 do return false
    args := css_value_commas(v[open+1:len(v)-1])
    switch v[:open] {
    case "minmax": return len(args) == 2 && css_value_grid_breadth(args[0], false) && css_value_grid_breadth(args[1], true)
    case "fit-content": return len(args) == 1 && css_value_length(args[0])
    }
    return false
}

css_value_grid_fixed :: proc(v: string) -> bool {
    if css_value_length(v) do return true
    if !strings.has_prefix(v, "minmax(") || css.token_group_end(v, 6) != len(v)-1 do return false
    args := css_value_commas(v[7:len(v)-1])
    return len(args) == 2 && css_value_grid_breadth(args[0], false) && css_value_grid_breadth(args[1], true) &&
        (css_value_length(args[0]) || (css_value_grid_breadth(args[1], false) && css_value_length(args[1])))
}

css_value_grid_names :: proc(v: string) -> bool {
    if len(v) < 2 || v[0] != '[' || css.token_group_end(v, 0) != len(v)-1 do return false
    for name in split_top_level(v[1:len(v)-1]) do if name == "span" || name == "auto" || !css_value_ident(name) do return false
    return true
}

css_value_grid_tracks :: proc(v: string, repeat := true, names := true) -> bool {
    if v == "none" do return repeat && names
    parts := split_top_level(v)
    if len(parts) == 0 do return false
    if parts[0] == "subgrid" {
        if !repeat || !names do return false
        for p in parts[1:] do if !css_value_grid_names(p) do return false
        return true
    }
    tracks, auto_repeat := 0, false
    fixed := true
    for p in parts {
        if names && css_value_grid_names(p) do continue
        if css_value_grid_track(p) { tracks += 1; fixed = fixed && css_value_grid_fixed(p); continue }
        if repeat && strings.has_prefix(p, "repeat(") && css.token_group_end(p, 6) == len(p)-1 {
            inner := p[7:len(p)-1]
            comma := css.token_index_top(inner, ',')
            if comma < 0 do return false
            count := strings.trim_space(inner[:comma])
            body := strings.trim_space(inner[comma+1:])
            if count == "auto-fill" || count == "auto-fit" {
                if auto_repeat do return false
                auto_repeat = true
                // Automatic repetition needs fixed-size tracks.
                for track in split_top_level(body) {
                    if css_value_grid_names(track) do continue
                    if css_value_grid_fixed(track) do continue
                    return false
                }
            } else if n, ok := strconv.parse_int(count); !ok || n < 1 { return false }
            if !css_value_grid_tracks(body, false, names) do return false
            for track in split_top_level(body) {
                if css_value_grid_names(track) do continue
                fixed = fixed && css_value_grid_fixed(track)
            }
            tracks += 1
            continue
        }
        return false
    }
    return tracks > 0 && (!auto_repeat || fixed)
}

css_value_grid_areas :: proc(v: string) -> bool {
    if v == "none" do return true
    Bounds :: struct { x0, x1, y0, y1, count: int }
    areas := make(map[string]Bounds, context.temp_allocator)
    rows := split_top_level(v)
    if len(rows) == 0 do return false
    columns := -1
    for row, y in rows {
        if !css_value_string(row) do return false
        // Decode escapes without changing the declaration's serialized value.
        b := strings.builder_make(context.temp_allocator)
        for i := 1; i < len(row)-1; i += 1 {
            if row[i] == '\\' {
                cp, end, ok := css.consume_escape(row, i)
                if !ok do return false
                strings.write_rune(&b, cp); i = end-1
            } else { strings.write_byte(&b, row[i]) }
        }
        text := strings.to_string(b)
        cells := make([dynamic]string, context.temp_allocator)
        start := 0
        for start < len(text) {
            if strings.index_byte(" \t\n\r\f", text[start]) >= 0 { start += 1; continue }
            end := start+1
            dots := text[start] == '.'
            for end < len(text) && strings.index_byte(" \t\n\r\f", text[end]) < 0 && (text[end] == '.') == dots do end += 1
            append(&cells, text[start:end]); start = end
        }
        if len(cells) == 0 || (columns >= 0 && columns != len(cells)) do return false
        columns = len(cells)
        for name, x in cells {
            if name[0] == '.' do continue
            if !css_value_ident(name) do return false
            b, found := areas[name]
            if !found { b = Bounds{x, x, y, y, 0} }
            b.x0 = min(b.x0, x); b.x1 = max(b.x1, x)
            b.y1 = y; b.count += 1
            areas[strings.clone(name, context.temp_allocator)] = b
        }
    }
    for _, b in areas do if b.count != (b.x1-b.x0+1)*(b.y1-b.y0+1) do return false
    return true
}

css_value_grid_template :: proc(v: string) -> bool {
    if v == "none" do return true
    groups := css_value_slashes(v)
    if len(groups) > 2 do return false
    parts := split_top_level(groups[0])
    has_area := false
    for p in parts do if css_value_string(p) do has_area = true
    if !has_area do return len(groups) == 2 && css_value_grid_tracks(groups[0]) && css_value_grid_tracks(groups[1])
    areas := make([dynamic]string, context.temp_allocator)
    have_row, sized := false, false
    for p in parts {
        if css_value_grid_names(p) do continue
        if css_value_string(p) { append(&areas, p); have_row = true; sized = false }
        else {
            if !have_row || sized || !css_value_grid_track(p) do return false
            sized = true
        }
    }
    return css_value_grid_areas(strings.join(areas[:], " ", context.temp_allocator)) &&
        (len(groups) == 1 || css_value_grid_tracks(groups[1], false, true))
}

css_value_grid :: proc(prop, v: string) -> (bool, bool) {
    switch prop {
    case "grid-column-start", "grid-column-end", "grid-row-start", "grid-row-end": return css_value_grid_line(v), true
    case "grid-column", "grid-row", "grid-area":
        parts := css_value_slashes(v)
        if len(parts) > (prop == "grid-area" ? 4 : 2) do return false, true
        for p in parts do if !css_value_grid_line(p) do return false, true
        return true, true
    case "grid-template-columns", "grid-template-rows": return css_value_grid_tracks(v), true
    case "grid-auto-columns", "grid-auto-rows": return css_value_grid_tracks(v, false, false), true
    case "grid-template-areas": return css_value_grid_areas(v), true
    case "grid-template": return css_value_grid_template(v), true
    case "grid-auto-flow":
        parts := split_top_level(v)
        if len(parts) == 1 do return css_value_keyword(v, "row column dense"), true
        if len(parts) != 2 do return false, true
        return (css_value_keyword(parts[0], "row column") && parts[1] == "dense") ||
            (parts[0] == "dense" && css_value_keyword(parts[1], "row column")), true
    }
    return true, false
}
