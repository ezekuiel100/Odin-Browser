package ui

import "core:strings"
import "core:strconv"

// Complete component grammars for related longhands and shorthands. These
// helpers validate syntax only; capability checks remain in css_supports_decl.
css_value_keyword :: proc(v, choices: string) -> bool {
    for k in strings.fields(choices, context.temp_allocator) do if v == k do return true
    return false
}

css_value_length :: proc(v: string, negative := false, percent := true) -> bool {
    if !percent && strings.contains(v, "%") do return false
    // Do not accept CSS-wide keywords inside a shorthand component.
    if css_value_keyword(v, "inherit initial unset revert revert-layer auto") do return false
    prop := negative ? "margin-left" : "padding-top"
    valid, checked := css_value_valid(prop, v)
    return valid && checked
}

css_value_border :: proc(v: string, outline: bool) -> bool {
    seen: [3]bool
    parts := split_top_level(v)
    if len(parts) < 1 || len(parts) > 3 do return false
    for p in parts {
        if css_value_keyword(p, "inherit initial unset revert revert-layer") do return false
        slot := -1
        if css_value_keyword(p, "thin medium thick") || css_value_length(p, false, false) { slot = 0 }
        else if (css_value_keyword(p, "none hidden dotted dashed solid double groove ridge inset outset") && !(outline && p == "hidden")) || (outline && p == "auto") { slot = 1 }
        else if ok, _ := css_value_valid("color", p); ok { slot = 2 }
        if slot < 0 || seen[slot] do return false
        seen[slot] = true
    }
    return true
}

css_value_alignment :: proc(prop, v: string) -> bool {
    content := prop == "align-content" || prop == "justify-content"
    justify := strings.has_prefix(prop, "justify-")
    if v == "normal" || v == "stretch" do return true
    if !content && strings.has_suffix(prop, "self") && v == "auto" do return true
    if content && css_value_keyword(v, "space-between space-around space-evenly") do return true
    if prop != "justify-content" && (v == "baseline" || v == "first baseline" || v == "last baseline") do return true
    if prop == "justify-items" && (v == "legacy" || v == "legacy left" || v == "legacy right" || v == "legacy center" || v == "left legacy" || v == "right legacy" || v == "center legacy") do return true
    if content && (strings.contains(v, "self-start") || strings.contains(v, "self-end")) do return false
    parts := split_top_level(v)
    if len(parts) == 2 && css_value_keyword(parts[0], "safe unsafe") do return css_value_alignment_position(parts[1], justify)
    return css_value_alignment_position(v, justify)
}

css_value_alignment_position :: proc(v: string, justify: bool) -> bool {
    return css_value_keyword(v, "center start end flex-start flex-end self-start self-end") || (justify && (v == "left" || v == "right"))
}

css_value_timing :: proc(v: string) -> bool {
    if css_value_keyword(v, "linear ease ease-in ease-out ease-in-out step-start step-end") do return true
    if strings.has_prefix(v, "cubic-bezier(") && strings.has_suffix(v, ")") {
        args := css_value_commas(v[13:len(v)-1])
        if len(args) != 4 do return false
        for a, i in args {
            n, ok := css_number(a)
            if !ok || ((i == 0 || i == 2) && (n < 0 || n > 1)) do return false
        }
        return true
    }
    if strings.has_prefix(v, "steps(") && strings.has_suffix(v, ")") {
        args := css_value_commas(v[6:len(v)-1])
        if len(args) < 1 || len(args) > 2 do return false
        n, ok := strconv.parse_int(args[0])
        if !ok || n < 1 do return false
        if len(args) == 1 do return true
        return css_value_keyword(args[1], "start end jump-start jump-end jump-both") || (args[1] == "jump-none" && n > 1)
    }
    return false
}

css_value_family :: proc(prop, v: string) -> (valid, checked: bool) {
    keywords := ""
    switch prop {
    case "caption-side": keywords = "top bottom"
    case "empty-cells": keywords = "show hide"
    case "resize": keywords = "none both horizontal vertical block inline"
    case "user-select", "-webkit-user-select", "-moz-user-select", "-ms-user-select": keywords = "auto text none contain all"
    case "pointer-events": keywords = "auto none visiblepainted visiblefill visiblestroke visible painted fill stroke bounding-box all"
    case "list-style-position": keywords = "inside outside"
    case "text-decoration-style": keywords = "solid double dotted dashed wavy"
    case "text-decoration-skip-ink": keywords = "auto none all"
    case "content-visibility": keywords = "visible auto hidden"
    case "break-before", "break-after": keywords = "auto avoid always all avoid-page page left right recto verso avoid-column column"
    case "break-inside": keywords = "auto avoid avoid-page avoid-column"
    case "page-break-before", "page-break-after": keywords = "auto always avoid left right"
    case "page-break-inside": keywords = "auto avoid"
    }
    if keywords != "" do return css_value_keyword(v, keywords), true
    switch prop {
    case "text-decoration-line":
        if v == "none" do return true, true
        seen: [3]bool
        for p in split_top_level(v) {
            slot := -1
            switch p {
            case "underline": slot = 0
            case "overline": slot = 1
            case "line-through": slot = 2
            }
            if slot < 0 || seen[slot] do return false, true
            seen[slot] = true
        }
        return true, true
    case "border", "border-top", "border-right", "border-bottom", "border-left", "outline", "column-rule":
        return css_value_border(v, prop == "outline"), true
    case "column-rule-color": return css_value_valid("border-top-color", v)
    case "column-rule-style": return css_value_valid("border-top-style", v)
    case "column-rule-width": return css_value_valid("border-top-width", v)
    case "border-radius", "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius":
        // Slash is a separator only outside math functions.
        depth, slash := 0, -1
        for c, i in v {
            if c == '(' do depth += 1
            if c == ')' do depth -= 1
            if c == '/' && depth == 0 {
                if slash >= 0 || prop != "border-radius" do return false, true
                slash = i
            }
        }
        groups := []string{v}
        if slash >= 0 do groups = []string{v[:slash], v[slash+1:]}
        for group in groups {
            parts := split_top_level(group)
            limit := prop == "border-radius" ? 4 : 2
            if len(parts) < 1 || len(parts) > limit do return false, true
            for p in parts do if !css_value_length(p) do return false, true
        }
        return true, true
    case "border-spacing":
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 2 do return false, true
        for p in parts do if !css_value_length(p, false, false) do return false, true
        return true, true
    case "outline-offset": return css_value_length(v, true, false), true
    case "column-width": return v == "auto" || css_value_length(v, false, false), true
    case "columns":
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 2 do return false, true
        width, count := false, false
        for p in parts {
            if p == "auto" do continue
            n, ok := strconv.parse_int(p)
            if ok && n > 0 { if count do return false, true; count = true }
            else if css_value_length(p, false, false) { if width do return false, true; width = true }
            else do return false, true
        }
        return true, true
    case "flex-flow":
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 2 do return false, true
        direction, wrap := false, false
        for p in parts {
            if css_value_keyword(p, "row row-reverse column column-reverse") { if direction do return false, true; direction = true }
            else if css_value_keyword(p, "nowrap wrap wrap-reverse") { if wrap do return false, true; wrap = true }
            else do return false, true
        }
        return true, true
    case "flex":
        if v == "none" || v == "auto" do return true, true
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 3 do return false, true
        nums, basis, basis_at := 0, false, -1
        for p, i in parts {
            if n, ok := css_number(p); ok {
                if n < 0 do return false, true
                if nums == 2 {
                    if n != 0 || basis do return false, true
                    basis = true; basis_at = i; continue
                }
                nums += 1
            } else {
                if basis || css_value_keyword(p, "inherit initial unset revert revert-layer") do return false, true
                ok, _ := css_value_valid("flex-basis", p)
                if !ok do return false, true
                basis = true; basis_at = i
            }
        }
        return !(nums == 2 && basis_at == 1), true
    case "align-items", "align-self", "align-content", "justify-items", "justify-self", "justify-content":
        return css_value_alignment(prop, v), true
    case "place-items", "place-self", "place-content":
        a, b := "align-items", "justify-items"
        if prop == "place-self" { a = "align-self"; b = "justify-self" }
        if prop == "place-content" { a = "align-content"; b = "justify-content" }
        parts := split_top_level(v)
        // Try every boundary: baseline and safe/unsafe are two-token values.
        if css_value_alignment(a, v) && css_value_alignment(b, v) do return true, true
        if prop == "place-content" && (v == "baseline" || v == "first baseline" || v == "last baseline") do return true, true
        for i := 1; i < len(parts); i += 1 {
            left := strings.join(parts[:i], " ", context.temp_allocator)
            right := strings.join(parts[i:], " ", context.temp_allocator)
            if css_value_alignment(a, left) && css_value_alignment(b, right) do return true, true
        }
        return false, true
    case "font-size":
        return css_value_keyword(v, "xx-small x-small small medium large x-large xx-large xxx-large smaller larger") || css_value_length(v), true
    case "vertical-align":
        return css_value_keyword(v, "baseline sub super text-top text-bottom middle top bottom") || css_value_length(v, true), true
    case "text-decoration-thickness": return v == "auto" || v == "from-font" || css_value_length(v), true
    case "text-underline-offset": return v == "auto" || css_value_length(v, true), true
    case "transition-duration", "animation-duration", "transition-delay", "animation-delay", "animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state", "transition-timing-function", "animation-timing-function":
        for p in css_value_commas(v) {
            ok := false
            switch prop {
            case "animation-direction": ok = css_value_keyword(p, "normal reverse alternate alternate-reverse")
            case "animation-fill-mode": ok = css_value_keyword(p, "none forwards backwards both")
            case "animation-play-state": ok = css_value_keyword(p, "running paused")
            case "animation-iteration-count":
                n, k := css_number(p); ok = p == "infinite" || (k && n >= 0)
            case "transition-timing-function", "animation-timing-function": ok = css_value_timing(p)
            case:
                unit := strings.has_suffix(p, "ms") ? 2 : 1
                if strings.has_suffix(p, "s") {
                    n, k := css_number(p[:len(p)-unit])
                    ok = k && (strings.has_suffix(prop, "delay") || n >= 0)
                }
            }
            if !ok do return false, true
        }
        return true, true
    }
    if strings.has_prefix(prop, "scroll-margin") || strings.has_prefix(prop, "scroll-padding") {
        padding := strings.has_prefix(prop, "scroll-padding")
        base := padding ? "scroll-padding" : "scroll-margin"
        limit := 1
        if prop == base do limit = 4
        if strings.has_suffix(prop, "-block") || strings.has_suffix(prop, "-inline") do limit = 2
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > limit do return false, true
        for p in parts {
            if padding && p == "auto" do continue
            if !css_value_length(p, !padding, padding) do return false, true
        }
        return true, true
    }
    return true, false
}

// Keep empty items: a trailing comma invalidates the entire list.
css_value_commas :: proc(v: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    quote: u8
    for i := 0; i < len(v); i += 1 {
        c := v[i]
        if c == '\\' { i += 1; continue }
        if quote != 0 { if c == quote do quote = 0; continue }
        if c == '\'' || c == '"' { quote = c; continue }
        if c == '(' do depth += 1
        if c == ')' do depth -= 1
        if c == ',' && depth == 0 {
            append(&out, strings.trim_space(v[start:i])); start = i+1
        }
    }
    append(&out, strings.trim_space(v[start:])); return out[:]
}
