package css

import "core:strings"

// Locate a declaration separator, respecting strings, escapes and groups.
declaration_end :: proc(s: string) -> int {
    depth := 0
    quote: u8
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if c == '\\' { i += 1; continue }
        if quote != 0 {
            if c == quote do quote = 0
            continue
        }
        switch c {
        case '\'', '"': quote = c
        case '(', '[', '{': depth += 1
        case ')', ']', '}': depth -= 1
        case ';': if depth == 0 do return i
        }
    }
    return -1
}

// Normalize name escapes without turning escaped punctuation into syntax.
// Quoted strings and their escapes must remain byte-for-byte intact.
// Results are temporary, like the source used by the stylesheet parser.
declaration_text :: proc(raw: string) -> string {
    s := strip_comments(raw, context.temp_allocator)
    b := strings.builder_make(context.temp_allocator)
    quote: u8
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if c == '\\' {
            cp, next, ok := layer_escape(s, i)
            if quote == 0 && ok && ((cp >= 'a' && cp <= 'z') ||
                (cp >= 'A' && cp <= 'Z') || cp == '-' || cp == '_' || cp >= 128) {
                strings.write_rune(&b, cp)
            } else {
                strings.write_string(&b, s[i:min(next, len(s))])
            }
            i = max(i, next-1)
            continue
        }
        if quote != 0 {
            if c == quote do quote = 0
        } else if c == '\'' || c == '"' { quote = c }
        strings.write_byte(&b, c)
    }
    return strings.to_string(b)
}
