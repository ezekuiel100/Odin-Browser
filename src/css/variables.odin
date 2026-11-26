package css

import "core:strings"

// Empty is a valid custom-property value. Keep failure distinct from it and
// from an absent entry, including while inheriting an invalid computed value.
VARIABLE_INVALID :: "\x00"
VARIABLE_MAX_BYTES :: 1024 * 1024
VARIABLE_MAX_DEPTH :: 256

@(private="file")
variable_boundary_needed :: proc(a, b: u8) -> bool {
    left := token_name_byte(a) || a == '.' || a == '+' || a == '#' || a == '@' || a == '\\'
    right := token_name_byte(b) || b == '.' || b == '%' || b == '(' || b == '\\'
    return (left && right) || (a == '/' && b == '*')
}

variable_name_valid :: proc(name: string) -> bool {
    if len(name) <= 2 || !strings.has_prefix(name, "--") do return false
    l := Tokenizer{source = name}
    t := next_token(&l)
    return t.kind == .Name && t.end == len(name)
}

// The first argument is exactly one dashed identifier; the entire remainder
// after the first top-level comma is the fallback (which may be empty).
variable_arguments :: proc(inner: string) -> (name, fallback: string, has_fallback, ok: bool) {
    comma := token_index_top(inner, ',')
    head := inner
    if comma >= 0 { head = inner[:comma]; fallback = inner[comma+1:]; has_fallback = true }
    if has_fallback && (token_index_top(fallback, ';') >= 0 || token_index_top(fallback, '!') >= 0) do return "", "", false, false
    head = strings.trim_space(head)
    if !variable_name_valid(head) do return "", "", false, false
    name = declaration_text(head)
    return name, fallback, has_fallback, true
}

// Walk tokens, including unused fallbacks. Quoted text and longer identifiers
// such as myvar() are opaque. Function names are ASCII case-insensitive; custom
// property names retain their case.
variable_syntax :: proc(value: string) -> (has_var, valid: bool) {
    l := Tokenizer{source = value}
    for {
        t := next_token(&l)
        if t.kind == .EOF do return has_var, true
        if t.kind == .Bad do return has_var, false
        if t.kind != .Name || t.end >= len(value) || value[t.end] != '(' do continue
        if !strings.equal_fold(declaration_text(value[t.start:t.end]), "var") do continue
        has_var = true
        end := token_group_end(value, t.end)
        if end < 0 do return true, false
        _, _, _, ok := variable_arguments(value[t.end+1:end])
        if !ok do return true, false
    }
}

// Substitute an already computed variable environment. Boundaries are kept as
// whitespace so a number and an adjacent identifier can never become a length
// token (var(--n)px). The engine's value parsers consume this token serialization.
substitute_vars :: proc(value: string, props: map[string]string, depth := 0) -> (string, bool) {
    if value == VARIABLE_INVALID || depth >= VARIABLE_MAX_DEPTH || len(value) > VARIABLE_MAX_BYTES do return VARIABLE_INVALID, false
    has_var, valid := variable_syntax(value)
    if !valid do return VARIABLE_INVALID, false
    if !has_var do return value, true
    l := Tokenizer{source = value}
    b := strings.builder_make(context.temp_allocator)
    start := 0
    for {
        t := next_token(&l)
        if t.kind == .EOF do break
        if t.kind != .Name || t.end >= len(value) || value[t.end] != '(' do continue
        if !strings.equal_fold(declaration_text(value[t.start:t.end]), "var") do continue
        end := token_group_end(value, t.end)
        name, fallback, has_fallback, _ := variable_arguments(value[t.end+1:end])
        replacement, found := props[name]
        if !found || replacement == VARIABLE_INVALID || strings.equal_fold(strings.trim_space(replacement), "initial") {
            if !has_fallback do return VARIABLE_INVALID, false
            ok: bool
            replacement, ok = substitute_vars(fallback, props, depth+1)
            if !ok do return VARIABLE_INVALID, false
        }
        if strings.builder_len(b) + t.start-start + len(replacement) + 2 > VARIABLE_MAX_BYTES do return VARIABLE_INVALID, false
        strings.write_string(&b, value[start:t.start])
        if t.start > 0 && (replacement == "" || variable_boundary_needed(value[t.start-1], replacement[0])) do strings.write_byte(&b, ' ')
        strings.write_string(&b, replacement)
        if end+1 < len(value) && (replacement == "" || variable_boundary_needed(replacement[len(replacement)-1], value[end+1])) do strings.write_byte(&b, ' ')
        start = end+1
        l.pos = start
    }
    if strings.builder_len(b) + len(value)-start > VARIABLE_MAX_BYTES do return VARIABLE_INVALID, false
    strings.write_string(&b, value[start:])
    return strings.trim_space(strings.to_string(b)), true
}

@(private="file")
Variable_Resolver :: struct {
    raw, computed: map[string]string,
    state: map[string]u8,
    cyclic: map[string]bool,
    stack: [dynamic]string,
}

@(private="file")
compute_variable :: proc(r: ^Variable_Resolver, name: string) {
    switch r.state[name] {
    case 2: return
    case 1:
        // Invalidate every member of the cycle, even when a fallback would
        // otherwise hide the reference that closed it.
        in_cycle := false
        for key in r.stack {
            if key == name do in_cycle = true
            if in_cycle do r.cyclic[key] = true
        }
        return
    }
    value, found := r.raw[name]
    if !found do return
    value, _ = split_important(value)
    if len(r.stack) >= VARIABLE_MAX_DEPTH {
        r.computed[name] = VARIABLE_INVALID; r.state[name] = 2; return
    }
    r.state[name] = 1
    append(&r.stack, name)
    // All references are graph edges, including those in unused fallbacks.
    l := Tokenizer{source = value}
    for {
        t := next_token(&l)
        if t.kind == .EOF || t.kind == .Bad do break
        if t.kind != .Name || t.end >= len(value) || value[t.end] != '(' do continue
        if !strings.equal_fold(declaration_text(value[t.start:t.end]), "var") do continue
        end := token_group_end(value, t.end)
        if end < 0 do break
        dep, _, _, ok := variable_arguments(value[t.end+1:end])
        if ok do compute_variable(r, dep)
    }
    resolved, ok := substitute_vars(value, r.computed)
    if !ok || r.cyclic[name] || strings.equal_fold(strings.trim_space(value), "initial") do resolved = VARIABLE_INVALID
    r.computed[name] = resolved
    r.state[name] = 2
    resize(&r.stack, len(r.stack)-1)
}

// `inherited` is immutable and already computed. Only declarations from this
// element form a dependency graph: descendants cannot rebind a parent's var().
compute_custom_properties :: proc(declarations: map[string]string, inherited: map[string]string = nil) -> map[string]string {
    r := Variable_Resolver{
        raw = declarations,
        computed = make(map[string]string, len(inherited)+len(declarations), context.temp_allocator),
        state = make(map[string]u8, context.temp_allocator),
        cyclic = make(map[string]bool, context.temp_allocator),
        stack = make([dynamic]string, context.temp_allocator),
    }
    for name, value in inherited { r.computed[name] = value; r.state[name] = 2 }
    for name in declarations do r.state[name] = 0
    for name in declarations do compute_variable(&r, name)
    return r.computed
}
