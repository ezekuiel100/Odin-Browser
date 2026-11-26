package ui

import "core:strings"
import css "../css"

css_logical_property_known :: proc(prop: string) -> bool {
    switch prop {
    case "inline-size", "block-size", "min-inline-size", "min-block-size", "max-inline-size", "max-block-size",
         "margin-inline", "margin-block", "margin-inline-start", "margin-inline-end", "margin-block-start", "margin-block-end",
         "padding-inline", "padding-block", "padding-inline-start", "padding-inline-end", "padding-block-start", "padding-block-end",
         "inset-inline", "inset-block", "inset-inline-start", "inset-inline-end", "inset-block-start", "inset-block-end": return true
    }
    return false
}

css_value_property :: proc(prop: string) -> string {
    if strings.has_prefix(prop, "--") do return prop
    for prefix in ([]string{"-webkit-", "-moz-", "-ms-", "-o-"}) {
        if strings.has_prefix(prop, prefix) {
            base := prop[len(prefix):]
            if css_prop_is_known(base) do return base
        }
    }
    return prop
}

// Type-check the arithmetic accepted by the length evaluator. Runtime values
// and viewport/font conversion remain there; this prevents mixing a scalar
// with a length in addition, multiplying two lengths, or dividing by a length.
css_math_type :: proc(raw: string, depth := 0) -> (scalar, percent, valid: bool) {
    if depth >= 64 do return false, false, false
    v := strings.trim_space(raw)
    if v == "" do return false, false, false
    parens := 0
    add, mul := -1, -1
    for i := len(v)-1; i >= 0; i -= 1 {
        c := v[i]
        if c == ')' { parens += 1; continue }
        if c == '(' { parens -= 1; continue }
        if parens != 0 do continue
        if (c == '+' || c == '-') && i > 0 && i+1 < len(v) {
            if strings.index_byte(" \t\n\r\f", v[i-1]) >= 0 && strings.index_byte(" \t\n\r\f", v[i+1]) >= 0 && add < 0 do add = i
        } else if (c == '*' || c == '/') && mul < 0 { mul = i }
    }
    at := add >= 0 ? add : mul
    if at >= 0 {
        a, ap, ak := css_math_type(v[:at], depth+1)
        b, bp, bk := css_math_type(v[at+1:], depth+1)
        if !ak || !bk do return false, false, false
        switch v[at] {
        case '+', '-': return a && b, ap || bp, a == b
        case '*': return a && b, ap || bp, a || b
        case '/': return a, ap, b
        }
    }
    if v[0] == '(' && css.token_group_end(v, 0) == len(v)-1 do return css_math_type(v[1:len(v)-1], depth+1)
    if open := strings.index_byte(v, '('); open > 0 {
        if css.token_group_end(v, open) != len(v)-1 do return false, false, false
        name, inner := v[:open], v[open+1:len(v)-1]
        if name == "calc" do return css_math_type(inner, depth+1)
        if name != "min" && name != "max" && name != "clamp" do return false, false, false
        args := css_value_commas(inner)
        if len(args) == 0 || (name == "clamp" && len(args) != 3) do return false, false, false
        result, pct := false, false
        for arg, i in args {
            s, p, ok := css_math_type(arg, depth+1)
            if !ok || (i > 0 && result != s) do return false, false, false
            result = s; pct = pct || p
        }
        return result, pct, true
    }
    if _, ok := css_number(v); ok do return true, false, true
    end := css.scan_number_end(v, 0, true)
    if end == 0 || end >= len(v) do return false, false, false
    unit := v[end:]
    if !css_value_keyword(unit, "px em rem ex ch lh rlh vw vh vmin vmax svw svh lvw lvh dvw dvh pt pc in cm mm q %") do return false, false, false
    return false, unit == "%", true
}

css_value_logical :: proc(prop, v: string) -> (bool, bool) {
    switch prop {
    case "inline-size", "block-size": return css_value_valid("width", v)
    case "min-inline-size", "min-block-size": return css_value_valid("min-width", v)
    case "max-inline-size", "max-block-size": return css_value_valid("max-width", v)
    }
    if !strings.has_prefix(prop, "margin-") && !strings.has_prefix(prop, "padding-") && !strings.has_prefix(prop, "inset-") { return true, false }
    for base in ([]string{"margin", "padding", "inset"}) {
        for axis in ([]string{"inline", "block"}) {
            pair := strings.concatenate({base, "-", axis}, context.temp_allocator)
            if prop != pair && prop != strings.concatenate({pair, "-start"}, context.temp_allocator) &&
               prop != strings.concatenate({pair, "-end"}, context.temp_allocator) { continue }
            longhand := base == "inset" ? "left" : strings.concatenate({base, "-left"}, context.temp_allocator)
            parts := split_top_level(v)
            if len(parts) < 1 || len(parts) > (prop == pair ? 2 : 1) do return false, true
            for p in parts {
                if css_value_keyword(p, "inherit initial unset revert revert-layer") do return false, true
                if ok, _ := css_value_valid(longhand, p); !ok do return false, true
            }
            return true, true
        }
    }
    return true, false
}
