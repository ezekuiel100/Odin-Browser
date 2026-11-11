package css

import "core:strings"

// The `of` delimiter precedes the selector grammar, so whitespace tokens
// suffice here; never search inside the selector list itself.
split_nth_filter :: proc(arg: string) -> (formula, filter: string) {
    selector_ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }
    i := 0
    for i < len(arg) {
        for i < len(arg) && selector_ws(arg[i]) do i += 1
        start := i
        for i < len(arg) && !selector_ws(arg[i]) do i += 1
        if strings.equal_fold(arg[start:i], "of") {
            return strings.trim_space(arg[:start]), strings.trim_space(arg[i:])
        }
    }
    return arg, ""
}
