#+build windows
package js

import "core:strings"

// ICU is supplied by Windows (already used by time zones and text layout).
foreign import icu_collation "system:icu.lib"
@(default_calling_convention = "system")
foreign icu_collation {
    ucol_open :: proc(locale: cstring, status: ^i32) -> rawptr ---
    ucol_close :: proc(coll: rawptr) ---
    ucol_getAttribute :: proc(coll: rawptr, attribute: i32, status: ^i32) -> i32 ---
    ucol_setAttribute :: proc(coll: rawptr, attribute, value: i32, status: ^i32) ---
    ucol_strcollUTF8 :: proc(coll: rawptr, x: rawptr, nx: i32, y: rawptr, ny: i32, status: ^i32) -> i32 ---
    uloc_forLanguageTag :: proc(tag: cstring, locale: ^u8, capacity: i32, parsed: ^i32, status: ^i32) -> i32 ---
}

collation_compare :: proc(vm: ^Interp, o: Collation_Options, x, y: string, resolved: ^Collation_Options = nil) -> Value {
    status: i32
    parsed: i32
    locale: [512]u8
    tag := strings.clone_to_cstring(o.locale)
    defer delete(tag)
    uloc_forLanguageTag(tag, &locale[0], i32(len(locale)), &parsed, &status)
    if status > 0 || parsed != i32(len(o.locale)) || parsed == 0 {
        collation_error(vm, "Invalid collation locale"); return nil
    }
    id := string(locale[:])
    end := strings.index_byte(id, 0)
    if end >= 0 do id = id[:end]
    if o.usage == "search" {
        separator := strings.contains(id, "@") ? ";" : "@"
        id = strings.concatenate({id, separator, "collation=search"})
        defer delete(id)
    }
    name := strings.clone_to_cstring(id)
    defer delete(name)
    // Negative ICU status codes are successful locale fallback warnings.
    status = 0
    coll := ucol_open(name, &status)
    if coll == nil || status > 0 {
        collation_error(vm, "Unable to open collation locale"); return nil
    }
    defer ucol_close(coll)
    status = 0
    strength: i32 = 2 // UCOL_TERTIARY
    switch o.sensitivity {
    case "base", "case": strength = 0 // UCOL_PRIMARY
    case "accent": strength = 1 // UCOL_SECONDARY
    }
    ucol_setAttribute(coll, 5, strength, &status) // UCOL_STRENGTH
    ucol_setAttribute(coll, 3, o.sensitivity == "case" ? 17 : 16, &status) // CASE_LEVEL
    ucol_setAttribute(coll, 4, 17, &status) // NORMALIZATION_MODE = ON
    if o.numeric_set do ucol_setAttribute(coll, 7, o.numeric ? 17 : 16, &status)
    if o.case_first_set {
        first: i32 = 16 // OFF
        if o.case_first == "upper" do first = 25
        if o.case_first == "lower" do first = 24
        ucol_setAttribute(coll, 2, first, &status)
    }
    ucol_setAttribute(coll, 1, o.punctuation ? 20 : 21, &status) // ALTERNATE_HANDLING
    if resolved != nil {
        resolved^ = o
        resolved.numeric = ucol_getAttribute(coll, 7, &status) == 17
        switch ucol_getAttribute(coll, 2, &status) {
        case 24: resolved.case_first = "lower"
        case 25: resolved.case_first = "upper"
        case: resolved.case_first = "false"
        }
    }
    result := ucol_strcollUTF8(coll, raw_data(x), i32(len(x)), raw_data(y), i32(len(y)), &status)
    if status > 0 { collation_error(vm, "Unable to compare strings"); return nil }
    return f64(result)
}
