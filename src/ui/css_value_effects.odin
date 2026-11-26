package ui

import "core:strings"
import css "../css"

css_value_ident :: proc(v: string) -> bool {
    if v == "" || css_value_keyword(v, "initial inherit unset revert revert-layer default") do return false
    l := css.Tokenizer{source = v}
    t := css.next_token(&l)
    if t.kind != .Name || t.end != len(v) do return false
    c := v[0]
    if c >= '0' && c <= '9' do return false
    if c == '-' && (len(v) == 1 || (v[1] >= '0' && v[1] <= '9')) do return false
    return true
}

css_value_string :: proc(v: string) -> bool {
    l := css.Tokenizer{source = v}
    t := css.next_token(&l)
    return t.kind == .String && t.end == len(v)
}

css_value_angle :: proc(v: string) -> bool {
    if n, ok := css_number(v); ok do return n == 0
    for unit in ([]string{"deg", "rad", "grad", "turn"}) {
        if strings.has_suffix(v, unit) {
            _, ok := css_number(v[:len(v)-len(unit)])
            if ok do return true
        }
    }
    return false
}

css_value_shadow :: proc(v: string, text: bool) -> bool {
    if v == "none" do return true
    for item in css_value_commas(v) {
        lengths, color, inset, ended_lengths := 0, false, false, false
        for p in split_top_level(item) {
            if p == "inset" {
                if text || inset do return false
                inset = true
                if lengths > 0 do ended_lengths = true
            } else if css_value_length(p, true, false) {
                if ended_lengths do return false
                // The third length is blur; it cannot be negative.
                if lengths == 2 && !css_value_length(p, false, false) do return false
                lengths += 1
            } else {
                if color || css_value_keyword(p, "inherit initial unset revert revert-layer") do return false
                ok, _ := css_value_valid("color", p)
                if !ok do return false
                color = true
                if lengths > 0 do ended_lengths = true
            }
        }
        if lengths < 2 || lengths > (text ? 3 : 4) do return false
    }
    return true
}

css_value_transform :: proc(v: string) -> bool {
    if v == "none" do return true
    l := css.Tokenizer{source = v}
    count := 0
    for {
        t := css.next_token(&l)
        if t.kind == .EOF do return count > 0
        if t.kind == .Space || t.kind == .Comment do continue
        if t.kind != .Name || t.end >= len(v) || v[t.end] != '(' do return false
        end := css.token_group_end(v, t.end)
        if end < 0 do return false
        args := css_value_commas(v[t.end+1:end])
        name := v[t.start:t.end]
        lo, hi := 1, 1
        switch name {
        case "matrix": lo = 6; hi = 6
        case "matrix3d": lo = 16; hi = 16
        case "translate", "scale", "skew": hi = 2
        case "translate3d", "scale3d": lo = 3; hi = 3
        case "rotate3d": lo = 4; hi = 4
        case "translatex", "translatey", "translatez", "scalex", "scaley", "scalez", "rotate", "rotatex", "rotatey", "rotatez", "skewx", "skewy", "perspective":
        case: return false
        }
        if len(args) < lo || len(args) > hi do return false
        for a, i in args {
            if strings.has_prefix(name, "translate") {
                percent := name != "translatez" && !(name == "translate3d" && i == 2)
                if !css_value_length(a, true, percent) do return false
            } else if name == "perspective" {
                if a != "none" && !css_value_length(a, false, false) do return false
            } else if strings.has_prefix(name, "rotate") || strings.has_prefix(name, "skew") {
                if name == "rotate3d" && i < 3 {
                    if _, ok := css_number(a); !ok do return false
                } else if !css_value_angle(a) { return false }
            } else {
                if _, ok := css_number(a); !ok do return false
            }
        }
        count += 1
        l.pos = end+1
    }
}

css_value_motion :: proc(prop, v: string) -> bool {
    animation := prop == "animation"
    items := css_value_commas(v)
    if !animation && v == "none" do return true
    for item in items {
        if item == "" do return false
        seen: [6]bool // timing, direction, fill, play-state, iterations, name
        times := 0
        for p in split_top_level(item) {
            if strings.has_suffix(p, "s") {
                unit := strings.has_suffix(p, "ms") ? 2 : 1
                if n, ok := css_number(p[:len(p)-unit]); ok {
                    if times >= 2 || (times == 0 && n < 0) do return false
                    times += 1; continue
                }
            }
            slot := -1
            if !seen[0] && css_value_timing(p) { slot = 0 }
            else if animation {
                if !seen[1] && css_value_keyword(p, "normal reverse alternate alternate-reverse") { slot = 1 }
                else if !seen[2] && css_value_keyword(p, "none forwards backwards both") { slot = 2 }
                else if !seen[3] && css_value_keyword(p, "running paused") { slot = 3 }
                else if !seen[4] {
                    n, ok := css_number(p)
                    if p == "infinite" || (ok && n >= 0) do slot = 4
                }
            }
            if slot < 0 && !seen[5] && (css_value_ident(p) || (animation && css_value_string(p))) {
                if !animation && p == "none" do return false
                slot = 5
            }
            if slot < 0 do return false
            seen[slot] = true
        }
    }
    return true
}

// Slash is syntax only outside component groups and quoted strings.
css_value_slashes :: proc(v: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    start := 0
    for start <= len(v) {
        at := css.token_index_top(v[start:], '/')
        if at < 0 { append(&out, strings.trim_space(v[start:])); break }
        append(&out, strings.trim_space(v[start:start+at]))
        start += at+1
    }
    return out[:]
}

css_value_image :: proc(v: string) -> bool {
    if v == "none" do return true
    open := strings.index_byte(v, '(')
    if open <= 0 || css.token_group_end(v, open) != len(v)-1 do return false
    if v[:open] == "url" {
        inner := strings.trim_space(v[open+1:len(v)-1])
        if inner == "" || css_value_string(inner) do return true
        for i := 0; i < len(inner); i += 1 {
            c := inner[i]
            if c == '\\' { _, end, ok := css.consume_escape(inner, i); if !ok do return false; i = end-1; continue }
            if c <= ' ' || c == '(' || c == ')' || c == '"' || c == '\'' || c == 127 do return false
        }
        return true
    }
    if !css_value_keyword(v[:open], "linear-gradient radial-gradient conic-gradient repeating-linear-gradient repeating-radial-gradient repeating-conic-gradient") do return false
    _, ok := css.parse_gradient(v)
    return ok
}

css_value_position :: proc(v: string) -> bool {
    parts := split_top_level(v)
    if len(parts) < 1 || len(parts) > 4 do return false
    if len(parts) == 1 do return css_value_keyword(v, "left right top bottom center") || css_value_length(v, true)
    if len(parts) == 2 {
        x := css_value_keyword(parts[0], "left right center") || css_value_length(parts[0], true)
        y := css_value_keyword(parts[1], "top bottom center") || css_value_length(parts[1], true)
        swapped := css_value_keyword(parts[0], "top bottom center") && css_value_keyword(parts[1], "left right center")
        return (x && y) || swapped
    }
    horizontal, vertical := false, false
    terms := 0
    for i := 0; i < len(parts); i += 1 {
        terms += 1
        p := parts[i]
        if css_value_keyword(p, "left right") { if horizontal do return false; horizontal = true }
        else if css_value_keyword(p, "top bottom") { if vertical do return false; vertical = true }
        else if p == "center" {
            if i+1 < len(parts) && css_value_length(parts[i+1], true) do return false
            continue
        } else { return false }
        if i+1 < len(parts) && css_value_length(parts[i+1], true) do i += 1
    }
    return terms == 2
}

css_value_bg_size :: proc(v: string) -> bool {
    if v == "cover" || v == "contain" do return true
    parts := split_top_level(v)
    if len(parts) < 1 || len(parts) > 2 do return false
    for p in parts do if p != "auto" && !css_value_length(p) do return false
    return true
}

css_value_background :: proc(v: string) -> bool {
    layers := css_value_commas(v)
    for layer, i in layers {
        if layer == "" do return false
        groups := css_value_slashes(layer)
        if len(groups) > 2 do return false
        position := make([dynamic]string, context.temp_allocator)
        size := make([dynamic]string, context.temp_allocator)
        image, color, attachment := false, false, false
        boxes, repeat := 0, 0
        repeat_single := false
        for group, gi in groups {
            reading_size := gi == 1
            for p in split_top_level(group) {
                if reading_size && len(size) < 2 && (p == "auto" || p == "cover" || p == "contain" || css_value_length(p)) {
                    append(&size, p); continue
                }
                if reading_size && len(size) == 0 do return false
                reading_size = false
                if css_value_image(p) { if image do return false; image = true }
                else if css_value_keyword(p, "repeat no-repeat space round repeat-x repeat-y") {
                    if repeat_single || repeat >= 2 do return false
                    repeat_single = p == "repeat-x" || p == "repeat-y"
                    if repeat_single && repeat > 0 do return false
                    repeat += 1
                } else if css_value_keyword(p, "scroll fixed local") {
                    if attachment do return false; attachment = true
                } else if css_value_keyword(p, "border-box padding-box content-box") {
                    boxes += 1; if boxes > 2 do return false
                } else if ok, _ := css_value_valid("color", p); ok && !css_value_keyword(p, "inherit initial unset revert revert-layer") {
                    if color || i != len(layers)-1 do return false
                    color = true
                } else {
                    if gi == 1 do return false
                    append(&position, p)
                }
            }
        }
        if len(position) > 0 && !css_value_position(strings.join(position[:], " ", context.temp_allocator)) do return false
        if len(groups) == 2 && (len(position) == 0 || !css_value_bg_size(strings.join(size[:], " ", context.temp_allocator))) do return false
    }
    return true
}

css_value_effects :: proc(prop, v: string) -> (bool, bool) {
    switch prop {
    case "box-shadow", "text-shadow": return css_value_shadow(v, prop == "text-shadow"), true
    case "transform": return css_value_transform(v), true
    case "translate":
        if v == "none" do return true, true
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 3 do return false, true
        for p, i in parts do if !css_value_length(p, true, i != 2) do return false, true
        return true, true
    case "scale":
        if v == "none" do return true, true
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 3 do return false, true
        for p in parts {
            num := p
            if strings.has_suffix(p, "%") do num = p[:len(p)-1]
            if _, ok := css_number(num); !ok do return false, true
        }
        return true, true
    case "rotate":
        if v == "none" do return true, true
        parts := split_top_level(v)
        if len(parts) == 1 do return css_value_angle(v), true
        if len(parts) == 2 do return (css_value_keyword(parts[0], "x y z") && css_value_angle(parts[1])) || (css_value_angle(parts[0]) && css_value_keyword(parts[1], "x y z")), true
        if len(parts) != 4 do return false, true
        for angle_at in ([]int{0, 3}) {
            if !css_value_angle(parts[angle_at]) do continue
            numbers := true
            for p, i in parts do if i != angle_at { if _, ok := css_number(p); !ok do numbers = false }
            if numbers do return true, true
        }
        return false, true
    case "animation", "transition": return css_value_motion(prop, v), true
    case "animation-name", "transition-property":
        if prop == "transition-property" && v == "none" do return true, true
        for p in css_value_commas(v) {
            if prop == "animation-name" && css_value_string(p) do continue
            if !css_value_ident(p) || (prop == "transition-property" && p == "none") do return false, true
        }
        return true, true
    case "background": return css_value_background(v), true
    case "background-image", "list-style-image", "mask-image":
        for p in css_value_commas(v) do if !css_value_image(p) do return false, true
        return true, true
    case "background-size", "mask-size":
        for p in css_value_commas(v) do if !css_value_bg_size(p) do return false, true
        return true, true
    case "background-position", "mask-position", "object-position":
        for p in css_value_commas(v) do if !css_value_position(p) do return false, true
        return true, true
    case "background-repeat", "mask-repeat":
        for p in css_value_commas(v) {
            if p == "repeat-x" || p == "repeat-y" do continue
            parts := split_top_level(p)
            if len(parts) < 1 || len(parts) > 2 do return false, true
            for part in parts do if !css_value_keyword(part, "repeat no-repeat space round") do return false, true
        }
        return true, true
    case "background-origin", "background-clip", "background-attachment":
        choices := prop == "background-attachment" ? "scroll fixed local" : "border-box padding-box content-box"
        if prop == "background-clip" do choices = "border-box padding-box content-box text"
        for p in css_value_commas(v) do if !css_value_keyword(p, choices) do return false, true
        return true, true
    }
    return true, false
}
