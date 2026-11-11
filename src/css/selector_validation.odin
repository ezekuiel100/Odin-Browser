package css

import "core:strings"

// Shared syntax validation for stylesheets, DOM queries and feature detection.
// Rendering retains recovered structures but disables invalid selector lists.
selectors_valid :: proc(text: string) -> bool {
    return selector_list_valid(text, false, false, 0)
}

selector_list_valid :: proc(text: string, forgiving, relative: bool, depth: int) -> bool {
    if depth > 64 do return false
    any := false
    for raw in split_selector_list_top(text) {
        ok := selector_complex_valid(strings.trim_space(raw), relative, depth)
        if !ok && !forgiving do return false
        any = any || ok
    }
    return any || forgiving
}

selector_hex :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

selector_ident :: proc(s: string, pos: ^int) -> bool {
    if pos^ >= len(s) do return false
    c := s[pos^]
    if c == '-' {
        pos^ += 1
        if pos^ >= len(s) do return false
        c = s[pos^]
    }
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-' || c >= 128 || c == '\\') do return false
    for pos^ < len(s) {
        c = s[pos^]
        if c == '\\' {
            pos^ += 1
            if pos^ >= len(s) || s[pos^] == '\n' || s[pos^] == '\r' || s[pos^] == '\f' do return false
            count := 0
            for pos^ < len(s) && selector_hex(s[pos^]) && count < 6 { pos^ += 1; count += 1 }
            if count == 0 do pos^ += 1
            else if pos^ < len(s) && is_space(s[pos^]) do pos^ += 1
        } else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c >= 128 {
            pos^ += 1
        } else { break }
    }
    return true
}

// Quote and escape aware group scanner; rejects mismatched delimiters.
selector_group_end :: proc(s: string, open: int, depth: int = 0) -> int {
    if depth > 64 do return -1
    close := s[open] == '[' ? u8(']') : u8(')')
    i := open + 1
    for i < len(s) {
        c := s[i]
        if c == '\\' { i += 2; continue }
        if c == '"' || c == '\'' {
            quote := c; i += 1
            for i < len(s) && s[i] != quote {
                if s[i] == '\\' do i += 1
                else if s[i] == '\n' || s[i] == '\r' do return -1
                i += 1
            }
            if i >= len(s) do return -1
        } else if c == '[' || c == '(' {
            i = selector_group_end(s, i, depth+1)
            if i < 0 do return -1
        } else if c == close { return i
        } else if c == ']' || c == ')' { return -1 }
        i += 1
    }
    return -1
}

selector_attr_valid :: proc(s: string) -> bool {
    i := 0
    for i < len(s) && is_space(s[i]) do i += 1
    if !selector_ident(s, &i) do return false
    for i < len(s) && is_space(s[i]) do i += 1
    if i == len(s) do return true
    if s[i] != '=' {
        if !strings.contains("~|^$*", s[i:i+1]) do return false
        i += 1
    }
    if i >= len(s) || s[i] != '=' do return false
    i += 1
    for i < len(s) && is_space(s[i]) do i += 1
    if i >= len(s) do return false
    if s[i] == '"' || s[i] == '\'' {
        quote := s[i]; i += 1
        for i < len(s) && s[i] != quote {
            if s[i] == '\\' do i += 1
            i += 1
        }
        if i >= len(s) do return false
        i += 1
    } else if !selector_ident(s, &i) { return false }
    start := i
    for i < len(s) && is_space(s[i]) do i += 1
    if i == len(s) do return true
    if i == start || (s[i] != 'i' && s[i] != 'I' && s[i] != 's' && s[i] != 'S') do return false
    i += 1
    for i < len(s) && is_space(s[i]) do i += 1
    return i == len(s)
}

selector_complex_valid :: proc(s: string, relative: bool, depth: int) -> bool {
    if s == "" do return false
    i := 0
    if relative && (s[0] == '>' || s[0] == '+' || s[0] == '~') {
        i += 1
        for i < len(s) && is_space(s[i]) do i += 1
    }
    for i < len(s) {
        count := 0
        pseudo_element := false
        if s[i] == '*' { i += 1; count += 1
        } else if s[i] != '.' && s[i] != '#' && s[i] != '[' && s[i] != ':' {
            if !selector_ident(s, &i) do return false
            count += 1
        }
        for i < len(s) && !is_sel_boundary(s[i]) {
            if pseudo_element do return false
            c := s[i]; i += 1
            switch c {
            case '.', '#':
                if !selector_ident(s, &i) do return false
            case '[':
                end := selector_group_end(s, i-1)
                if end < 0 || !selector_attr_valid(s[i:end]) do return false
                i = end+1
            case ':':
                double := i < len(s) && s[i] == ':'
                if double do i += 1
                start := i
                if !selector_ident(s, &i) do return false
                name := strings.to_lower(s[start:i], context.temp_allocator)
                functional := i < len(s) && s[i] == '('
                arg := ""
                if functional {
                    end := selector_group_end(s, i)
                    if end < 0 do return false
                    arg = s[i+1:end]; i = end+1
                }
                if double || name == "before" || name == "after" || name == "first-line" || name == "first-letter" {
                    if functional || (name != "before" && name != "after" && name != "first-line" && name != "first-letter" && name != "selection" && name != "marker" && name != "placeholder" && !is_ignored_pseudo_element(name)) do return false
                    pseudo_element = true
                } else {
                    switch name {
                    case "is", "where", "matches", "-webkit-any":
                        if !functional || !selector_list_valid(arg, true, false, depth+1) do return false
                    case "not", "has":
                        if !functional || !selector_list_valid(arg, false, name == "has", depth+1) do return false
                    case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
                        formula, filter := split_nth_filter(arg)
                        if formula != arg {
                            if name != "nth-child" && name != "nth-last-child" do return false
                            if !selector_list_valid(filter, false, false, depth+1) do return false
                        }
                        _, _, ok := parse_nth(formula)
                        if !functional || !ok do return false
                    case "dir":
                        if !functional || (strings.trim_space(arg) != "ltr" && strings.trim_space(arg) != "rtl") do return false
                    case "root", "scope", "empty", "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type",
                         "link", "any-link", "valid", "in-range", "defined", "placeholder-shown", "default",
                         "hover", "focus", "focus-visible", "focus-within", "active", "checked", "disabled", "enabled", "required", "optional", "read-only", "read-write":
                        if functional do return false
                    case:
                        if functional || !pseudo_never_matches(name) do return false
                    }
                }
            case: return false
            }
            count += 1
        }
        if count == 0 do return false
        spaced := false
        for i < len(s) && is_space(s[i]) { i += 1; spaced = true }
        if i == len(s) do return true
        if pseudo_element do return false
        if s[i] == '>' || s[i] == '+' || s[i] == '~' {
            i += 1
            for i < len(s) && is_space(s[i]) do i += 1
            if i == len(s) do return false
        } else if !spaced { return false }
    }
    return false
}
