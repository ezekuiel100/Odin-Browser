package ui

import "core:strings"
import "core:strconv"
import csspkg "../css"
import jspkg "../js"

// A syntax decision is separate from feature support. Uncovered grammars keep
// their existing parser; callers must not confuse `checked = false` with proof.
css_value_valid :: proc(prop, value: string) -> (valid, checked: bool) {
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if v == "" do return false, true
    if !css_value_balanced(v) do return false, true
    if strings.has_prefix(prop, "--") do return true, true
    // Substitution is checked at computed-value time, not against a dummy map.
    if strings.contains(v, "var(") || strings.contains(v, "attr(") do return true, false
    switch v {
    case "inherit", "initial", "unset", "revert", "revert-layer": return true, true
    }
    keywords := ""
    switch prop {
    case "display": keywords = "none flex inline-flex grid inline-grid inline-block block flow-root inline table inline-table table-row table-cell table-row-group table-header-group table-footer-group contents"
    case "position": keywords = "static relative absolute fixed sticky -webkit-sticky"
    case "box-sizing": keywords = "content-box border-box"
    case "flex-direction": keywords = "row row-reverse column column-reverse"
    case "flex-wrap": keywords = "nowrap wrap wrap-reverse"
    case "visibility": keywords = "visible hidden collapse"
    case "overflow", "overflow-x", "overflow-y": keywords = "visible hidden clip scroll auto"
    case "float": keywords = "none left right inline-start inline-end"
    case "clear": keywords = "none left right both inline-start inline-end"
    case "isolation": keywords = "auto isolate"
    case "object-fit": keywords = "fill contain cover none scale-down"
    case "border-collapse": keywords = "collapse separate"
    case "table-layout": keywords = "auto fixed"
    case "font-kerning": keywords = "auto normal none"
    case "font-style": keywords = "normal italic oblique"
    case "direction": keywords = "ltr rtl"
    case "white-space": keywords = "normal nowrap pre pre-wrap pre-line break-spaces"
    case "overflow-wrap", "word-wrap": keywords = "normal break-word anywhere"
    case "word-break": keywords = "normal break-all break-word"
    case "text-transform": keywords = "none uppercase lowercase capitalize"
    case "scroll-behavior": keywords = "auto smooth"
    case "all": return false, true // only CSS-wide keywords, handled above
    }
    if keywords != "" {
        for k in strings.fields(keywords, context.temp_allocator) do if v == k do return true, true
        // overflow's shorthand accepts an independent x/y pair.
        if prop == "overflow" {
            parts := split_top_level(v)
            if len(parts) == 2 {
                a, _ := css_value_valid("overflow-x", parts[0])
                b, _ := css_value_valid("overflow-y", parts[1])
                return a && b, true
            }
        }
        return false, true
    }
    switch prop {
    case "aspect-ratio":
        parts := split_top_level(v)
        if len(parts) > 0 && parts[0] == "auto" { v = strings.trim_space(v[4:]) }
        if v == "" do return true, true
        slash := strings.index_byte(v, '/')
        if slash < 0 {
            n, ok := css_number(v)
            return ok && n >= 0, true
        }
        a, ak := css_number(strings.trim_space(v[:slash]))
        b, bk := css_number(strings.trim_space(v[slash+1:]))
        return ak && bk && a >= 0 && b >= 0, true
    case "border-width", "border-style", "border-color":
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > 4 do return false, true
        longhand := "border-top-width"
        if prop == "border-style" do longhand = "border-top-style"
        if prop == "border-color" do longhand = "border-top-color"
        for p in parts {
            ok, _ := css_value_valid(longhand, p)
            if !ok do return false, true
        }
        return true, true
    case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style", "outline-style":
        styles := []string{"none", "hidden", "dotted", "dashed", "solid", "double", "groove", "ridge", "inset", "outset"}
        for k in styles do if v == k do return true, true
        return prop == "outline-style" && v == "auto", true
    case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "outline-width":
        if v == "thin" || v == "medium" || v == "thick" do return true, true
        if strings.contains(v, "%") do return false, true
        return css_value_valid("padding-top", v)
    case "order", "z-index", "column-count":
        if prop != "order" && v == "auto" do return true, true
        n, ok := strconv.parse_i64(v)
        return ok && (prop != "column-count" || n > 0), true
    case "flex-grow", "flex-shrink":
        n, ok := css_number(v)
        return ok && n >= 0, true
    case "opacity":
        if strings.has_suffix(v, "%") {
            _, ok := css_number(v[:len(v)-1])
            return ok, true
        }
        _, ok := css_number(v) // out-of-range numbers are valid and clamped
        return ok, true
    case "color", "background-color", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color", "outline-color", "text-decoration-color", "caret-color", "accent-color":
        if v == "transparent" || v == "currentcolor" do return true, true
        if (prop == "caret-color" || prop == "accent-color") && v == "auto" do return true, true
        _, ok := csspkg.parse_color(v)
        return ok, true
    }
    // Length/percentage grammars. Plain non-zero numbers are not lengths.
    count := 0
    negative, auto, intrinsic, none := false, false, false, false
    switch prop {
    case "width", "height", "min-width", "min-height": count = 1; auto = true; intrinsic = true
    case "max-width", "max-height": count = 1; none = true; intrinsic = true
    case "flex-basis": count = 1; auto = true; intrinsic = true
    case "top", "right", "bottom", "left": count = 1; auto = true; negative = true
    case "inset", "margin": count = 4; auto = true; negative = true
    case "margin-top", "margin-right", "margin-bottom", "margin-left": count = 1; auto = true; negative = true
    case "padding": count = 4
    case "padding-top", "padding-right", "padding-bottom", "padding-left": count = 1
    case "gap", "grid-gap": count = 2
    case "row-gap", "column-gap", "grid-row-gap", "grid-column-gap": count = 1
    }
    if count > 0 {
        parts := split_top_level(v)
        if len(parts) < 1 || len(parts) > count do return false, true
        for p in parts {
            if auto && p == "auto" do continue
            if none && p == "none" do continue
            if intrinsic && (p == "min-content" || p == "max-content" || p == "fit-content" || (prop == "flex-basis" && p == "content")) do continue
            if (strings.contains(prop, "gap")) && p == "normal" do continue
            if n, ok := css_number(p); ok {
                if n != 0 do return false, true
            }
            if !strings.contains(p, "(") && len(strings.fields(p, context.temp_allocator)) != 1 do return false, true
            off, pct, _, ok := parse_len_clamped(p, 16)
            if !ok do return false, true
            // A math function may compute negative later; CSS clamps it then.
            if !negative && !strings.contains(p, "(") && (off < 0 || pct < 0) do return false, true
        }
        return true, true
    }
    return true, false
}

// Reject broken component values without interpreting text inside strings.
css_value_balanced :: proc(v: string) -> bool {
    stack := make([dynamic]u8, context.temp_allocator)
    quote: u8
    for i := 0; i < len(v); i += 1 {
        c := v[i]
        if c == '\\' { i += 1; continue }
        if quote != 0 {
            if c == quote do quote = 0
            else if c == '\n' || c == '\r' do return false
            continue
        }
        switch c {
        case '\'', '"': quote = c
        case '(', '[', '{': append(&stack, c)
        case ')', ']', '}':
            if len(stack) == 0 do return false
            open := stack[len(stack)-1]
            if (c == ')' && open != '(') || (c == ']' && open != '[') || (c == '}' && open != '{') do return false
            resize(&stack, len(stack)-1)
        case ';', '!': if len(stack) == 0 do return false
        }
    }
    return quote == 0 && len(stack) == 0
}

css_number :: proc(v: string) -> (f64, bool) {
    if v == "" do return 0, false
    if csspkg.scan_number_end(v, 0, true) != len(v) do return 0, false
    return strconv.parse_f64(v)
}

// Called for EVERY declaration, before duplicate handling or cascade priority.
css_declaration_valid :: proc(prop, value: string) -> bool {
    valid, _ := css_value_valid(prop, value)
    return valid
}

@(init)
install_css_value_validation :: proc "contextless" () {
    csspkg.g_value_valid = css_declaration_valid
    jspkg.g_css_value_valid = css_declaration_valid
    jspkg.g_css_condition_supports = csspkg.supports_condition
}
