package js

import "core:strings"

// Literal replacements also search UTF-16 units (a surrogate can be the needle).
string_replace_impl :: proc(vm: ^Interp, s, search: string, replacement: Value, all: bool) -> Value {
    fn, is_fn := replacement.(^Function)
    text := ""
    if !is_fn { text = to_js_string(vm, replacement); if vm.throwing do return nil }
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    n, size := str_rlen(s), str_rlen(search)
    last, start := 0, 0
    for start <= n {
        found := js_string_find(s, search, start)
        if found < 0 do break
        strings.write_string(&sb, str_rslice(s, last, found))
        if is_fn {
            result := call_function(vm, fn, nil, []Value{Value(search), f64(found), Value(s)})
            if vm.throwing do return nil
            converted := to_js_string(vm, result)
            if vm.throwing do return nil
            strings.write_string(&sb, converted)
        } else { write_str_replacement(&sb, text, s, found, size) }
        last = found + size
        if !all do break
        start = found + max(1,size)
    }
    strings.write_string(&sb, str_rslice(s, last, n))
    return own_str(vm, strings.to_string(sb))
}
