package css

import "core:strings"
import "core:unicode/utf8"

// Structural CSS tokens retain source spans. Consumers decide grammar and
// recovery; strings, comments and escaped punctuation never become delimiters.
Token_Kind :: enum { EOF, Space, Comment, Name, String, Delim, Bad }
Token :: struct { kind: Token_Kind, start, end: int, delim: u8 }
Tokenizer :: struct { source: string, pos: int }

token_hex :: proc(c: u8) -> int {
    if c >= '0' && c <= '9' do return int(c - '0')
    if c >= 'a' && c <= 'f' do return int(c - 'a') + 10
    if c >= 'A' && c <= 'F' do return int(c - 'A') + 10
    return -1
}

consume_escape :: proc(s: string, start: int) -> (cp: rune, end: int, ok: bool) {
    i := start + 1
    if i >= len(s) || s[i] == '\n' || s[i] == '\r' || s[i] == '\f' do return 0, i, false
    if token_hex(s[i]) < 0 {
        r, size := utf8.decode_rune_in_string(s[i:])
        return r, i + size, true
    }
    value, digits := 0, 0
    for i < len(s) && digits < 6 {
        h := token_hex(s[i])
        if h < 0 do break
        value = value * 16 + h
        i += 1; digits += 1
    }
    if i < len(s) && is_space(s[i]) {
        cr := s[i] == '\r'; i += 1
        if cr && i < len(s) && s[i] == '\n' do i += 1
    }
    if value == 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff) do value = 0xfffd
    return rune(value), i, true
}

token_name_byte :: proc(c: u8) -> bool {
    return c >= 128 || c == '_' || c == '-' || (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

next_token :: proc(l: ^Tokenizer) -> Token {
    s := l.source
    start := l.pos
    if start >= len(s) do return Token{kind = .EOF, start = start, end = start}
    c := s[start]
    l.pos += 1
    kind := Token_Kind.Delim
    if is_space(c) {
        kind = .Space
        for l.pos < len(s) && is_space(s[l.pos]) do l.pos += 1
    } else if c == '/' && l.pos < len(s) && s[l.pos] == '*' {
        kind = .Comment
        end := strings.index(s[l.pos+1:], "*/")
        l.pos = end < 0 ? len(s) : l.pos + 1 + end + 2
    } else if c == '"' || c == '\'' {
        kind = .Bad
        for l.pos < len(s) {
            ch := s[l.pos]
            if ch == c { l.pos += 1; kind = .String; break }
            if ch == '\n' || ch == '\r' || ch == '\f' do break
            if ch == '\\' {
                l.pos += 1
                if l.pos >= len(s) do break
                if s[l.pos] == '\r' {
                    l.pos += 1
                    if l.pos < len(s) && s[l.pos] == '\n' do l.pos += 1
                } else if s[l.pos] == '\n' || s[l.pos] == '\f' { l.pos += 1
                } else { _, end, _ := consume_escape(s, l.pos-1); l.pos = end }
            } else { l.pos += 1 }
        }
    } else if token_name_byte(c) || c == '\\' {
        kind = .Name
        l.pos = start
        for l.pos < len(s) {
            if s[l.pos] == '\\' {
                _, end, ok := consume_escape(s, l.pos)
                if !ok {
                    if l.pos == start { kind = .Bad; l.pos = end }
                    break
                }
                l.pos = end
            } else if token_name_byte(s[l.pos]) { l.pos += 1
            } else { break }
        }
    }
    return Token{kind, start, l.pos, kind == .Delim ? c : 0}
}

token_close :: proc(c: u8) -> u8 {
    switch c { case '(': return ')'; case '[': return ']'; case '{': return '}' }
    return 0
}

// Iterative, bounded stack: malformed nesting cannot overflow the call stack.
token_group_end :: proc(s: string, open: int) -> int {
    if open < 0 || open >= len(s) || token_close(s[open]) == 0 do return -1
    stack: [256]u8
    depth := 0
    l := Tokenizer{source = s, pos = open}
    for {
        t := next_token(&l)
        if t.kind == .EOF || t.kind == .Bad do return -1
        if t.kind != .Delim do continue
        if close := token_close(t.delim); close != 0 {
            if depth == len(stack) do return -1
            stack[depth] = close; depth += 1
        } else if t.delim == ')' || t.delim == ']' || t.delim == '}' {
            if depth == 0 || stack[depth-1] != t.delim do return -1
            depth -= 1
            if depth == 0 do return t.start
        }
    }
}

token_index_top :: proc(s: string, delim: u8) -> int {
    l := Tokenizer{source = s}
    for {
        t := next_token(&l)
        if t.kind == .EOF || t.kind == .Bad do return -1
        if t.kind != .Delim do continue
        if t.delim == delim do return t.start
        if token_close(t.delim) != 0 {
            end := token_group_end(s, t.start)
            if end < 0 do return -1
            l.pos = end + 1
        } else if t.delim == ')' || t.delim == ']' || t.delim == '}' { return -1 }
    }
}

// Find a grammar boundary, returning EOF when absent. In particular, braces
// inside strings, escapes, attribute selectors and functions stay opaque.
token_boundary :: proc(s: string, start: int, delimiters: string) -> int {
    l := Tokenizer{source = s, pos = start}
    for {
        t := next_token(&l)
        if t.kind == .EOF do return len(s)
        if t.kind != .Delim do continue
        if strings.index_byte(delimiters, t.delim) >= 0 do return t.start
        if token_close(t.delim) != 0 {
            end := token_group_end(s, t.start)
            if end < 0 do return len(s)
            l.pos = end + 1
        }
    }
}

tokens_balanced :: proc(s: string) -> bool {
    l := Tokenizer{source = s}
    for {
        t := next_token(&l)
        if t.kind == .EOF do return true
        if t.kind == .Bad do return false
        if t.kind != .Delim do continue
        if token_close(t.delim) != 0 {
            end := token_group_end(s, t.start)
            if end < 0 do return false
            l.pos = end + 1
        } else if t.delim == ')' || t.delim == ']' || t.delim == '}' { return false }
    }
}

token_find_top_keyword :: proc(s, keyword: string) -> int {
    l := Tokenizer{source = s}
    for {
        t := next_token(&l)
        if t.kind == .EOF || t.kind == .Bad do return -1
        if t.kind == .Name && strings.equal_fold(s[t.start:t.end], keyword) do return t.start
        if t.kind == .Delim && token_close(t.delim) != 0 {
            end := token_group_end(s, t.start)
            if end < 0 do return -1
            l.pos = end + 1
        }
    }
}
