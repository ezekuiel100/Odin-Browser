package css
selector_ascii_lower :: proc(s: string) -> string {
    b := make([]u8, len(s), context.temp_allocator)
    for c, i in transmute([]u8)s {
        b[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
    }
    return string(b)
}
