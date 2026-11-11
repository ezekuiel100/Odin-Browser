package css

import "core:strings"

// Locate a declaration separator, respecting strings, escapes and groups.
declaration_end :: proc(s: string) -> int {
    return token_index_top(s, ';')
}

// Normalize name escapes without turning escaped punctuation into syntax.
// Quoted strings and their escapes must remain byte-for-byte intact.
// Results are temporary, like the source used by the stylesheet parser.
declaration_text :: proc(raw: string) -> string {
    s := strip_comments(raw, context.temp_allocator)
    b := strings.builder_make(context.temp_allocator)
    l := Tokenizer{source = s}
    for {
        t := next_token(&l)
        if t.kind == .EOF do break
        if t.kind != .Name { strings.write_string(&b, s[t.start:t.end]); continue }
        i := t.start
        for i < t.end {
            if s[i] == '\\' {
                cp, end, ok := consume_escape(s, i)
                if ok && ((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || cp == '-' || cp == '_' || cp >= 128) {
                    strings.write_rune(&b, cp)
                } else { strings.write_string(&b, s[i:end]) }
                i = end
            } else { strings.write_byte(&b, s[i]); i += 1 }
        }
    }
    return strings.to_string(b)
}
