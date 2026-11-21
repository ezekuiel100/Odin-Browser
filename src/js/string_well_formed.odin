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

// Keep one byte representation per UTF-16 string: adjacent surrogate halves
// become UTF-8; unpaired halves remain WTF-8. This also makes map keys and
// equality independent of whether a string came from slicing or concatenation.
js_has_surrogate_pair :: proc(s: string) -> bool {
    for i := 0; i + 5 < len(s); i += 1 {
        if s[i] == 0xED && s[i+1] >= 0xA0 && s[i+1] <= 0xAF &&
           s[i+2] >= 0x80 && s[i+2] <= 0xBF && s[i+3] == 0xED &&
           s[i+4] >= 0xB0 && s[i+4] <= 0xBF && s[i+5] >= 0x80 && s[i+5] <= 0xBF { return true }
    }
    return false
}

clone_js_string :: proc(s: string, allocator := context.allocator) -> string {
    if !js_has_surrogate_pair(s) do return strings.clone(s, allocator)
    sb := strings.builder_make(allocator)
    for i := 0; i < len(s); {
        r, w := decode_js_rune(s[i:])
        i += w
        if r >= 0xD800 && r <= 0xDBFF && i < len(s) {
            lo, lw := decode_js_rune(s[i:])
            if lo >= 0xDC00 && lo <= 0xDFFF {
                r = 0x10000 + ((r-0xD800) << 10) + lo-0xDC00
                i += lw
            }
        }
        write_js_rune(&sb, r)
    }
    return strings.to_string(sb)
}

// Temporary decoded representation used by string search and the RegExp VM.
// Unicode regexes consume code points; other operations consume UTF-16 units.
js_string_chars :: proc(s: string, points: bool) -> []rune {
    out := make([dynamic]rune, 0, len(s), context.temp_allocator)
    for i := 0; i < len(s); {
        r, w := decode_js_rune(s[i:])
        i += w
        if points && r >= 0xD800 && r <= 0xDBFF && i < len(s) {
            lo, lw := decode_js_rune(s[i:])
            if lo >= 0xDC00 && lo <= 0xDFFF {
                r = 0x10000 + ((r-0xD800) << 10) + lo-0xDC00
                i += lw
            }
        }
        if !points && r > 0xFFFF {
            v := r - 0x10000
            append(&out, 0xD800 + (v >> 10), 0xDC00 + (v & 1023))
        } else { append(&out, r) }
    }
    return out[:]
}

js_has_astral :: proc(s: string) -> bool {
    for b in transmute([]u8)s do if b >= 0xF0 do return true
    return false
}

// Borrowed slice for ordinary boundaries, temporary WTF-8 for split pairs.
js_unit_boundary :: proc(s: string, index: int) -> (offset: int, half: bool) {
    if index <= 0 do return 0, false
    k := 0
    for i := 0; i < len(s); {
        if k >= index do return i, false
        w := utf8_width(s[i])
        if s[i] >= 0xF0 {
            if k + 1 == index do return i, true
            k += 2
        } else { k += 1 }
        i += w
    }
    return len(s), false
}

// A code-unit index, including matches against one half of an astral character.
js_string_find :: proc(s, needle: string, position: int, backwards := false) -> int {
    n := str_rlen(s)
    pos := clamp(position, 0, n)
    if needle == "" do return pos
    if !backwards && !js_has_astral(s) && !js_has_astral(needle) {
        off := str_rbyte(s, pos)
        found := strings.index(s[off:], needle)
        return str_rindex(s, off+found) if found >= 0 else -1
    }
    chars := js_string_chars(s, false)
    search := js_string_chars(needle, false)
    if len(search) > len(chars) do return -1
    start, end, step := pos, len(chars)-len(search), 1
    if backwards { start = min(pos, end); end = 0; step = -1 }
    for i := start; (i <= end if step > 0 else i >= end); i += step {
        match := true
        for c, j in search do if chars[i+j] != c { match = false; break }
        if match do return i
    }
    return -1
}

js_advance_index :: proc(s: string, index: int, points: bool) -> int {
    if !points do return index + 1
    hi, ok := str_code_unit_at(s, index)
    lo, lok := str_code_unit_at(s, index+1)
    if ok && lok && hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF do return index + 2
    return index + 1
}

// Iteration consumes code points but must preserve an unpaired surrogate.
js_code_point_offsets :: proc(s: string, offsets: ^[dynamic]int) {
    for i := 0; i < len(s); {
        append(offsets, i)
        _, width := decode_js_rune(s[i:])
        i += width
    }
    append(offsets, len(s))
}

js_string_compare :: proc(a, b: string) -> int {
    if !js_has_astral(a) && !js_has_astral(b) do return -1 if a < b else (1 if a > b else 0)
    x, y := js_string_chars(a, false), js_string_chars(b, false)
    for i in 0 ..< min(len(x),len(y)) do if x[i] != y[i] do return -1 if x[i] < y[i] else 1
    return -1 if len(x) < len(y) else (1 if len(x) > len(y) else 0)
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
