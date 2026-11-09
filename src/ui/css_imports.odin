package ui

import "core:strings"
import net "../net"

// Cache de DOWNLOAD, não de ocorrências: cada uso mantém sua posição na cascata.
// A pilha ativa corta apenas ciclos do caminho corrente. Tudo é local à coleta.
CSS_Import_Load :: #type proc(url: string) -> (body: string, ok: bool)
CSS_Import_Cache :: struct { body: string, ok: bool }
CSS_Import_State :: struct {
    cache: map[string]CSS_Import_Cache,
    active: map[string]bool,
    count: ^int,
    load: CSS_Import_Load,
    expansions: int,
}

css_import_state :: proc(count: ^int, load := css_import_download) -> CSS_Import_State {
    return {cache = make(map[string]CSS_Import_Cache, context.temp_allocator),
            active = make(map[string]bool, context.temp_allocator), count = count, load = load}
}

@(private = "file")
css_import_download :: proc(url: string) -> (body: string, ok: bool) {
    r := net.fetch(url)
    defer delete(r.body)
    if !r.ok do return "", false
    return strings.clone(r.body, context.temp_allocator), true
}

css_import_body :: proc(st: ^CSS_Import_State, url: string) -> (string, bool) {
    if v, found := st.cache[url]; found do return v.body, v.ok
    if !url_buscavel(url) || st.count^ >= MAX_SHEETS do return "", false
    st.count^ += 1
    body, ok := st.load(url)
    st.cache[url] = {body, ok}
    return body, ok
}

CSS_Import_Conditions :: struct {
    layer: bool,
    name, supports, media: string,
    ok: bool,
}

@(private = "file")
ci_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0c' }

@(private = "file")
ci_ident_byte :: proc(c: u8) -> bool {
    return c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// Passa um escape CSS, inclusive até seis hexadecimais + whitespace opcional.
@(private = "file")
ci_escape_end :: proc(s: string, at: int) -> int {
    i := at + 1
    for k := 0; i < len(s) && k < 6; k += 1 {
        c := s[i]
        if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') do break
        i += 1
    }
    if i > at + 1 {
        if i < len(s) && ci_space(s[i]) {
            if s[i] == '\r' && i + 1 < len(s) && s[i+1] == '\n' do i += 1
            i += 1
        }
    } else if i < len(s) {
        if s[i] == '\r' && i + 1 < len(s) && s[i+1] == '\n' do i += 1
        i += 1
    }
    return i
}

@(private = "file")
ci_skip :: proc(s: string, at: int) -> int {
    i := at
    for i < len(s) {
        if ci_space(s[i]) { i += 1; continue }
        if i + 1 < len(s) && s[i:i+2] == "/*" {
            end := strings.index(s[i+2:], "*/")
            if end < 0 do return len(s)
            i += end + 4
            continue
        }
        break
    }
    return i
}

@(private = "file")
ci_string_end :: proc(s: string, at: int) -> int {
    i := at + 1
    for i < len(s) {
        if s[i] == s[at] do return i + 1
        if s[i] == '\\' { i = ci_escape_end(s, i); continue }
        if s[i] == '\n' || s[i] == '\r' || s[i] == '\x0c' do return -1
        i += 1
    }
    return -1
}

// Retorna só delimitadores no nível zero; strings, comentários e escapes não
// encerram statements. Uma chave no nível zero encerra o cabeçalho inteiro.
@(private = "file")
ci_end :: proc(s: string, at: int, close: u8) -> int {
    stack := make([dynamic]u8, context.temp_allocator)
    i := at
    for i < len(s) {
        c := s[i]
        if c == '\\' { i = ci_escape_end(s, i); continue }
        if c == '"' || c == '\'' {
            i = ci_string_end(s, i)
            if i < 0 do return -1
            continue
        }
        if c == '/' && i + 1 < len(s) && s[i+1] == '*' {
            i = ci_skip(s, i)
            continue
        }
        if len(stack) == 0 && c == close do return i
        if c == '{' || c == '}' do return -1
        if c == '(' || c == '[' {
            append(&stack, c == '(' ? u8(')') : u8(']'))
        } else if c == ')' || c == ']' {
            if len(stack) == 0 || stack[len(stack)-1] != c do return -1
            resize(&stack, len(stack)-1)
        }
        i += 1
    }
    return -1
}

@(private = "file")
ci_word :: proc(s: string, at: int, word: string) -> bool {
    end := at + len(word)
    return end <= len(s) && strings.equal_fold(s[at:end], word) &&
           (end == len(s) || !ci_ident_byte(s[end]) && s[end] != '\\')
}

// Decodifica somente o endereço; condições preservam a grafia/escapes CSS.
@(private = "file")
ci_unescape :: proc(s: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    i := 0
    for i < len(s) {
        if s[i] != '\\' { strings.write_byte(&b, s[i]); i += 1; continue }
        i += 1
        if i >= len(s) do break
        v, digits := 0, 0
        for i < len(s) && digits < 6 {
            c := s[i]
            d := -1
            if c >= '0' && c <= '9' do d = int(c-'0')
            if c >= 'a' && c <= 'f' do d = int(c-'a') + 10
            if c >= 'A' && c <= 'F' do d = int(c-'A') + 10
            if d < 0 do break
            v = v * 16 + d
            i += 1
            digits += 1
        }
        if digits > 0 {
            if v == 0 || v > 0x10ffff || v >= 0xd800 && v <= 0xdfff do v = 0xfffd
            strings.write_rune(&b, rune(v))
            if i < len(s) && ci_space(s[i]) {
                if s[i] == '\r' && i+1 < len(s) && s[i+1] == '\n' do i += 1
                i += 1
            }
        } else {
            if s[i] == '\r' && i+1 < len(s) && s[i+1] == '\n' do i += 1
            if !ci_space(s[i]) || s[i] == ' ' || s[i] == '\t' do strings.write_byte(&b, s[i])
            i += 1
        }
    }
    return strings.to_string(b)
}

// Assinatura conservada para consumidores/testes existentes.
parse_import_stmt :: proc(stmt: string) -> (url, cond: string) {
    i := ci_skip(stmt, 0)
    if i == len(stmt) do return
    if stmt[i] == '"' || stmt[i] == '\'' {
        end := ci_string_end(stmt, i)
        if end < 0 do return
        return ci_unescape(stmt[i+1:end-1]), strings.trim_space(stmt[end:])
    }
    if !ci_word(stmt, i, "url") || i+3 >= len(stmt) || stmt[i+3] != '(' do return
    i = ci_skip(stmt, i+4)
    if i == len(stmt) do return
    start := i
    if stmt[i] == '"' || stmt[i] == '\'' {
        end := ci_string_end(stmt, i)
        if end < 0 do return
        url = ci_unescape(stmt[i+1:end-1])
        i = ci_skip(stmt, end)
    } else {
        for i < len(stmt) && stmt[i] != ')' && !ci_space(stmt[i]) {
            if stmt[i] == '\\' { i = ci_escape_end(stmt, i); continue }
            if stmt[i] == '(' || stmt[i] == '"' || stmt[i] == '\'' || stmt[i] < 32 do return "", ""
            i += 1
        }
        url = ci_unescape(stmt[start:i])
        i = ci_skip(stmt, i)
    }
    if i >= len(stmt) || stmt[i] != ')' do return "", ""
    cond = strings.trim_space(stmt[i+1:])
    return
}

@(private = "file")
ci_layer_name :: proc(s: string) -> bool {
    i := ci_skip(s, 0)
    for i < len(s) {
        start := i
        if s[i] >= '0' && s[i] <= '9' do return false
        for i < len(s) {
            if s[i] == '\\' {
                if i+1 >= len(s) || ci_space(s[i+1]) do return false
                i = ci_escape_end(s, i)
            } else if ci_ident_byte(s[i]) { i += 1 } else { break }
        }
        if i == start do return false
        i = ci_skip(s, i)
        if i == len(s) do return true
        if s[i] != '.' do return false
        i = ci_skip(s, i+1)
    }
    return false
}

css_import_conditions :: proc(s: string) -> CSS_Import_Conditions {
    c: CSS_Import_Conditions
    i := ci_skip(s, 0)
    if ci_word(s, i, "layer") {
        c.layer = true
        i += 5
        if i < len(s) && s[i] == '(' {
            end := ci_end(s, i+1, ')')
            if end < 0 do return c
            c.name = strings.trim_space(s[i+1:end])
            if !ci_layer_name(c.name) do return c
            i = end+1
        }
        i = ci_skip(s, i)
    }
    if ci_word(s, i, "supports") {
        i += 8
        if i >= len(s) || s[i] != '(' do return c
        end := ci_end(s, i+1, ')')
        if end < 0 || ci_skip(s[i+1:end], 0) == end-i-1 do return c
        c.supports = strings.trim_space(s[i+1:end])
        i = ci_skip(s, end+1)
    }
    // Modificadores fora de ordem/duplicados não podem virar media irrestrita.
    if ci_word(s, i, "layer") || ci_word(s, i, "supports") do return c
    c.media = strings.trim_space(s[i:])
    if ci_end(strings.concatenate({c.media, ";"}, context.temp_allocator), 0, ';') != len(c.media) do return c
    c.ok = true
    return c
}

import_media_cond :: proc(cond: string) -> string {
    c := css_import_conditions(cond)
    return c.ok ? c.media : ""
}

@(private = "file")
ci_open :: proc(sb: ^strings.Builder, c: CSS_Import_Conditions) -> int {
    n := 0
    // Layer é sempre externa: seu registro independe do resultado das condições.
    if c.layer {
        strings.write_string(sb, strings.concatenate({"\n@layer ", c.name, " {\n"}, context.temp_allocator))
        n += 1
    }
    if c.supports != "" {
        strings.write_string(sb, strings.concatenate({"\n@supports (", c.supports, ") {\n"}, context.temp_allocator))
        n += 1
    }
    if c.media != "" {
        strings.write_string(sb, strings.concatenate({"\n@media ", c.media, " {\n"}, context.temp_allocator))
        n += 1
    }
    return n
}

css_expand_imports :: proc(css, sheet_url: string, sb: ^strings.Builder, st: ^CSS_Import_State) {
    write_sheet_mark(sb, sheet_url)
    st.active[sheet_url] = true
    defer delete_key(&st.active, sheet_url)
    i, last := 0, 0
    first := true
    for {
        i = ci_skip(css, i)
        if i >= len(css) do break
        if first && ci_word(css, i, "@charset") {
            end := ci_end(css, i+8, ';')
            if end < 0 do break
            i = end+1
            first = false
            continue
        }
        first = false
        if ci_word(css, i, "@layer") {
            end := ci_end(css, i+6, ';')
            if end < 0 do break // bloco layer encerra cabeçalho
            names := strings.split(css[i+6:end], ",", context.temp_allocator)
            valid := len(names) > 0
            for name in names do valid = valid && ci_layer_name(name)
            if !valid do break
            i = end+1
            continue
        }
        if !ci_word(css, i, "@import") do break
        end := ci_end(css, i+7, ';')
        if end < 0 do break
        url, cond := parse_import_stmt(css[i+7:end])
        c := css_import_conditions(cond)
        strings.write_string(sb, css[last:i])
        i = end+1
        last = i
        if url == "" || !c.ok do continue
        // Também preserva camada vazia quando download falha ou ciclo é cortado.
        wrappers := ci_open(sb, c)
        abs := net.resolve_url(sheet_url, url, context.temp_allocator)
        if !(abs in st.active) && len(st.active) < 64 && st.expansions < 2048 {
            body, ok := css_import_body(st, abs)
            if ok {
                st.expansions += 1
                css_expand_imports(body, abs, sb, st)
            }
        }
        for j := 0; j < wrappers; j += 1 do strings.write_string(sb, "\n}\n")
        write_sheet_mark(sb, sheet_url)
    }
    strings.write_string(sb, css[last:])
}

// API legada: seen não é mais usado como dedup semântico nem como pilha.
append_css_with_imports :: proc(css, sheet_url: string, sb: ^strings.Builder, count: ^int, seen: ^map[string]bool) {
    st := css_import_state(count)
    css_expand_imports(css, sheet_url, sb, &st)
}
