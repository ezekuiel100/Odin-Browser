package html

// Emissor de tokens no formato do html5lib-tests (tokenizer/*.test). Usado pelo
// modo `browser.exe --tokenize`, que o html5lib-tokenizer.ps1 compara com o campo
// "output" esperado.
//
// Compartilha helpers de baixo nível com parser.odin (parse_open_tag,
// decode_entities, find_raw_close, strip_cdata, is_void, normalize_tag, ...),
// mas é separado do Tokenizer usado pelo tree builder principal em
// treebuild.odin. O runner cobre Data, PLAINTEXT, RCDATA, RAWTEXT, Script data e
// CDATA section; estados não mapeados são pulados.
//
// Formato de saída: uma linha JSON por token (o PS junta e compara estrutura):
//   ["Character", <dados>]
//   ["StartTag", <nome>, {<attrs>}]        (+ true no fim se self-closing)
//   ["EndTag", <nome>]
//   ["Comment", <dados>]
//   ["DOCTYPE", <nome|null>, <public|null>, <system|null>, <correctness_bool>]
//
// Diferenças remanescentes são registradas como DIFF pelo runner. Erros de parse
// do corpus não são emitidos como tokens; a comparação considera os tokens de
// conteúdo e ignora entradas ParseError esperadas.

import "core:strings"
import "core:unicode/utf8"

// Serializa os tokens de `input` como linhas JSON. `initial_state` = estado de
// entrada do tokenizer ("data" default, ou "plaintext"/"rcdata"/"rawtext"/
// "script"/"cdata"); `last_start_tag` = a "appropriate end tag" que fecha
// RCDATA/RAWTEXT/script (do campo lastStartTag dos testes html5lib).
html5lib_tokenize :: proc(input0: string, initial_state := "data", last_start_tag := "") -> string {
    sb := strings.builder_make()

    // Preprocessing do input stream (HTML5): CR e CRLF viram LF. Só aloca cópia
    // se houver algum '\r'.
    input := input0
    cr_owned := false
    if strings.index_byte(input0, '\r') >= 0 {
        nb := strings.builder_make()
        k := 0
        for k < len(input0) {
            if input0[k] == '\r' {
                strings.write_byte(&nb, '\n')
                if k + 1 < len(input0) && input0[k + 1] == '\n' do k += 1
            } else {
                strings.write_byte(&nb, input0[k])
            }
            k += 1
        }
        input = strings.to_string(nb)
        cr_owned = true
    }
    defer if cr_owned do delete(input)

    // Buffer de dados de caractere: o html5lib COALESCE tokens Character
    // adjacentes num só. Acumulamos aqui e damos flush ANTES de qualquer token
    // não-caractere (StartTag/EndTag/Comment/DOCTYPE) e no fim.
    cbuf := strings.builder_make()

    // acumula uma fatia de texto do estado Data (decodifica entidades). NÃO
    // sanitiza: o tokenizer reporta os codepoints REAIS (astral >U+FFFF, ZWJ,
    // seletores de variação). O descarte via sanitize_text é um limite de
    // RENDERIZAÇÃO (ImWchar 16-bit do ImGui) aplicado só ao construir os text
    // nodes do parser (parser.odin) — não é uma decisão de tokenização.
    add_text :: proc(cbuf: ^strings.Builder, run: string) {
        if len(run) == 0 do return
        dec := decode_entities(run)
        defer delete(dec)
        strings.write_string(cbuf, dec)
    }
    // acumula texto CRU (script/style: sem decodificar)
    add_raw :: proc(cbuf: ^strings.Builder, run: string) {
        strings.write_string(cbuf, run)
    }
    // emite o Character acumulado (se houver) e zera o buffer
    flush :: proc(sb, cbuf: ^strings.Builder) {
        if strings.builder_len(cbuf^) == 0 do return
        strings.write_string(sb, "[\"Character\",")
        json_string(sb, strings.to_string(cbuf^))
        strings.write_string(sb, "]\n")
        strings.builder_reset(cbuf)
    }

    i := 0
    n := len(input)

    // ── prefixo de estado inicial não-Data ───────────────────────────────────
    // Emite o conteúdo do estado até ele sair para o estado Data (fim do texto,
    // a end tag apropriada, ou `]]>`), e o laço Data abaixo continua a partir daí.
    if initial_state != "data" && initial_state != "" {
        // acumula uma fatia como Character, com decode de entidades opcional e
        // NUL→U+FFFD opcional (regras por estado)
        put_run :: proc(cbuf: ^strings.Builder, run: string, decode, nul_fffd: bool) {
            src := decode ? decode_entities(run) : run
            defer if decode do delete(src)
            if !nul_fffd {
                strings.write_string(cbuf, src)
                return
            }
            for k in 0 ..< len(src) {
                if src[k] == 0x00 { strings.write_rune(cbuf, '�') } else { strings.write_byte(cbuf, src[k]) }
            }
        }
        // a end tag apropriada é `</` + last (case-insensitive) + [ws|/|>]
        appropriate_end :: proc(s: string, at: int, last: string) -> bool {
            if len(last) == 0 || !has_at_ci(s, at, last) do return false
            a := at + len(last)
            if a >= len(s) do return false
            return is_space(s[a]) || s[a] == '/' || s[a] == '>'
        }

        switch initial_state {
        case "plaintext":
            put_run(&cbuf, input[i:n], false, true) // tudo texto, NUL→FFFD, nunca fecha
            i = n
        case "rcdata", "rawtext", "script":
            decode := initial_state == "rcdata"
            close_at := -1
            if initial_state == "script" {
                // script data: honra os sub-estados de escape (<!-- ... -->)
                close_at = script_close_pos(input, i, last_start_tag)
            } else {
                k := i
                for k < n {
                    if input[k] == '<' && k + 1 < n && input[k + 1] == '/' && appropriate_end(input, k + 2, last_start_tag) {
                        close_at = k
                        break
                    }
                    k += 1
                }
            }
            put_run(&cbuf, input[i:close_at if close_at >= 0 else n], decode, true)
            gt := close_at >= 0 ? index_byte_from(input, close_at, '>') : -1
            if gt >= 0 {
                // end tag apropriada COMPLETA (tem '>'): emite e volta a Data.
                flush(&sb, &cbuf)
                name := strings.to_lower(last_start_tag); defer delete(name)
                strings.write_string(&sb, "[\"EndTag\",")
                json_string(&sb, name)
                strings.write_string(&sb, "]\n")
                i = gt + 1
            } else {
                // sem '>' até EOF: a end tag (se iniciada) é abandonada — só o
                // texto acumulado sai. `foo</xmp ` → Character "foo", sem EndTag.
                i = n
            }
        case "cdata":
            end := index_from(input, i, "]]>")
            if end >= 0 {
                put_run(&cbuf, input[i:end], false, false) // raw, NUL MANTIDO
                i = end + 3 // → estado Data
            } else {
                put_run(&cbuf, input[i:n], false, false)
                i = n
            }
        }
    }

    for i < n {
        if input[i] == '<' && i + 1 < n {
            next := input[i + 1]

            // declaração de marcação <!  →  comentário / DOCTYPE / bogus comment
            if next == '!' {
                if has_at(input, i, "<!--") {
                    flush(&sb, &cbuf)
                    i = scan_comment(&sb, input, i + 4) // máquina de estados
                } else if has_at_ci(input, i + 2, "doctype") {
                    flush(&sb, &cbuf)
                    i = emit_doctype(&sb, input, i + 9) // após "<!DOCTYPE"
                } else {
                    flush(&sb, &cbuf) // `<! ...>` → bogus comment
                    i = emit_bogus_comment(&sb, input, i + 2)
                }
                continue
            }

            // tag de fechamento </
            if next == '/' {
                if i + 2 < n && is_ascii_alpha(input[i + 2]) {
                    end := index_byte_from(input, i, '>')
                    close := end if end >= 0 else n
                    tag := close_tag_name(input[i + 2 : close])
                    if len(tag) > 0 {
                        flush(&sb, &cbuf)
                        strings.write_string(&sb, "[\"EndTag\",")
                        json_string(&sb, tag)
                        strings.write_string(&sb, "]\n")
                    }
                    delete(tag)
                    i = close + 1 if end >= 0 else n
                } else if i + 2 < n && input[i + 2] == '>' {
                    i += 3 // `</>` end tag vazio: ignorado (sem flush → coalesce)
                } else if i + 2 >= n {
                    add_text(&cbuf, input[i:n]) // `</` no EOF → "<" e "/" literais
                    i = n
                } else {
                    flush(&sb, &cbuf) // `</1>` etc. → bogus comment
                    i = emit_bogus_comment(&sb, input, i + 2)
                }
                continue
            }

            // `<?` → bogus comment (o '?' entra no conteúdo)
            if next == '?' {
                flush(&sb, &cbuf)
                i = emit_bogus_comment(&sb, input, i + 1)
                continue
            }

            // tag de abertura: só se '<' for seguido de letra ASCII
            if is_ascii_alpha(next) {
                tag, attrs, aorder, self_closing, consumed, closed, ok := parse_open_tag(input[i:])
                if ok && !closed {
                    // EOF dentro da tag → token abandonado (nada emitido)
                    delete(tag); delete_attrs(attrs)
                    i = n
                    continue
                }
                if ok {
                flush(&sb, &cbuf)
                emit_start_tag(&sb, tag, attrs, self_closing)
                raw    := tag == "script" || tag == "style"
                rcdata := tag == "textarea" || tag == "title"
                if !is_void(tag) && !self_closing && (raw || rcdata) {
                    rest_start := i + consumed
                    rclose := find_raw_close(input, rest_start, tag)
                    end := rclose if rclose >= 0 else n
                    if end > rest_start {
                        if rcdata {
                            add_text(&cbuf, input[rest_start:end])
                        } else {
                            // <script>/<style>: cru (mas descasca <![CDATA[…]]>)
                            add_raw(&cbuf, strip_cdata(input[rest_start:end]))
                        }
                    }
                    if rclose >= 0 {
                        ce := index_byte_from(input, rclose, '>')
                        cname := close_tag_name(input[rclose + 2 : ce if ce >= 0 else n])
                        if len(cname) > 0 {
                            flush(&sb, &cbuf)
                            strings.write_string(&sb, "[\"EndTag\",")
                            json_string(&sb, cname)
                            strings.write_string(&sb, "]\n")
                        }
                        delete(cname)
                        i = ce + 1 if ce >= 0 else n
                    } else {
                        i = n
                    }
                    delete(tag); delete_attrs(attrs)
                    continue
                }
                delete(tag); delete_attrs(attrs)
                i += consumed
                continue
                } // if ok
            } // if is_ascii_alpha
        }

        // texto até o próximo '<' (com o mesmo cuidado do parser: '<' que não vira
        // tag é texto literal → busca começa depois dele, senão loop infinito).
        // NÃO damos flush aqui: runs de texto adjacentes (inclusive um '<' literal)
        // coalescem num único token Character.
        search_from := i + 1 if input[i] == '<' else i
        j := index_byte_from(input, search_from, '<')
        text_end := j if j >= 0 else n
        add_text(&cbuf, input[i:text_end])
        i = text_end
    }

    flush(&sb, &cbuf) // Character final acumulado
    return strings.to_string(sb)
}

@(private = "file")
delete_attrs :: proc(attrs: map[string]string) {
    a := attrs
    for k, v in a { delete(k); delete(v) }
    delete(a)
}

@(private = "file")
emit_start_tag :: proc(sb: ^strings.Builder, tag: string, attrs: map[string]string, self_closing: bool) {
    strings.write_string(sb, "[\"StartTag\",")
    json_string(sb, tag)
    strings.write_string(sb, ",{")
    // ordena os nomes p/ saída determinística (o esperado é um objeto — ordem
    // não importa na comparação estrutural do PS, mas mantemos estável)
    first := true
    keys := make([dynamic]string); defer delete(keys)
    for k in attrs do append(&keys, k)
    // insertion sort simples (poucos atributos)
    for a := 1; a < len(keys); a += 1 {
        v := keys[a]; b := a - 1
        for b >= 0 && keys[b] > v { keys[b + 1] = keys[b]; b -= 1 }
        keys[b + 1] = v
    }
    for k in keys {
        if !first do strings.write_byte(sb, ',')
        first = false
        json_string(sb, k)
        strings.write_byte(sb, ':')
        json_string(sb, attrs[k])
    }
    strings.write_byte(sb, '}')
    if self_closing do strings.write_string(sb, ",true")
    strings.write_string(sb, "]\n")
}

// Match case-insensitive de `needle` (ASCII) em s a partir de `at`.
@(private = "file")
has_at_ci :: proc(s: string, at: int, needle: string) -> bool {
    if at + len(needle) > len(s) do return false
    for k in 0 ..< len(needle) {
        a := s[at + k]; b := needle[k]
        if a >= 'A' && a <= 'Z' do a += 32
        if b >= 'A' && b <= 'Z' do b += 32
        if a != b do return false
    }
    return true
}

@(private = "file")
is_ascii_alpha :: proc(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Acha o '<' da end tag `</last>` que REALMENTE fecha o script data, honrando os
// sub-estados de escape do HTML5: dentro de `<!-- ... -->` (escaped) um `<script`
// entra em DOUBLE-escaped, onde `</script>` NÃO fecha (só `</script`→escaped e
// `-->`→script data). Devolve -1 se nada fecha. `st`: 0=script data, 1=escaped,
// 2=double-escaped.
@(private = "file")
script_close_pos :: proc(s: string, start: int, last: string) -> int {
    n := len(s)
    st := 0
    i := start
    delim :: proc(s: string, a: int) -> bool {
        return a < len(s) && (is_space(s[a]) || s[a] == '/' || s[a] == '>')
    }
    for i < n {
        if st >= 1 && has_at(s, i, "-->") { st = 0; i += 3; continue }
        if s[i] == '<' {
            if len(last) > 0 && (st == 0 || st == 1) && i + 1 < n && s[i + 1] == '/' && has_at_ci(s, i + 2, last) && delim(s, i + 2 + len(last)) {
                return i // end tag apropriada em script/escaped → FECHA (last vazio nunca fecha)
            }
            if st == 2 && i + 1 < n && s[i + 1] == '/' && has_at_ci(s, i + 2, "script") && delim(s, i + 2 + 6) {
                st = 1; i = i + 2 + 6; continue // </script em double → volta a escaped (não fecha)
            }
            if st == 1 && has_at_ci(s, i + 1, "script") && delim(s, i + 1 + 6) {
                st = 2; i = i + 1 + 6; continue // <script em escaped → double-escaped
            }
            if st == 0 && has_at(s, i, "<!--") { st = 1; i += 4; continue }
        }
        i += 1
    }
    return -1
}

// Escreve um byte num builder de nome/id de DOCTYPE, com NUL→U+FFFD e
// (opcional) minúsculo — regras dos "DOCTYPE ... state" do HTML5.
@(private = "file")
dt_put :: proc(b: ^strings.Builder, c: u8, lower: bool) {
    if c == 0x00 { strings.write_rune(b, '�'); return }
    ch := c
    if lower && ch >= 'A' && ch <= 'Z' do ch += 32
    strings.write_byte(b, ch)
}

@(private = "file")
Dt_State :: enum {
    BeforeName, Name, AfterName, AfterPubKw, BeforePubId, PubIdDq, PubIdSq,
    AfterPubId, BetweenPubSys, AfterSysKw, BeforeSysId, SysIdDq, SysIdSq,
    AfterSysId, Bogus, Done,
}

// Máquina de estados FIEL do DOCTYPE (HTML5 tokenizer). `s` é o input completo,
// `p` aponta logo após "<!DOCTYPE". Emite o token e devolve o índice seguinte.
// correctness = !force-quirks. NUL→FFFD nos nomes/ids; whitespace = is_space
// (tab/LF/FF/CR/espaço — NÃO o VT). PUBLIC/SYSTEM sem id válido → null.
@(private = "file")
emit_doctype :: proc(sb: ^strings.Builder, s: string, start: int) -> int {
    n := len(s)
    p := start
    name := strings.builder_make(); defer strings.builder_destroy(&name)
    pub  := strings.builder_make(); defer strings.builder_destroy(&pub)
    sys  := strings.builder_make(); defer strings.builder_destroy(&sys)
    has_name, has_pub, has_sys, fq := false, false, false, false
    st := Dt_State.BeforeName

    for st != .Done {
        if p >= n {
            // EOF seta force-quirks em TODOS os estados MENOS o Bogus (spec: o
            // "bogus DOCTYPE state" emite o token sem mexer no force-quirks).
            if st != .Bogus do fq = true
            break
        }
        c := s[p]
        switch st {
        case .BeforeName:
            if is_space(c) { p += 1 }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { has_name = true; dt_put(&name, c, true); p += 1; st = .Name }
        case .Name:
            if is_space(c) { p += 1; st = .AfterName }
            else if c == '>' { p += 1; st = .Done }
            else { dt_put(&name, c, true); p += 1 }
        case .AfterName:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else if has_at_ci(s, p, "public") { p += 6; st = .AfterPubKw }
            else if has_at_ci(s, p, "system") { p += 6; st = .AfterSysKw }
            else { fq = true; st = .Bogus }
        case .AfterPubKw:
            if is_space(c) { p += 1; st = .BeforePubId }
            else if c == '"' { has_pub = true; p += 1; st = .PubIdDq }
            else if c == '\'' { has_pub = true; p += 1; st = .PubIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .BeforePubId:
            if is_space(c) { p += 1 }
            else if c == '"' { has_pub = true; p += 1; st = .PubIdDq }
            else if c == '\'' { has_pub = true; p += 1; st = .PubIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .PubIdDq:
            if c == '"' { p += 1; st = .AfterPubId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { dt_put(&pub, c, false); p += 1 }
        case .PubIdSq:
            if c == '\'' { p += 1; st = .AfterPubId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { dt_put(&pub, c, false); p += 1 }
        case .AfterPubId:
            if is_space(c) { p += 1; st = .BetweenPubSys }
            else if c == '>' { p += 1; st = .Done }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else { fq = true; st = .Bogus }
        case .BetweenPubSys:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else { fq = true; st = .Bogus }
        case .AfterSysKw:
            if is_space(c) { p += 1; st = .BeforeSysId }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .BeforeSysId:
            if is_space(c) { p += 1 }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .SysIdDq:
            if c == '"' { p += 1; st = .AfterSysId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { dt_put(&sys, c, false); p += 1 }
        case .SysIdSq:
            if c == '\'' { p += 1; st = .AfterSysId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { dt_put(&sys, c, false); p += 1 }
        case .AfterSysId:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else { st = .Bogus } // NÃO seta force-quirks (spec)
        case .Bogus:
            if c == '>' { p += 1; st = .Done }
            else { p += 1 }
        case .Done:
        }
    }

    strings.write_string(sb, "[\"DOCTYPE\",")
    if has_name { json_string(sb, strings.to_string(name)) } else { strings.write_string(sb, "null") }
    strings.write_byte(sb, ',')
    if has_pub { json_string(sb, strings.to_string(pub)) } else { strings.write_string(sb, "null") }
    strings.write_byte(sb, ',')
    if has_sys { json_string(sb, strings.to_string(sys)) } else { strings.write_string(sb, "null") }
    strings.write_byte(sb, ',')
    strings.write_string(sb, "false" if fq else "true")
    strings.write_string(sb, "]\n")
    return p
}

@(private = "file")
Cm_State :: enum { Start, StartDash, Comment, EndDash, End, EndBang }

// Máquina de estados de comentário (HTML5). `start` aponta logo após "<!--".
// Fecha em `-->` ou `--!>`; trata os abruptos (`<!-->`, `<!--->`), dashes finais
// e NUL→U+FFFD. Emite o token Comment e devolve o índice seguinte.
@(private = "file")
scan_comment :: proc(sb: ^strings.Builder, s: string, start: int) -> int {
    n := len(s)
    p := start
    d := strings.builder_make(); defer strings.builder_destroy(&d)
    put :: proc(d: ^strings.Builder, c: u8) {
        if c == 0x00 { strings.write_rune(d, '�') } else { strings.write_byte(d, c) }
    }
    st := Cm_State.Start
    done := false
    for !done {
        if p >= n do break // EOF: emite o que tem
        c := s[p]
        switch st {
        case .Start:
            if c == '-' { p += 1; st = .StartDash }
            else if c == '>' { p += 1; done = true } // <!--> abrupto → vazio
            else { st = .Comment }
        case .StartDash:
            if c == '-' { p += 1; st = .End }
            else if c == '>' { p += 1; done = true } // <!---> abrupto
            else { put(&d, '-'); st = .Comment }
        case .Comment:
            if c == '-' { p += 1; st = .EndDash }
            else { put(&d, c); p += 1 }
        case .EndDash:
            if c == '-' { p += 1; st = .End }
            else { put(&d, '-'); st = .Comment }
        case .End:
            if c == '>' { p += 1; done = true }
            else if c == '!' { p += 1; st = .EndBang }
            else if c == '-' { put(&d, '-'); p += 1 } // fica em End
            else { put(&d, '-'); put(&d, '-'); st = .Comment }
        case .EndBang:
            if c == '-' { put(&d, '-'); put(&d, '-'); put(&d, '!'); p += 1; st = .EndDash }
            else if c == '>' { p += 1; done = true } // --!> fecha
            else { put(&d, '-'); put(&d, '-'); put(&d, '!'); st = .Comment }
        }
    }
    strings.write_string(sb, "[\"Comment\",")
    json_string(sb, strings.to_string(d))
    strings.write_string(sb, "]\n")
    return p
}

// Bogus comment (HTML5): consome de `start` até '>' (ou EOF), emite Comment com
// o conteúdo (NUL→U+FFFD). Cobre `<! ...>`, `<?...>`, `</1>`.
@(private = "file")
emit_bogus_comment :: proc(sb: ^strings.Builder, s: string, start: int) -> int {
    n := len(s)
    gt := index_byte_from(s, start, '>')
    end := gt if gt >= 0 else n
    data := strings.builder_make(); defer strings.builder_destroy(&data)
    for k in start ..< end {
        if s[k] == 0x00 { strings.write_rune(&data, '�') } else { strings.write_byte(&data, s[k]) }
    }
    strings.write_string(sb, "[\"Comment\",")
    json_string(sb, strings.to_string(data))
    strings.write_string(sb, "]\n")
    return end + 1 if gt >= 0 else n
}

// Escreve `s` como string JSON (aspas + escapes). UTF-8 cru p/ o resto (o PS lê
// UTF-8). NUL e controles viram \u00XX.
@(private = "file")
json_string :: proc(sb: ^strings.Builder, s: string) {
    strings.write_byte(sb, '"')
    for r in s {
        switch r {
        case '"':  strings.write_string(sb, "\\\"")
        case '\\': strings.write_string(sb, "\\\\")
        case '\n': strings.write_string(sb, "\\n")
        case '\r': strings.write_string(sb, "\\r")
        case '\t': strings.write_string(sb, "\\t")
        case '\f': strings.write_string(sb, "\\f")
        case '\b': strings.write_string(sb, "\\b")
        case:
            if r < 0x20 {
                write_u_escape(sb, u16(r))
            } else {
                bytes, w := utf8.encode_rune(r)
                strings.write_bytes(sb, bytes[:w])
            }
        }
    }
    strings.write_byte(sb, '"')
}

@(private = "file")
write_u_escape :: proc(sb: ^strings.Builder, v: u16) {
    hex := "0123456789abcdef"
    strings.write_string(sb, "\\u")
    strings.write_byte(sb, hex[(v >> 12) & 0xF])
    strings.write_byte(sb, hex[(v >> 8) & 0xF])
    strings.write_byte(sb, hex[(v >> 4) & 0xF])
    strings.write_byte(sb, hex[v & 0xF])
}
