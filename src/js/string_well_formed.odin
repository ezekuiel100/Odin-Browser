package js

import "core:strings"
import "core:unicode/utf8"

// WTF-8 retains lone UTF-16 surrogates instead of losing them to U+FFFD.
// Valid Unicode keeps its existing UTF-8 representation.
write_js_rune :: proc(sb: ^strings.Builder, r: rune) {
    if r >= 0xD800 && r <= 0xDFFF {
        strings.write_byte(sb, u8(0xE0 | (u32(r) >> 12)))
        strings.write_byte(sb, u8(0x80 | ((u32(r) >> 6) & 63)))
        strings.write_byte(sb, u8(0x80 | (u32(r) & 63)))
    } else { strings.write_rune(sb, r) }
}

decode_js_rune :: proc(s: string) -> (rune, int) {
    if len(s) >= 3 && s[0] == 0xED && s[1] >= 0xA0 && s[1] <= 0xBF && s[2] >= 0x80 && s[2] <= 0xBF {
        return rune((u32(s[0] & 15) << 12) | (u32(s[1] & 63) << 6) | u32(s[2] & 63)), 3
    }
    return utf8.decode_rune(s)
}

str_well_formed :: proc(vm: ^Interp, this: Value, repair: bool) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String method called on null or undefined"); return nil }
    s := collation_string(vm, this)
    if vm.throwing do return nil
    sb: strings.Builder
    if repair do strings.builder_init(&sb)
    defer if repair do strings.builder_destroy(&sb)
    for i := 0; i < len(s); {
        r, width := decode_js_rune(s[i:])
        i += width
        if r >= 0xD800 && r <= 0xDFFF {
            if r <= 0xDBFF && i < len(s) {
                lo, lw := decode_js_rune(s[i:])
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    if repair do strings.write_rune(&sb, rune(0x10000 + ((r-0xD800) << 10) + lo-0xDC00))
                    i += lw
                    continue
                }
            }
            if !repair do return false
            r = 0xFFFD
        }
        if repair do strings.write_rune(&sb, r)
    }
    if repair do return own_str(vm, strings.to_string(sb))
    return true
}

str_is_well_formed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return str_well_formed(vm, this, false) }
str_to_well_formed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return str_well_formed(vm, this, true) }
